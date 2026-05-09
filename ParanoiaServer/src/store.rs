use anyhow::{Context, Result};
use rocksdb::{DB, IteratorMode, Options, WriteBatch};

pub struct PacketStore {
    db: DB,
}

// RocksDB внутри потокобезопасен для конкурентных чтений/записей
// DB: Send + Sync, поэтому Arc<PacketStore> безопасен
unsafe impl Send for PacketStore {}
unsafe impl Sync for PacketStore {}

impl PacketStore {
    pub fn open(path: &str) -> Result<Self> {
        let mut opts = Options::default();
        opts.create_if_missing(true);
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

    /// Получить пакеты с seq > after_seq для данного диалога.
    pub fn pull(&self, dialogue_id: &str, after_seq: u64) -> Result<Vec<(u64, Vec<u8>)>> {
        let start_key = make_key(dialogue_id, after_seq.saturating_add(1));
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
            result.push((seq, val_bytes.to_vec()));
        }
        Ok(result)
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
}

fn make_key(dialogue_id: &str, seq: u64) -> String {
    format!("{dialogue_id}:{seq:020}")
}

fn parse_seq(key: &str, dialogue_id: &str) -> Result<u64> {
    let suffix = &key[dialogue_id.len() + 1..]; // +1 для ":"
    suffix
        .parse::<u64>()
        .with_context(|| format!("Cannot parse seq from key: {key}"))
}
