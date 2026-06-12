//! Пробуждение long-poll ожидателей `/notify` при появлении нового сообщения.
//!
//! В отличие от [`crate::call_signal`], здесь НЕТ очереди и payload: сами
//! сообщения durable лежат в [`crate::store::PacketStore`] (RocksDB). Этот стор
//! держит ТОЛЬКО `tokio::sync::Notify` на каждый `dialogue_id` — чистый сигнал
//! «в этом диалоге что-то появилось, перечитай count_after». При `/push` сервер
//! будит ожидателей соответствующего диалога; long-poll `/notify` просыпается и
//! пересчитывает количество новых.
//!
//! Почему по `dialogue_id`, а не по получателю: `make_dialogue_id` симметричен,
//! `/push` и `/notify` считают один и тот же id для пары. Разбудив по диалогу, мы
//! будим обе стороны — каждая пересчитает новые сообщения относительно СВОЕГО seq.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use tokio::sync::{Notify, RwLock};

/// Период фоновой GC пустых waker'ов.
pub const GC_INTERVAL: Duration = Duration::from_secs(30);

/// Реестр per-dialogue Notify для long-poll `/notify`.
pub struct DialogueNotifyStore {
    inner: RwLock<HashMap<String, Arc<Notify>>>,
}

impl DialogueNotifyStore {
    pub fn new() -> Self {
        Self {
            inner: RwLock::new(HashMap::new()),
        }
    }

    /// Разбудить всех, кто сейчас long-poll'ит этот диалог. Если ожидателей нет —
    /// дешёвый no-op (не создаём запись: незачем плодить waker'ы на каждый push).
    pub async fn notify(&self, dialogue_id: &str) {
        let waker = {
            let map = self.inner.read().await;
            map.get(dialogue_id).map(Arc::clone)
        };
        if let Some(w) = waker {
            w.notify_waiters();
        }
    }

    /// Получить Notify для long-poll ожидания (создаёт запись, если нет). Вызывающий
    /// держит `Arc` всё время ожидания — поэтому GC не удалит «живой» waker
    /// (strong_count > 1).
    pub async fn waker(&self, dialogue_id: &str) -> Arc<Notify> {
        let mut map = self.inner.write().await;
        Arc::clone(
            map.entry(dialogue_id.to_string())
                .or_insert_with(|| Arc::new(Notify::new())),
        )
    }

    /// GC: выкинуть waker'ы, которые никто не держит (нет активных ожидателей).
    /// `strong_count == 1` → ссылку держит только сама мапа.
    pub async fn gc(&self) {
        let mut map = self.inner.write().await;
        map.retain(|_, w| Arc::strong_count(w) > 1);
    }
}

impl Default for DialogueNotifyStore {
    fn default() -> Self {
        Self::new()
    }
}

/// Фоновая GC-задача. JoinHandle теряем — задача живёт с рантаймом.
pub fn spawn_gc(store: Arc<DialogueNotifyStore>) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(GC_INTERVAL);
        ticker.tick().await; // первый tick — сразу, пропускаем
        loop {
            ticker.tick().await;
            store.gc().await;
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn notify_with_no_waiters_is_noop() {
        let store = DialogueNotifyStore::new();
        // Не паникует, ничего не создаёт.
        store.notify("dlg1").await;
        assert_eq!(store.inner.read().await.len(), 0);
    }

    #[tokio::test]
    async fn waker_wakes_waiter() {
        let store = Arc::new(DialogueNotifyStore::new());
        let w = store.waker("dlg1").await;
        let notified = w.notified();
        tokio::pin!(notified);
        let store2 = Arc::clone(&store);
        let h = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(10)).await;
            store2.notify("dlg1").await;
        });
        // Должны проснуться до таймаута.
        tokio::time::timeout(Duration::from_secs(1), notified.as_mut())
            .await
            .expect("waker did not fire");
        h.await.unwrap();
    }

    #[tokio::test]
    async fn gc_drops_unheld_wakers() {
        let store = DialogueNotifyStore::new();
        let _ = store.waker("dlg1").await; // Arc дропнут сразу (не держим)
        assert_eq!(store.inner.read().await.len(), 1);
        store.gc().await;
        assert_eq!(store.inner.read().await.len(), 0);
    }

    #[tokio::test]
    async fn gc_keeps_held_wakers() {
        let store = DialogueNotifyStore::new();
        let _held = store.waker("dlg1").await; // держим Arc
        store.gc().await;
        assert_eq!(store.inner.read().await.len(), 1);
    }
}
