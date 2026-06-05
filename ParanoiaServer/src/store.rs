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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MapResult {
    pub runs: Vec<(u64, u64)>,
    pub last_seq: u64,
    pub truncated: bool,
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

    /// Получить пакеты в диапазоне `(after_seq, to_seq]`. `to_seq` обязателен
    /// и должен быть строго больше `after_seq`.
    pub fn pull(
        &self,
        dialogue_id: &str,
        after_seq: u64,
        to_seq: u64,
    ) -> Result<Vec<(u64, Vec<u8>)>> {
        if to_seq == 0 || to_seq <= after_seq {
            anyhow::bail!("Invalid pull range");
        }
        let Some(start_seq) = after_seq.checked_add(1) else {
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
            if seq > to_seq {
                break;
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

    /// Карта живых seq в диалоге.
    ///
    /// Возвращает список непрерывных runs `(begin, end)` (включительно с обеих
    /// сторон) для всех существующих seq в `(after_seq, to_seq]`. `to_seq == 0`
    /// означает открытый правый конец.
    ///
    /// `last_seq` — максимальный seq во всём диалоге (даже если он за пределами
    /// запрошенного диапазона), или 0 если диалог пуст.
    ///
    /// Если количество runs достигло `max_runs`, ответ обрезается и
    /// `truncated = true`. Клиент тогда дозапрашивает с `after_seq =
    /// последний_возвращённый_end`.
    pub fn map(
        &self,
        dialogue_id: &str,
        after_seq: u64,
        to_seq: u64,
        max_runs: usize,
    ) -> Result<MapResult> {
        if to_seq != 0 && to_seq <= after_seq {
            anyhow::bail!("Invalid map range");
        }
        let start_seq = match after_seq.checked_add(1) {
            Some(s) => s,
            None => {
                return Ok(MapResult {
                    runs: Vec::new(),
                    last_seq: self.last_seq(dialogue_id)?,
                    truncated: false,
                });
            }
        };
        let prefix = format!("{dialogue_id}:");
        let start_key = make_key(dialogue_id, start_seq);
        let mut runs: Vec<(u64, u64)> = Vec::new();
        let mut current: Option<(u64, u64)> = None;
        let mut truncated = false;

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
            let seq = parse_seq(key_str, dialogue_id)?;
            if to_seq != 0 && seq > to_seq {
                break;
            }
            if let Some((_, last)) = current.as_mut() {
                if seq == *last + 1 {
                    *last = seq;
                    continue;
                }
                runs.push(current.take().expect("current is Some"));
            }
            if runs.len() >= max_runs {
                truncated = true;
                break;
            }
            current = Some((seq, seq));
        }

        if !truncated {
            if let Some(run) = current.take() {
                runs.push(run);
            }
        }

        let last_seq = self.last_seq(dialogue_id)?;
        Ok(MapResult {
            runs,
            last_seq,
            truncated,
        })
    }

    /// Максимальный seq во всём диалоге (или 0 если диалог пуст).
    pub fn last_seq(&self, dialogue_id: &str) -> Result<u64> {
        let prefix = format!("{dialogue_id}:");
        // ':' = 0x3A, ';' = 0x3B — reverse-seek от dialogue_id+';' попадает на
        // самый большой ключ с префиксом dialogue_id+':'.
        let upper = format!("{dialogue_id};");
        let mut iter = self.db.iterator(IteratorMode::From(
            upper.as_bytes(),
            rocksdb::Direction::Reverse,
        ));
        if let Some(item) = iter.next() {
            let (key_bytes, _) = item.context("RocksDB iterator error")?;
            let key_str = std::str::from_utf8(&key_bytes).context("Non-UTF8 key in RocksDB")?;
            if key_str.starts_with(&prefix) {
                return parse_seq(key_str, dialogue_id);
            }
        }
        Ok(0)
    }

    /// Удалить пакеты с seq в `[from_seq, to_seq]` (включительно) для диалога.
    /// `from_seq == 0` интерпретируется как «с начала диалога».
    pub fn remove_range(&self, dialogue_id: &str, from_seq: u64, to_seq: u64) -> Result<()> {
        if from_seq > to_seq && from_seq != 0 {
            anyhow::bail!("Invalid range");
        }
        let prefix = format!("{dialogue_id}:");
        let start_seq = from_seq.max(1);
        let start_key = make_key(dialogue_id, start_seq);
        let mut batch = WriteBatch::default();

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
            let seq = parse_seq(key_str, dialogue_id)?;
            if seq > to_seq {
                break; // ключи отсортированы, дальше seq только растёт
            }
            batch.delete(&key_bytes);
        }
        self.db.write(batch).context("RocksDB write batch failed")
    }

    /// Перечислить все диалоги в хранилище как `(dialogue_id, last_seq, total_bytes)`.
    ///
    /// `total_bytes` — суммарный размер value всех пакетов диалога на диске
    /// (compression выключен, см. `open`, поэтому это байты «как лежат»). Значение
    /// и так материализуется итератором, так что подсчёт практически бесплатен.
    ///
    /// Служебные ключи `receipt:*` пропускаются. Ключи RocksDB отсортированы
    /// лексикографически, а `dialogue_id` имеет фиксированную длину (hex SHA256)
    /// с zero-padded seq, поэтому все пакеты одного диалога идут подряд.
    pub fn list_dialogues(&self) -> Result<Vec<(String, u64, u64)>> {
        let mut result: Vec<(String, u64, u64)> = Vec::new();
        let mut current_id: Option<String> = None;
        let mut current_last: u64 = 0;
        let mut current_bytes: u64 = 0;

        let iter = self.db.iterator(IteratorMode::Start);
        for item in iter {
            let (key_bytes, val_bytes) = item.context("RocksDB iterator error")?;
            let key_str = std::str::from_utf8(&key_bytes).context("Non-UTF8 key in RocksDB")?;
            if key_str.starts_with("receipt:") {
                continue;
            }
            let Some((id, seq_str)) = key_str.split_once(':') else {
                continue;
            };
            let Ok(seq) = seq_str.parse::<u64>() else {
                continue;
            };
            let val_len = val_bytes.len() as u64;
            match current_id.as_deref() {
                Some(cur) if cur == id => {
                    if seq > current_last {
                        current_last = seq;
                    }
                    current_bytes = current_bytes.saturating_add(val_len);
                }
                _ => {
                    if let Some(prev) = current_id.take() {
                        result.push((prev, current_last, current_bytes));
                    }
                    current_id = Some(id.to_string());
                    current_last = seq;
                    current_bytes = val_len;
                }
            }
        }
        if let Some(prev) = current_id.take() {
            result.push((prev, current_last, current_bytes));
        }
        Ok(result)
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

    // ── Эфемерное хранилище больших файлов ────────────────────────────────
    //
    // Большие файлы (в диапазоне (max_history_file_size .. large_file_max])
    // НЕ попадают в историю диалога: они лежат в отдельном пространстве ключей
    // `eph:<dialogue_id>:<file_id>:<chunk>` с метазаписью `ephmeta:<did>:<fid>`,
    // несущей срок жизни `expires_at`. Reaper физически удаляет просроченные.
    // Сервер видит только шифр-блобы (E2E), про содержимое ничего не знает.

    /// Сохранить один чанк эфемерного файла и (пере)записать метазапись с TTL.
    /// `retention_secs` — срок «ожидания скачивания» из конфига сервера.
    pub fn ephemeral_put_chunk(
        &self,
        dialogue_id: &str,
        file_id: &str,
        chunk_index: u32,
        total_chunks: u32,
        total_size: u64,
        data: &[u8],
        retention_secs: u64,
    ) -> Result<()> {
        let chunk_key = make_eph_chunk_key(dialogue_id, file_id, chunk_index);
        self.db
            .put(&chunk_key, data)
            .context("RocksDB put ephemeral chunk failed")?;
        let meta = EphemeralMeta {
            chunk_count: total_chunks,
            total_size,
            expires_at: now_unix_ts().saturating_add(retention_secs),
        };
        let meta_key = make_eph_meta_key(dialogue_id, file_id);
        self.db
            .put(&meta_key, serde_json::to_vec(&meta)?)
            .context("RocksDB put ephemeral meta failed")
    }

    /// Метазапись эфемерного файла (если есть и не просрочена).
    pub fn ephemeral_meta(&self, dialogue_id: &str, file_id: &str) -> Result<Option<EphemeralMeta>> {
        let key = make_eph_meta_key(dialogue_id, file_id);
        let Some(value) = self.db.get(&key)? else {
            return Ok(None);
        };
        let meta: EphemeralMeta = serde_json::from_slice(&value).context("Bad ephemeral meta")?;
        if meta.expires_at <= now_unix_ts() {
            return Ok(None);
        }
        Ok(Some(meta))
    }

    /// Получить один чанк эфемерного файла (если файл существует и не просрочен).
    pub fn ephemeral_get_chunk(
        &self,
        dialogue_id: &str,
        file_id: &str,
        chunk_index: u32,
    ) -> Result<Option<Vec<u8>>> {
        if self.ephemeral_meta(dialogue_id, file_id)?.is_none() {
            return Ok(None);
        }
        let key = make_eph_chunk_key(dialogue_id, file_id, chunk_index);
        Ok(self.db.get(&key)?)
    }

    /// Удалить все просроченные эфемерные файлы (метазапись + все чанки).
    /// Возвращает число удалённых файлов. Вызывается фоновым reaper'ом.
    pub fn ephemeral_reap(&self) -> Result<u64> {
        let now = now_unix_ts();
        let mut expired: Vec<String> = Vec::new(); // "<did>:<fid>"
        let iter = self.db.iterator(IteratorMode::From(
            EPH_META_PREFIX.as_bytes(),
            rocksdb::Direction::Forward,
        ));
        for item in iter {
            let (key_bytes, val_bytes) = item.context("RocksDB iterator error")?;
            let key_str = std::str::from_utf8(&key_bytes).context("Non-UTF8 key")?;
            let Some(suffix) = key_str.strip_prefix(EPH_META_PREFIX) else {
                break; // вышли за пределы ephmeta: — ключи отсортированы
            };
            let expires_at = serde_json::from_slice::<EphemeralMeta>(&val_bytes)
                .map(|m| m.expires_at)
                .unwrap_or(0);
            if expires_at <= now {
                expired.push(suffix.to_string());
            }
        }

        let mut removed = 0u64;
        for did_fid in expired {
            let mut batch = WriteBatch::default();
            batch.delete(format!("{EPH_META_PREFIX}{did_fid}").as_bytes());
            // Все чанки файла: префикс `eph:<did>:<fid>:`.
            let chunk_prefix = format!("{EPH_CHUNK_PREFIX}{did_fid}:");
            let iter = self.db.iterator(IteratorMode::From(
                chunk_prefix.as_bytes(),
                rocksdb::Direction::Forward,
            ));
            for item in iter {
                let (key_bytes, _) = item.context("RocksDB iterator error")?;
                let key_str = std::str::from_utf8(&key_bytes).context("Non-UTF8 key")?;
                if !key_str.starts_with(&chunk_prefix) {
                    break;
                }
                batch.delete(key_bytes);
            }
            self.db.write(batch).context("RocksDB ephemeral reap failed")?;
            removed += 1;
        }
        Ok(removed)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct EphemeralMeta {
    pub chunk_count: u32,
    pub total_size: u64,
    pub expires_at: u64,
}

const EPH_CHUNK_PREFIX: &str = "eph:";
const EPH_META_PREFIX: &str = "ephmeta:";

fn make_eph_chunk_key(dialogue_id: &str, file_id: &str, chunk_index: u32) -> String {
    format!("{EPH_CHUNK_PREFIX}{dialogue_id}:{file_id}:{chunk_index:020}")
}

fn make_eph_meta_key(dialogue_id: &str, file_id: &str) -> String {
    format!("{EPH_META_PREFIX}{dialogue_id}:{file_id}")
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    static TEST_COUNTER: AtomicU64 = AtomicU64::new(0);

    struct TempStoreDir(PathBuf);

    impl TempStoreDir {
        fn new() -> Self {
            let dir = std::env::temp_dir().join(format!(
                "paranoia-store-test-{}-{}",
                std::process::id(),
                TEST_COUNTER.fetch_add(1, Ordering::Relaxed)
            ));
            let _ = std::fs::remove_dir_all(&dir);
            Self(dir)
        }
    }

    impl Drop for TempStoreDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn open_store() -> (TempStoreDir, PacketStore) {
        let tmp = TempStoreDir::new();
        let store = PacketStore::open(tmp.0.to_str().unwrap()).expect("open store");
        (tmp, store)
    }

    fn push_seqs(store: &PacketStore, dialogue: &str, seqs: &[u64]) {
        for &seq in seqs {
            store.push(dialogue, seq, &[0xAB]).expect("push");
        }
    }

    #[test]
    fn ephemeral_roundtrip_and_ttl() {
        let (_tmp, store) = open_store();
        let did = "a".repeat(64);
        let fid = "f00dfeed";
        // Свежий файл (TTL час): мета и чанк доступны.
        store
            .ephemeral_put_chunk(&did, fid, 0, 2, 1000, b"chunk-zero", 3600)
            .expect("put");
        store
            .ephemeral_put_chunk(&did, fid, 1, 2, 1000, b"chunk-one", 3600)
            .expect("put");
        let meta = store.ephemeral_meta(&did, fid).unwrap().expect("meta");
        assert_eq!(meta.chunk_count, 2);
        assert_eq!(meta.total_size, 1000);
        assert_eq!(
            store.ephemeral_get_chunk(&did, fid, 0).unwrap().as_deref(),
            Some(&b"chunk-zero"[..])
        );

        // Эфемерные ключи не попадают в перечисление диалогов (не история).
        assert!(store.list_dialogues().unwrap().is_empty());

        // Просроченный файл (TTL=0): мета/чанки уже недоступны, reaper их удаляет.
        let did2 = "b".repeat(64);
        store
            .ephemeral_put_chunk(&did2, "dead", 0, 1, 4, b"gone", 0)
            .expect("put");
        assert!(store.ephemeral_meta(&did2, "dead").unwrap().is_none());
        assert!(store.ephemeral_get_chunk(&did2, "dead", 0).unwrap().is_none());
        let removed = store.ephemeral_reap().unwrap();
        assert_eq!(removed, 1, "reaper удаляет один просроченный файл");
        // Не-просроченный файл reaper не трогает.
        assert!(store.ephemeral_meta(&did, fid).unwrap().is_some());
    }

    #[test]
    fn map_empty_dialogue() {
        let (_tmp, store) = open_store();
        let res = store.map("dlg", 0, 0, 8192).unwrap();
        assert!(res.runs.is_empty());
        assert_eq!(res.last_seq, 0);
        assert!(!res.truncated);
    }

    #[test]
    fn map_contiguous_run() {
        let (_tmp, store) = open_store();
        push_seqs(&store, "dlg", &[1, 2, 3, 4, 5]);
        let res = store.map("dlg", 0, 0, 8192).unwrap();
        assert_eq!(res.runs, vec![(1, 5)]);
        assert_eq!(res.last_seq, 5);
        assert!(!res.truncated);
    }

    #[test]
    fn map_collapses_runs_around_gaps() {
        let (_tmp, store) = open_store();
        push_seqs(&store, "dlg", &[1, 2, 3, 7, 8, 12]);
        let res = store.map("dlg", 0, 0, 8192).unwrap();
        assert_eq!(res.runs, vec![(1, 3), (7, 8), (12, 12)]);
        assert_eq!(res.last_seq, 12);
        assert!(!res.truncated);
    }

    #[test]
    fn map_respects_after_seq() {
        let (_tmp, store) = open_store();
        push_seqs(&store, "dlg", &[1, 2, 3, 7, 8, 12]);
        let res = store.map("dlg", 3, 0, 8192).unwrap();
        assert_eq!(res.runs, vec![(7, 8), (12, 12)]);
        assert_eq!(res.last_seq, 12);
    }

    #[test]
    fn map_respects_to_seq_upper_bound() {
        let (_tmp, store) = open_store();
        push_seqs(&store, "dlg", &[1, 2, 3, 7, 8, 12]);
        let res = store.map("dlg", 0, 8, 8192).unwrap();
        assert_eq!(res.runs, vec![(1, 3), (7, 8)]);
        // last_seq отражает весь диалог, а не запрошенный диапазон.
        assert_eq!(res.last_seq, 12);
    }

    #[test]
    fn map_to_seq_clips_run_in_the_middle() {
        let (_tmp, store) = open_store();
        push_seqs(&store, "dlg", &[5, 6, 7, 8, 9]);
        let res = store.map("dlg", 4, 7, 8192).unwrap();
        assert_eq!(res.runs, vec![(5, 7)]);
        assert_eq!(res.last_seq, 9);
    }

    #[test]
    fn map_truncates_when_runs_exceed_limit() {
        let (_tmp, store) = open_store();
        // 5 runs: 1, 3, 5, 7, 9
        push_seqs(&store, "dlg", &[1, 3, 5, 7, 9]);
        let res = store.map("dlg", 0, 0, 3).unwrap();
        assert_eq!(res.runs, vec![(1, 1), (3, 3), (5, 5)]);
        assert!(res.truncated);
        assert_eq!(res.last_seq, 9);
    }

    #[test]
    fn map_does_not_mix_dialogues() {
        let (_tmp, store) = open_store();
        push_seqs(&store, "dlg-a", &[1, 2, 3]);
        push_seqs(&store, "dlg-b", &[1, 2, 3]);
        let res = store.map("dlg-a", 0, 0, 8192).unwrap();
        assert_eq!(res.runs, vec![(1, 3)]);
        assert_eq!(res.last_seq, 3);
    }

    #[test]
    fn map_rejects_reversed_range() {
        let (_tmp, store) = open_store();
        push_seqs(&store, "dlg", &[1, 2, 3]);
        assert!(store.map("dlg", 5, 3, 8192).is_err());
    }

    #[test]
    fn map_handles_to_seq_equal_to_after_seq_as_error() {
        let (_tmp, store) = open_store();
        push_seqs(&store, "dlg", &[1, 2, 3]);
        assert!(store.map("dlg", 3, 3, 8192).is_err());
    }

    #[test]
    fn map_with_max_cursor_returns_empty() {
        let (_tmp, store) = open_store();
        push_seqs(&store, "dlg", &[1, 2, 3]);
        let res = store.map("dlg", u64::MAX, 0, 8192).unwrap();
        assert!(res.runs.is_empty());
        assert_eq!(res.last_seq, 3);
    }

    #[test]
    fn last_seq_returns_max_for_dialogue() {
        let (_tmp, store) = open_store();
        push_seqs(&store, "dlg", &[1, 5, 99]);
        push_seqs(&store, "dlh", &[1, 200]); // соседний по lex префикс
        assert_eq!(store.last_seq("dlg").unwrap(), 99);
        assert_eq!(store.last_seq("dlh").unwrap(), 200);
    }

    #[test]
    fn last_seq_returns_zero_for_empty() {
        let (_tmp, store) = open_store();
        assert_eq!(store.last_seq("dlg").unwrap(), 0);
    }

    #[test]
    fn pull_rejects_open_ended_to_seq() {
        let (_tmp, store) = open_store();
        push_seqs(&store, "dlg", &[1, 2, 3]);
        assert!(store.pull("dlg", 0, 0).is_err());
    }

    #[test]
    fn pull_rejects_reversed_range() {
        let (_tmp, store) = open_store();
        push_seqs(&store, "dlg", &[1, 2, 3]);
        assert!(store.pull("dlg", 5, 3).is_err());
    }

    #[test]
    fn pull_rejects_equal_bounds() {
        let (_tmp, store) = open_store();
        push_seqs(&store, "dlg", &[1, 2, 3]);
        assert!(store.pull("dlg", 3, 3).is_err());
    }

    #[test]
    fn pull_returns_bounded_range() {
        let (_tmp, store) = open_store();
        push_seqs(&store, "dlg", &[1, 2, 3, 4, 5]);
        let res = store.pull("dlg", 1, 4).unwrap();
        let seqs: Vec<u64> = res.into_iter().map(|(s, _)| s).collect();
        assert_eq!(seqs, vec![2, 3, 4]);
    }

    #[test]
    fn pull_skips_holes() {
        let (_tmp, store) = open_store();
        push_seqs(&store, "dlg", &[1, 5, 10]);
        let res = store.pull("dlg", 0, 7).unwrap();
        let seqs: Vec<u64> = res.into_iter().map(|(s, _)| s).collect();
        assert_eq!(seqs, vec![1, 5]);
    }

    #[test]
    fn remove_range_inclusive() {
        let (_tmp, store) = open_store();
        push_seqs(&store, "dlg", &[1, 2, 3, 4, 5]);
        store.remove_range("dlg", 2, 4).unwrap();
        let res = store.map("dlg", 0, 0, 8192).unwrap();
        assert_eq!(res.runs, vec![(1, 1), (5, 5)]);
    }

    #[test]
    fn remove_range_from_zero_means_from_start() {
        let (_tmp, store) = open_store();
        push_seqs(&store, "dlg", &[1, 2, 3, 4, 5]);
        store.remove_range("dlg", 0, 3).unwrap();
        let res = store.map("dlg", 0, 0, 8192).unwrap();
        assert_eq!(res.runs, vec![(4, 5)]);
    }

    #[test]
    fn remove_range_does_not_touch_other_dialogues() {
        let (_tmp, store) = open_store();
        push_seqs(&store, "dlg-a", &[1, 2, 3]);
        push_seqs(&store, "dlg-b", &[1, 2, 3]);
        store.remove_range("dlg-a", 0, 100).unwrap();
        assert_eq!(store.last_seq("dlg-a").unwrap(), 0);
        assert_eq!(store.last_seq("dlg-b").unwrap(), 3);
    }

    #[test]
    fn list_dialogues_reports_each_dialogue_with_last_seq() {
        let (_tmp, store) = open_store();
        // Используем валидные hex dialogue_id (фиксированная длина, как в проде).
        let a = "a".repeat(64);
        let b = "b".repeat(64);
        push_seqs(&store, &a, &[1, 2, 3, 7]);
        push_seqs(&store, &b, &[1, 5]);
        // Служебный receipt-ключ не должен попадать в список диалогов.
        store
            .set_receipts_enabled("alice", &a, true)
            .expect("receipt");

        let mut got = store.list_dialogues().unwrap();
        got.sort();
        // По 1 байту (0xAB) на пакет: у `a` — 4 пакета, у `b` — 2.
        assert_eq!(got, vec![(a.clone(), 7, 4), (b.clone(), 5, 2)]);
    }

    #[test]
    fn list_dialogues_empty_store() {
        let (_tmp, store) = open_store();
        assert!(store.list_dialogues().unwrap().is_empty());
    }
}
