use anyhow::{Context, Result};
use rocksdb::{DB, DBCompressionType, IteratorMode, Options, WriteBatch};
use serde::{Deserialize, Serialize};
use std::time::{SystemTime, UNIX_EPOCH};

pub struct PacketStore {
    db: DB,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReceiptState {
    pub last_seq: u64,
    pub receipts_enabled: bool,
    pub updated_at: u64,
}

impl Default for ReceiptState {
    fn default() -> Self {
        Self {
            last_seq: 0,
            receipts_enabled: true,
            updated_at: 0,
        }
    }
}

// RocksDB внутри потокобезопасен для конкурентных чтений/записей
// DB: Send + Sync, поэтому Arc<PacketStore> безопасен
unsafe impl Send for PacketStore {}
unsafe impl Sync for PacketStore {}

impl PacketStore {
    pub fn open(path: &str) -> Result<Self> {
        let mut opts = Options::default();
        opts.create_if_missing(true);
        // Payload уже зашифрован на клиенте, поэтому сжатие почти не экономит диск.
        opts.set_compression_type(DBCompressionType::None);
        let db = DB::open(&opts, path).with_context(|| format!("Cannot open RocksDB at {path}"))?;
        Ok(Self { db })
    }

    /// Сохранить пакет. Возвращает ошибку при дублировании seq.
    pub fn push(&self, dialogue_id: &str, seq: u64, data: &[u8]) -> Result<()> {
        let key = make_key(dialogue_id, seq);
        if self.db.get(&key)?.is_some() {
            anyhow::bail!("Duplicate seq {seq}");
        }
        self.db.put(&key, data).context("RocksDB put failed")
    }

    /// Получить пакеты для pull.
    ///
    /// * `to_seq == 0`: старая логика, все пакеты с `seq > after_seq`.
    /// * `to_seq >= after_seq`: ограниченный pull `(after_seq, to_seq]`.
    pub fn pull(
        &self,
        dialogue_id: &str,
        after_seq: u64,
        to_seq: u64,
    ) -> Result<Vec<(u64, Vec<u8>)>> {
        let Some((start_seq, end_seq)) = pull_bounds(after_seq, to_seq)? else {
            return Ok(Vec::new());
        };
        let start_key = make_key(dialogue_id, start_seq);
        let prefix = format!("{dialogue_id}:");
        let mut result = Vec::new();

        let iter = self.db.iterator(IteratorMode::From(
            start_key.as_bytes(),
            rocksdb::Direction::Forward,
        ));

        for item in iter {
            let (key_bytes, val_bytes) = item.context("RocksDB iterator error")?;
            let key_str = std::str::from_utf8(&key_bytes).context("Non-UTF8 key in RocksDB")?;
            if !key_str.starts_with(&prefix) {
                break;
            }
            let seq = parse_seq(key_str, dialogue_id)?;
            if let Some(end_seq) = end_seq {
                if seq > end_seq {
                    break;
                }
            }
            result.push((seq, val_bytes.to_vec()));
        }
        Ok(result)
    }

    /// Посчитать пакеты с seq > after_seq без чтения payload.
    pub fn count_after(&self, dialogue_id: &str, after_seq: u64) -> Result<u64> {
        let start_key = make_key(dialogue_id, after_seq.saturating_add(1));
        let prefix = format!("{dialogue_id}:");
        let mut count = 0u64;

        let iter = self.db.iterator(IteratorMode::From(
            start_key.as_bytes(),
            rocksdb::Direction::Forward,
        ));

        for item in iter {
            let (key_bytes, _) = item.context("RocksDB iterator error")?;
            let key_str = std::str::from_utf8(&key_bytes).context("Non-UTF8 key in RocksDB")?;
            if !key_str.starts_with(&prefix) {
                break;
            }
            count = count.saturating_add(1);
        }
        Ok(count)
    }

