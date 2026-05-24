//! In-memory очередь сигнальных конвертов VoIP.
//!
//! Конверты живут только в RAM и удаляются по TTL (`ENVELOPE_TTL`). Никакой
//! персистентности в `PacketStore` — сигналинг эфемерный. Сервер видит метаданные
//! `{sender, recver, kind, ts}`, но payload зашифрован dialog master key'ом и
//! сервер его не расшифровывает.
//!
//! Long-poll реализован через `tokio::sync::Notify`: при `push` будятся все
//! ожидатели данного recver'a.

use std::collections::{HashMap, VecDeque};
use std::sync::Arc;
use std::time::{Duration, Instant};

use tokio::sync::{Notify, RwLock};

/// Максимальный возраст конверта в очереди.
pub const ENVELOPE_TTL: Duration = Duration::from_secs(60);
/// Период фоновой GC.
pub const GC_INTERVAL: Duration = Duration::from_secs(10);
/// Жёсткий потолок на длину очереди одного recver'a — защита от затопления.
pub const MAX_QUEUE_LEN: usize = 64;
/// Жёсткий потолок на размер одного payload'а (после base64-декода).
pub const MAX_PAYLOAD_LEN: usize = 4 * 1024;

#[derive(Debug, Clone)]
pub struct CallEnvelope {
    pub sender: String,
    pub kind: u8,
    pub payload: Vec<u8>,
    pub ts_ms: i64,
    pub received: Instant,
}

struct Queue {
    items: VecDeque<CallEnvelope>,
    /// Notify, на котором ждут long-poll'еры этого recver'a.
    waker: Arc<Notify>,
}

impl Queue {
    fn new() -> Self {
        Self {
            items: VecDeque::new(),
            waker: Arc::new(Notify::new()),
        }
    }
}

pub struct CallSignalStore {
    inner: RwLock<HashMap<String, Queue>>,
}

impl CallSignalStore {
    pub fn new() -> Self {
        Self {
            inner: RwLock::new(HashMap::new()),
        }
    }

    /// Положить конверт в очередь recver'a и разбудить ожидающих.
    pub async fn push(&self, recver: String, envelope: CallEnvelope) {
        let waker = {
            let mut map = self.inner.write().await;
            let q = map.entry(recver).or_insert_with(Queue::new);
            // Кольцо: при переполнении отбрасываем самый старый.
            if q.items.len() >= MAX_QUEUE_LEN {
                q.items.pop_front();
            }
            q.items.push_back(envelope);
            Arc::clone(&q.waker)
        };
        waker.notify_waiters();
    }

    /// Дренировать все накопленные конверты recver'a. Не блокирует.
    pub async fn drain(&self, recver: &str) -> Vec<CallEnvelope> {
        let mut map = self.inner.write().await;
        match map.get_mut(recver) {
            Some(q) => q.items.drain(..).collect(),
            None => Vec::new(),
        }
    }

    /// Получить Notify-объект для long-poll. Если очереди ещё нет — создать.
    pub async fn waker(&self, recver: &str) -> Arc<Notify> {
        let mut map = self.inner.write().await;
        let q = map.entry(recver.to_string()).or_insert_with(Queue::new);
        Arc::clone(&q.waker)
    }

    /// GC: удалить устаревшие конверты и пустые очереди.
    pub async fn gc(&self) {
        let now = Instant::now();
        let mut map = self.inner.write().await;
        map.retain(|_, q| {
            while let Some(front) = q.items.front() {
                if now.duration_since(front.received) > ENVELOPE_TTL {
                    q.items.pop_front();
                } else {
                    break;
                }
            }
            // Очередь живёт, пока есть конверты ИЛИ кто-то держит её waker
            // (Arc::strong_count > 1 = ожидатель ещё держит ссылку).
            !q.items.is_empty() || Arc::strong_count(&q.waker) > 1
        });
    }
}

impl Default for CallSignalStore {
    fn default() -> Self {
        Self::new()
    }
}

/// Запустить фоновую GC-задачу. Возвращает JoinHandle, который потеряем — задача
/// прерывается при остановке Tokio-рантайма.
pub fn spawn_gc(store: Arc<CallSignalStore>) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(GC_INTERVAL);
        // Первый tick срабатывает сразу — пропустим.
        ticker.tick().await;
        loop {
            ticker.tick().await;
            store.gc().await;
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_envelope(sender: &str, kind: u8) -> CallEnvelope {
        CallEnvelope {
            sender: sender.into(),
            kind,
            payload: vec![1, 2, 3],
            ts_ms: 0,
            received: Instant::now(),
        }
    }

    #[tokio::test]
    async fn push_and_drain() {
        let store = CallSignalStore::new();
        store.push("bob".into(), make_envelope("alice", 0)).await;
        store.push("bob".into(), make_envelope("alice", 2)).await;
        let drained = store.drain("bob").await;
        assert_eq!(drained.len(), 2);
        assert_eq!(drained[0].kind, 0);
        assert_eq!(drained[1].kind, 2);
        let drained_again = store.drain("bob").await;
        assert!(drained_again.is_empty());
    }

    #[tokio::test]
    async fn queue_overflow_drops_oldest() {
        let store = CallSignalStore::new();
        for i in 0..(MAX_QUEUE_LEN as u8 + 5) {
            store.push("bob".into(), make_envelope("alice", i)).await;
        }
        let drained = store.drain("bob").await;
        assert_eq!(drained.len(), MAX_QUEUE_LEN);
        // Первые 5 должны быть отброшены.
        assert_eq!(drained.first().unwrap().kind, 5);
    }

    #[tokio::test]
    async fn waker_wakes_waiters() {
        let store = Arc::new(CallSignalStore::new());
        let w = store.waker("bob").await;
        let store2 = Arc::clone(&store);
        let handle = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(10)).await;
            store2.push("bob".into(), make_envelope("alice", 0)).await;
        });
        // Ждём с таймаутом, чтобы тест не висел в случае поломки.
        let _ = tokio::time::timeout(Duration::from_secs(1), w.notified())
            .await
            .expect("waker did not fire");
        handle.await.unwrap();
        assert_eq!(store.drain("bob").await.len(), 1);
    }

    #[tokio::test]
    async fn gc_removes_expired() {
        let store = CallSignalStore::new();
        let mut old = make_envelope("alice", 0);
        old.received = Instant::now() - ENVELOPE_TTL - Duration::from_secs(1);
        store.push("bob".into(), old).await;
        store.gc().await;
        assert!(store.drain("bob").await.is_empty());
    }
}