    /// Удалить все пакеты с seq <= cut_seq для данного диалога.
    pub fn remove_until(&self, dialogue_id: &str, cut_seq: u64) -> Result<()> {
        let prefix = format!("{dialogue_id}:");
        let mut batch = WriteBatch::default();

        let iter = self.db.iterator(IteratorMode::From(
            prefix.as_bytes(),
            rocksdb::Direction::Forward,
        ));

        for item in iter {
            let (key_bytes, _) = item.context("RocksDB iterator error")?;
            let key_str = std::str::from_utf8(&key_bytes).context("Non-UTF8 key in RocksDB")?;
            if !key_str.starts_with(&prefix) {
                break;
            }
            let seq = parse_seq(key_str, dialogue_id)?;
            if seq <= cut_seq {
                batch.delete(&key_bytes);
            } else {
                break; // ключи отсортированы, дальше seq только растёт
            }
        }
        self.db.write(batch).context("RocksDB write batch failed")
    }

    pub fn receipt_state(&self, username: &str, dialogue_id: &str) -> Result<ReceiptState> {
        let key = make_receipt_key(username, dialogue_id);
        let Some(value) = self.db.get(&key)? else {
            return Ok(ReceiptState::default());
        };
        serde_json::from_slice(&value).context("Cannot decode receipt state")
    }

    pub fn update_last_seq(
        &self,
        username: &str,
        dialogue_id: &str,
        pulled_seq: u64,
    ) -> Result<()> {
        let mut state = self.receipt_state(username, dialogue_id)?;
        if !state.receipts_enabled {
            return Ok(());
        }
        state.last_seq = state.last_seq.max(pulled_seq);
        state.updated_at = now_unix_ts();
        self.write_receipt_state(username, dialogue_id, &state)
    }

    pub fn set_receipts_enabled(
        &self,
        username: &str,
        dialogue_id: &str,
        receipts_enabled: bool,
    ) -> Result<()> {
        let mut state = self.receipt_state(username, dialogue_id)?;
        state.receipts_enabled = receipts_enabled;
        state.updated_at = now_unix_ts();
        self.write_receipt_state(username, dialogue_id, &state)
    }

    fn write_receipt_state(
        &self,
        username: &str,
        dialogue_id: &str,
        state: &ReceiptState,
    ) -> Result<()> {
        let key = make_receipt_key(username, dialogue_id);
        let value = serde_json::to_vec(state)?;
        self.db
            .put(key, value)
            .context("RocksDB put receipt failed")
    }
}

fn make_key(dialogue_id: &str, seq: u64) -> String {
    format!("{dialogue_id}:{seq:020}")
}

fn make_receipt_key(username: &str, dialogue_id: &str) -> String {
    format!("receipt:{username}:{dialogue_id}")
}

fn now_unix_ts() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0)
}

fn parse_seq(key: &str, dialogue_id: &str) -> Result<u64> {
    let suffix = &key[dialogue_id.len() + 1..]; // +1 для ":"
    suffix
        .parse::<u64>()
        .with_context(|| format!("Cannot parse seq from key: {key}"))
}

fn pull_bounds(after_seq: u64, to_seq: u64) -> Result<Option<(u64, Option<u64>)>> {
    if to_seq != 0 && to_seq < after_seq {
        anyhow::bail!("Invalid pull range");
    }

    let Some(start_seq) = after_seq.checked_add(1) else {
        return Ok(None);
    };

    let end_seq = (to_seq != 0).then_some(to_seq);
    if end_seq.is_some_and(|end_seq| start_seq > end_seq) {
        return Ok(None);
    }

    Ok(Some((start_seq, end_seq)))
}

#[cfg(test)]
mod tests {
    use super::pull_bounds;

    #[test]
    fn pull_bounds_keeps_legacy_open_ended_mode() {
        assert_eq!(pull_bounds(10, 0).unwrap(), Some((11, None)));
    }

    #[test]
    fn pull_bounds_supports_bounded_mode() {
        assert_eq!(pull_bounds(10, 20).unwrap(), Some((11, Some(20))));
    }

    #[test]
    fn pull_bounds_allows_empty_bounded_range() {
        assert_eq!(pull_bounds(10, 10).unwrap(), None);
    }

    #[test]
    fn pull_bounds_rejects_reversed_range() {
        assert!(pull_bounds(20, 10).is_err());
    }

    #[test]
    fn pull_bounds_handles_max_cursor_in_legacy_mode() {
        assert_eq!(pull_bounds(u64::MAX, 0).unwrap(), None);
    }
}
