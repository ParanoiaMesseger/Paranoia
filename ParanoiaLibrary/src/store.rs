use crate::types::{AttachmentKind, DialogueKey, Message, MessageStatus};
use anyhow::{anyhow, Result};
use chrono::{DateTime, Utc};
use rusqlite::{Connection, OptionalExtension, params};
use std::sync::{Mutex, MutexGuard};

/// Запись журнала исходящей файловой передачи (resumable transfers). Хранится
/// у отправителя, пока тело файла не доставлено на сервер целиком; позволяет
/// до-слать недостающие чанки после обрыва. См. таблицу `outbound_transfers`.
#[derive(Debug, Clone)]
pub struct OutboundTransfer {
    pub transfer_id: String,
    pub dialogue: DialogueKey,
    pub header_seq: u64,
    pub chunk_count: u32,
    pub chunk_sizes: Vec<usize>,
    pub cache_path: String,
    pub filename: String,
    pub mime_type: String,
    pub kind: AttachmentKind,
    pub total_size: usize,
    pub group_id: Option<String>,
    pub timestamp: DateTime<Utc>,
    pub attempts: u32,
}

pub struct LocalStore {
    pub(crate) conn: Mutex<Connection>,
}

impl LocalStore {
    /// Открыть базу данных в режиме SQLCipher.
    /// Параметры по политике (LocalStorageEncryptionPolicy.md §5.2):
    /// - PRAGMA key = "x'<hex-32B>'"
    /// - PRAGMA cipher_page_size = 4096
    /// - PRAGMA kdf_iter = 1  (внешний KDF — Argon2id)
    /// - PRAGMA cipher_hmac_algorithm = HMAC_SHA512
    pub fn open(path: &str, db_key: &[u8; 32]) -> Result<Self> {
        let conn = Connection::open(path)?;
        // ВАЖНО: cipher_* параметры ДОЛЖНЫ быть выставлены ДО PRAGMA key.
        // SQLCipher применяет page_size/kdf_iter/hmac_algorithm к шифрованию
        // header'а в момент derive ключа; если их установить после key —
        // они либо игнорируются (для существующего файла) либо приводят к
        // несовместимости с заявленной политикой §5.2.
        conn.execute_batch(
            "PRAGMA cipher_page_size = 4096;\
             PRAGMA kdf_iter = 1;\
             PRAGMA cipher_hmac_algorithm = HMAC_SHA512;",
        )?;
        let key_pragma = format!("PRAGMA key = \"x'{}'\";", hex::encode(db_key));
        conn.execute_batch(&key_pragma)
            .map_err(|e| anyhow!("sqlcipher key: {e}"))?;
        conn.execute_batch("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")?;
        // Проверка ключа: первая операция чтения упадёт если ключ неверный.
        conn.query_row("SELECT count(*) FROM sqlite_master;", [], |_| Ok(()))
            .map_err(|e| anyhow!("sqlcipher key verification failed: {e}"))?;
        let store = Self {
            conn: Mutex::new(conn),
        };
        store.migrate()?;
        Ok(store)
    }

    fn conn(&self) -> Result<MutexGuard<'_, Connection>> {
        self.conn
            .lock()
            .map_err(|_| anyhow::anyhow!("local store mutex poisoned"))
    }

    fn migrate(&self) -> Result<()> {
        let conn = self.conn()?;
        conn.execute_batch(
            "
            CREATE TABLE IF NOT EXISTS messages (
                id          TEXT PRIMARY KEY,
                dialogue_a  TEXT NOT NULL,
                dialogue_b  TEXT NOT NULL,
                sender      TEXT NOT NULL,
                content     TEXT NOT NULL,
                timestamp   TEXT NOT NULL,
                status      TEXT NOT NULL,
                server_seq  INTEGER
            );

            CREATE INDEX IF NOT EXISTS idx_dialogue_ts
                ON messages (dialogue_a, dialogue_b, timestamp);

            CREATE INDEX IF NOT EXISTS idx_dialogue_seq
                ON messages (dialogue_a, dialogue_b, server_seq);

            -- seq -> message_id маппинг для read receipts
            CREATE TABLE IF NOT EXISTS seq_map (
                dialogue_a TEXT    NOT NULL,
                dialogue_b TEXT    NOT NULL,
                server_seq INTEGER NOT NULL,
                message_id TEXT    NOT NULL,
                PRIMARY KEY (dialogue_a, dialogue_b, server_seq)
            );

            -- Состояние диалога
            -- next_send_seq — атомарный счётчик отправки
            CREATE TABLE IF NOT EXISTS dialogue_state (
                dialogue_a      TEXT    NOT NULL,
                dialogue_b      TEXT    NOT NULL,
                last_pulled_seq INTEGER NOT NULL DEFAULT 0,
                next_send_seq   INTEGER NOT NULL DEFAULT 1,
                PRIMARY KEY (dialogue_a, dialogue_b)
            );

            -- Входящие чанки, ожидающие сборки
            CREATE TABLE IF NOT EXISTS incoming_chunks (
                transfer_id TEXT    NOT NULL,
                dialogue_a  TEXT    NOT NULL,
                dialogue_b  TEXT    NOT NULL,
                sender      TEXT    NOT NULL,
                chunk_index INTEGER NOT NULL,
                total       INTEGER NOT NULL,
                filename    TEXT    NOT NULL,
                mime_type   TEXT    NOT NULL,
                total_size  INTEGER NOT NULL,
                data        BLOB    NOT NULL,
                timestamp   TEXT    NOT NULL,
                PRIMARY KEY (transfer_id, chunk_index)
            );

            -- Журнал ИСХОДЯЩИХ файловых передач для возобновления (resumable
            -- transfers). Строка живёт, пока тело файла не доставлено на сервер
            -- полностью; при обрыве (выход из диалога, потеря сети, рестарт)
            -- фоновый resume до-сылает недостающие seq, нарезая файл по
            -- сохранённым chunk_sizes (идентичные границы). Только у отправителя,
            -- в wire-пакеты не попадает. transfer_id == id отображаемого сообщения.
            CREATE TABLE IF NOT EXISTS outbound_transfers (
                transfer_id TEXT    PRIMARY KEY,
                dialogue_a  TEXT    NOT NULL,
                dialogue_b  TEXT    NOT NULL,
                header_seq  INTEGER NOT NULL,
                chunk_count INTEGER NOT NULL,
                chunk_sizes TEXT    NOT NULL,
                cache_path  TEXT    NOT NULL,
                filename    TEXT    NOT NULL,
                mime_type   TEXT    NOT NULL,
                kind        TEXT    NOT NULL,
                total_size  INTEGER NOT NULL,
                group_id    TEXT,
                timestamp   TEXT    NOT NULL,
                attempts    INTEGER NOT NULL DEFAULT 0
            );
        ",
        )?;
        Ok(())
    }

    // ── seq management ────────────────────────────────────────────────────

    /// Атомарно получить следующий локально известный seq и инкрементировать счётчик.
    /// Перед отправкой Dialogue синхронизирует last_pulled_seq через серверный pull.
    pub fn next_send_seq(&self, dialogue: &DialogueKey) -> Result<u64> {
        let conn = self.conn()?;
        // Upsert — создаём запись если нет, иначе инкрементируем
        conn.execute(
            "INSERT INTO dialogue_state (dialogue_a, dialogue_b, last_pulled_seq, next_send_seq)
             VALUES (?1, ?2, 0, 2)
             ON CONFLICT(dialogue_a, dialogue_b)
             DO UPDATE SET next_send_seq = next_send_seq + 1",
            params![dialogue.a, dialogue.b],
        )?;
        // Читаем только что выданный seq (до инкремента = текущий - 1)
        // Используем last_insert_rowid trick через returning или просто читаем
        let seq: i64 = conn.query_row(
            "SELECT next_send_seq - 1 FROM dialogue_state
             WHERE dialogue_a = ?1 AND dialogue_b = ?2",
            params![dialogue.a, dialogue.b],
            |r| r.get(0),
        )?;
        Ok(seq as u64)
    }

    /// Зарезервировать непрерывный диапазон исходящих seq.
    /// Возвращает первый seq диапазона.
    pub fn reserve_send_seq_range(&self, dialogue: &DialogueKey, count: u64) -> Result<u64> {
        if count == 0 {
            anyhow::bail!("empty seq range");
        }

        let conn = self.conn()?;
        conn.execute(
            "INSERT INTO dialogue_state (dialogue_a, dialogue_b, last_pulled_seq, next_send_seq)
             VALUES (?1, ?2, 0, 1)
             ON CONFLICT(dialogue_a, dialogue_b) DO NOTHING",
            params![dialogue.a, dialogue.b],
        )?;

        let start_seq: i64 = conn.query_row(
            "SELECT next_send_seq FROM dialogue_state
             WHERE dialogue_a = ?1 AND dialogue_b = ?2",
            params![dialogue.a, dialogue.b],
            |r| r.get(0),
        )?;
        let end_next = (start_seq as u64)
            .checked_add(count)
            .ok_or_else(|| anyhow::anyhow!("seq range overflow"))?;

        conn.execute(
            "UPDATE dialogue_state
             SET next_send_seq = ?3
             WHERE dialogue_a = ?1 AND dialogue_b = ?2",
            params![dialogue.a, dialogue.b, end_next as i64],
        )?;
        Ok(start_seq as u64)
    }

    pub fn get_last_pulled_seq(&self, dialogue: &DialogueKey) -> Result<u64> {
        let conn = self.conn()?;
        let seq: Option<i64> = conn
            .query_row(
                "SELECT last_pulled_seq FROM dialogue_state
             WHERE dialogue_a = ?1 AND dialogue_b = ?2",
                params![dialogue.a, dialogue.b],
                |r| r.get(0),
            )
            .ok();
        Ok(seq.unwrap_or(0) as u64)
    }

    pub fn set_last_pulled_seq(&self, dialogue: &DialogueKey, seq: u64) -> Result<()> {
        let conn = self.conn()?;
        conn.execute(
            "INSERT INTO dialogue_state (dialogue_a, dialogue_b, last_pulled_seq, next_send_seq)
             VALUES (?1, ?2, ?3, ?3 + 1)
             ON CONFLICT(dialogue_a, dialogue_b)
             DO UPDATE SET
                last_pulled_seq = MAX(dialogue_state.last_pulled_seq, excluded.last_pulled_seq),
                next_send_seq = MAX(dialogue_state.next_send_seq, excluded.last_pulled_seq + 1)",
            params![dialogue.a, dialogue.b, seq as i64],
        )?;
        Ok(())
    }

    // ── messages ──────────────────────────────────────────────────────────

    pub fn save_message(&self, msg: &Message) -> Result<()> {
        let conn = self.conn()?;
        let content_json = serde_json::to_string(&msg.content)?;
        conn.execute(
            "INSERT OR REPLACE INTO messages
             (id, dialogue_a, dialogue_b, sender, content, timestamp, status, server_seq)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![
                msg.id,
                msg.dialogue.a,
                msg.dialogue.b,
                msg.sender,
                content_json,
                msg.timestamp.to_rfc3339(),
                serde_json::to_string(&msg.status)?,
                msg.server_seq.map(|s| s as i64),
            ],
        )?;
        if let Some(seq) = msg.server_seq {
            conn.execute(
                "INSERT OR IGNORE INTO seq_map
                 (dialogue_a, dialogue_b, server_seq, message_id)
                 VALUES (?1, ?2, ?3, ?4)",
                params![msg.dialogue.a, msg.dialogue.b, seq as i64, msg.id],
            )?;
        }
        Ok(())
    }

    pub fn update_status(&self, message_id: &str, status: MessageStatus) -> Result<()> {
        let conn = self.conn()?;
        conn.execute(
            "UPDATE messages SET status = ?1 WHERE id = ?2",
            params![serde_json::to_string(&status)?, message_id],
        )?;
        Ok(())
    }

    // ── outbound transfers (resumable file sends) ─────────────────────────────

    /// Записать/обновить журнал исходящей передачи (idempotent по transfer_id).
    pub fn insert_outbound(&self, t: &OutboundTransfer) -> Result<()> {
        let conn = self.conn()?;
        conn.execute(
            "INSERT OR REPLACE INTO outbound_transfers
             (transfer_id, dialogue_a, dialogue_b, header_seq, chunk_count, chunk_sizes,
              cache_path, filename, mime_type, kind, total_size, group_id, timestamp, attempts)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)",
            params![
                t.transfer_id,
                t.dialogue.a,
                t.dialogue.b,
                t.header_seq as i64,
                t.chunk_count as i64,
                serde_json::to_string(&t.chunk_sizes)?,
                t.cache_path,
                t.filename,
                t.mime_type,
                serde_json::to_string(&t.kind)?,
                t.total_size as i64,
                t.group_id,
                t.timestamp.to_rfc3339(),
                t.attempts as i64,
            ],
        )?;
        Ok(())
    }

    /// Все незавершённые исходящие передачи диалога (для resume).
    pub fn list_outbound(&self, dialogue: &DialogueKey) -> Result<Vec<OutboundTransfer>> {
        let conn = self.conn()?;
        let mut stmt = conn.prepare(
            "SELECT transfer_id, header_seq, chunk_count, chunk_sizes, cache_path, filename,
                    mime_type, kind, total_size, group_id, timestamp, attempts
             FROM outbound_transfers
             WHERE dialogue_a = ?1 AND dialogue_b = ?2
             ORDER BY header_seq ASC",
        )?;
        let dlg = dialogue.clone();
        let rows = stmt.query_map(params![dialogue.a, dialogue.b], move |row| {
            let chunk_sizes_json: String = row.get(3)?;
            let kind_json: String = row.get(7)?;
            let ts_str: String = row.get(10)?;
            Ok(OutboundTransfer {
                transfer_id: row.get(0)?,
                dialogue: dlg.clone(),
                header_seq: row.get::<_, i64>(1)? as u64,
                chunk_count: row.get::<_, i64>(2)? as u32,
                chunk_sizes: serde_json::from_str(&chunk_sizes_json).unwrap_or_default(),
                cache_path: row.get(4)?,
                filename: row.get(5)?,
                mime_type: row.get(6)?,
                kind: serde_json::from_str(&kind_json).unwrap_or(AttachmentKind::File),
                total_size: row.get::<_, i64>(8)? as usize,
                group_id: row.get(9)?,
                timestamp: DateTime::parse_from_rfc3339(&ts_str)
                    .map(|d| d.with_timezone(&Utc))
                    .unwrap_or_else(|_| Utc::now()),
                attempts: row.get::<_, i64>(11)? as u32,
            })
        })?;
        rows.collect::<rusqlite::Result<Vec<_>>>().map_err(Into::into)
    }

    pub fn delete_outbound(&self, transfer_id: &str) -> Result<()> {
        let conn = self.conn()?;
        conn.execute(
            "DELETE FROM outbound_transfers WHERE transfer_id = ?1",
            params![transfer_id],
        )?;
        Ok(())
    }

    /// Увеличить счётчик попыток resume; вернуть новое значение.
    pub fn bump_outbound_attempts(&self, transfer_id: &str) -> Result<u32> {
        let conn = self.conn()?;
        conn.execute(
            "UPDATE outbound_transfers SET attempts = attempts + 1 WHERE transfer_id = ?1",
            params![transfer_id],
        )?;
        let n: i64 = conn
            .query_row(
                "SELECT attempts FROM outbound_transfers WHERE transfer_id = ?1",
                params![transfer_id],
                |r| r.get(0),
            )
            .optional()?
            .unwrap_or(0);
        Ok(n as u32)
    }

    /// Вернуть все server_seq у локальных сообщений диалога, у которых статус
    /// уже подтверждён сервером (Delivered/Read). Использует tombstone sweep
    /// в `Dialogue::receive`, чтобы не задеть наши же исходящие в полёте.
    pub fn get_delivered_server_seqs(&self, dialogue: &DialogueKey) -> Result<Vec<u64>> {
        let conn = self.conn()?;
        let delivered_json = serde_json::to_string(&MessageStatus::Delivered)?;
        let read_json = serde_json::to_string(&MessageStatus::Read)?;
        let mut stmt = conn.prepare(
            "SELECT server_seq
             FROM messages
             WHERE dialogue_a = ?1
               AND dialogue_b = ?2
               AND server_seq IS NOT NULL
               AND status IN (?3, ?4)",
        )?;
        let rows = stmt.query_map(
            params![dialogue.a, dialogue.b, delivered_json, read_json],
            |row| row.get::<_, i64>(0).map(|v| v as u64),
        )?;
        rows.collect::<rusqlite::Result<Vec<u64>>>()
            .map_err(Into::into)
    }

    /// Удалить локальные сообщения по конкретному списку `server_seq`.
    /// Пустой список — no-op.
    pub fn delete_messages_by_seqs(
        &self,
        dialogue: &DialogueKey,
        seqs: &[u64],
    ) -> Result<()> {
        if seqs.is_empty() {
            return Ok(());
        }
        let conn = self.conn()?;
        let mut del_msg = conn.prepare(
            "DELETE FROM messages
             WHERE dialogue_a = ?1
               AND dialogue_b = ?2
               AND server_seq = ?3",
        )?;
        let mut del_map = conn.prepare(
            "DELETE FROM seq_map
             WHERE dialogue_a = ?1
               AND dialogue_b = ?2
               AND server_seq = ?3",
        )?;
        for &seq in seqs {
            del_msg.execute(params![dialogue.a, dialogue.b, seq as i64])?;
            del_map.execute(params![dialogue.a, dialogue.b, seq as i64])?;
        }
        Ok(())
    }

    pub fn delete_messages_until(&self, dialogue: &DialogueKey, cut_seq: u64) -> Result<()> {
        let conn = self.conn()?;
        conn.execute(
            "DELETE FROM messages
             WHERE dialogue_a = ?1
               AND dialogue_b = ?2
               AND server_seq IS NOT NULL
               AND server_seq <= ?3",
            params![dialogue.a, dialogue.b, cut_seq as i64],
        )?;
        conn.execute(
            "DELETE FROM seq_map
             WHERE dialogue_a = ?1
               AND dialogue_b = ?2
               AND server_seq <= ?3",
            params![dialogue.a, dialogue.b, cut_seq as i64],
        )?;
        Ok(())
    }

    /// Батч READ RECEIPT: помечаем все сообщения с server_seq <= up_to_seq как Read.
    pub fn mark_read_until(&self, dialogue: &DialogueKey, up_to_seq: u64) -> Result<usize> {
        let conn = self.conn()?;
        let read_json = serde_json::to_string(&MessageStatus::Read)?;
        let sent_json = serde_json::to_string(&MessageStatus::Sent)?;
        let delivered_json = serde_json::to_string(&MessageStatus::Delivered)?;
        let count = conn.execute(
            "UPDATE messages
             SET status = ?1
             WHERE dialogue_a = ?2
               AND dialogue_b = ?3
               AND server_seq <= ?4
               AND status IN (?5, ?6)",
            params![
                read_json,
                dialogue.a,
                dialogue.b,
                up_to_seq as i64,
                sent_json,
                delivered_json,
            ],
        )?;
        Ok(count)
    }

    pub fn mark_outgoing_read_until(
        &self,
        dialogue: &DialogueKey,
        sender: &str,
        up_to_seq: u64,
    ) -> Result<usize> {
        let conn = self.conn()?;
        let read_json = serde_json::to_string(&MessageStatus::Read)?;
        let sent_json = serde_json::to_string(&MessageStatus::Sent)?;
        let delivered_json = serde_json::to_string(&MessageStatus::Delivered)?;
        let count = conn.execute(
            "UPDATE messages
             SET status = ?1
             WHERE dialogue_a = ?2
               AND dialogue_b = ?3
               AND sender = ?4
               AND server_seq <= ?5
               AND status IN (?6, ?7)",
            params![
                read_json,
                dialogue.a,
                dialogue.b,
                sender,
                up_to_seq as i64,
                sent_json,
                delivered_json,
            ],
        )?;
        Ok(count)
    }

    pub fn latest_outgoing_status(
        &self,
        dialogue: &DialogueKey,
        sender: &str,
    ) -> Result<Option<(u64, MessageStatus)>> {
        let conn = self.conn()?;
        conn.query_row(
            "SELECT server_seq, status
             FROM messages
             WHERE dialogue_a = ?1
               AND dialogue_b = ?2
               AND sender = ?3
               AND server_seq IS NOT NULL
             ORDER BY server_seq DESC
             LIMIT 1",
            params![dialogue.a, dialogue.b, sender],
            |row| {
                let seq = row.get::<_, i64>(0)?;
                let status_json = row.get::<_, String>(1)?;
                let status = serde_json::from_str(&status_json).map_err(|err| {
                    rusqlite::Error::FromSqlConversionFailure(
                        1,
                        rusqlite::types::Type::Text,
                        Box::new(err),
                    )
                })?;
                Ok((seq as u64, status))
            },
        )
        .optional()
        .map_err(Into::into)
    }

    pub fn get_message_by_seq(&self, dialogue: &DialogueKey, seq: u64) -> Result<Option<String>> {
        let conn = self.conn()?;
        Ok(conn
            .query_row(
                "SELECT id
              FROM messages
              WHERE dialogue_a = ?1
                AND dialogue_b = ?2
                AND server_seq = ?3
              LIMIT 1",
                params![dialogue.a, dialogue.b, seq as i64],
                |r| r.get(0),
            )
            .optional()?)
    }

    pub fn get_messages(
        &self,
        dialogue: &DialogueKey,
        limit: usize,
        before: Option<DateTime<Utc>>,
    ) -> Result<Vec<Message>> {
        let conn = self.conn()?;
        let before_str = before.unwrap_or_else(Utc::now).to_rfc3339();
        let mut stmt = conn.prepare(
            "SELECT id, sender, content, timestamp, status, server_seq
             FROM messages
             WHERE dialogue_a = ?1
               AND dialogue_b = ?2
               AND timestamp < ?3
             ORDER BY timestamp DESC
             LIMIT ?4",
        )?;
        let rows = stmt.query_map(
            params![dialogue.a, dialogue.b, before_str, limit as i64],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, Option<i64>>(5)?,
                ))
            },
        )?;
        let mut messages = Vec::new();
        for row in rows {
            // Пропускаем непарсящиеся строки, а не валим всю выборку: одно битое/
            // старое сообщение не должно «прятать» весь остальной диалог (иначе при
            // большом лимите вся история падала в Err → пустой результат).
            let (id, sender, content_json, ts_str, status_json, seq) = match row {
                Ok(v) => v,
                Err(_) => continue,
            };
            let content = match serde_json::from_str(&content_json) {
                Ok(c) => c,
                Err(_) => continue,
            };
            let timestamp = match ts_str.parse::<DateTime<Utc>>() {
                Ok(t) => t,
                Err(_) => continue,
            };
            let status = match serde_json::from_str(&status_json) {
                Ok(s) => s,
                Err(_) => continue,
            };
            messages.push(Message {
                id,
                dialogue: dialogue.clone(),
                sender,
                content,
                timestamp,
                status,
                server_seq: seq.map(|s| s as u64),
            });
        }
        messages.reverse();
        Ok(messages)
    }

    pub fn get_message_by_id(
        &self,
        dialogue: &DialogueKey,
        message_id: &str,
    ) -> Result<Option<Message>> {
        let conn = self.conn()?;
        let row = conn
            .query_row(
                "SELECT id, sender, content, timestamp, status, server_seq
                 FROM messages
                 WHERE dialogue_a = ?1
                   AND dialogue_b = ?2
                   AND id = ?3
                 LIMIT 1",
                params![dialogue.a, dialogue.b, message_id],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, String>(3)?,
                        row.get::<_, String>(4)?,
                        row.get::<_, Option<i64>>(5)?,
                    ))
                },
            )
            .optional()?;

        row.map(|(id, sender, content_json, ts_str, status_json, seq)| {
            Ok(Message {
                id,
                dialogue: dialogue.clone(),
                sender,
                content: serde_json::from_str(&content_json)?,
                timestamp: ts_str.parse::<DateTime<Utc>>()?,
                status: serde_json::from_str(&status_json)?,
                server_seq: seq.map(|s| s as u64),
            })
        })
        .transpose()
    }

    // ── dialogue deletion ─────────────────────────────────────────────────

    /// Удалить все локальные данные диалога из SQLite.
    pub fn delete_dialogue(&self, dialogue: &DialogueKey) -> Result<()> {
        let conn = self.conn()?;
        for table in ["messages", "seq_map", "dialogue_state", "incoming_chunks"] {
            conn.execute(
                &format!("DELETE FROM {table} WHERE dialogue_a = ?1 AND dialogue_b = ?2"),
                params![dialogue.a, dialogue.b],
            )?;
        }
        Ok(())
    }

    // ── chunks ────────────────────────────────────────────────────────────

    pub fn save_chunk(
        &self,
        transfer_id: &str,
        dialogue: &DialogueKey,
        sender: &str,
        index: u32,
        total: u32,
        filename: &str,
        mime_type: &str,
        total_size: usize,
        data: &[u8],
        timestamp: DateTime<Utc>,
    ) -> Result<()> {
        let conn = self.conn()?;
        conn.execute(
            "INSERT OR IGNORE INTO incoming_chunks
             (transfer_id, dialogue_a, dialogue_b, sender, chunk_index,
              total, filename, mime_type, total_size, data, timestamp)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)",
            params![
                transfer_id,
                dialogue.a,
                dialogue.b,
                sender,
                index as i64,
                total as i64,
                filename,
                mime_type,
                total_size as i64,
                data,
                timestamp.to_rfc3339(),
            ],
        )?;
        Ok(())
    }

    /// Проверить, все ли чанки получены. Если да — собрать и вернуть FileAttachment.
    pub fn try_assemble_chunks(
        &self,
        transfer_id: &str,
        dialogue: &DialogueKey,
    ) -> Result<Option<AssembledFile>> {
        let conn = self.conn()?;

        // Считаем сколько чанков уже есть
        let (count, total, filename, mime_type, total_size, sender, timestamp): (
            i64,
            i64,
            String,
            String,
            i64,
            String,
            String,
        ) = conn.query_row(
            "SELECT COUNT(*), MAX(total), MAX(filename), MAX(mime_type),
                    MAX(total_size), MAX(sender), MIN(timestamp)
             FROM incoming_chunks
             WHERE transfer_id = ?1 AND dialogue_a = ?2 AND dialogue_b = ?3",
            params![transfer_id, dialogue.a, dialogue.b],
            |r| {
                Ok((
                    r.get(0)?,
                    r.get(1)?,
                    r.get(2)?,
                    r.get(3)?,
                    r.get(4)?,
                    r.get(5)?,
                    r.get(6)?,
                ))
            },
        )?;

        if count < total {
            return Ok(None); // ещё не все чанки
        }

        // Читаем все чанки в порядке index
        let mut stmt = conn.prepare(
            "SELECT data FROM incoming_chunks
             WHERE transfer_id = ?1 AND dialogue_a = ?2 AND dialogue_b = ?3
             ORDER BY chunk_index ASC",
        )?;
        let chunks: Vec<Vec<u8>> = stmt
            .query_map(params![transfer_id, dialogue.a, dialogue.b], |r| r.get(0))?
            .collect::<rusqlite::Result<_>>()?;

        let mut assembled = Vec::with_capacity(total_size as usize);
        chunks.into_iter().for_each(|chunk| assembled.extend(chunk));

        // Удаляем чанки из таблицы
        conn.execute(
            "DELETE FROM incoming_chunks
             WHERE transfer_id = ?1 AND dialogue_a = ?2 AND dialogue_b = ?3",
            params![transfer_id, dialogue.a, dialogue.b],
        )?;

        Ok(Some(AssembledFile {
            sender,
            filename,
            mime_type,
            data: assembled,
            timestamp: timestamp.parse::<DateTime<Utc>>()?,
        }))
    }
}

pub struct AssembledFile {
    pub sender: String,
    pub filename: String,
    pub mime_type: String,
    pub data: Vec<u8>,
    pub timestamp: DateTime<Utc>,
}

#[cfg(test)]
mod outbound_tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    static CTR: AtomicU64 = AtomicU64::new(0);

    fn tmp_store() -> (std::path::PathBuf, LocalStore) {
        let path = std::env::temp_dir().join(format!(
            "paranoia-outbound-test-{}-{}.db",
            std::process::id(),
            CTR.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_file(&path);
        let store = LocalStore::open(path.to_str().unwrap(), &[7u8; 32]).expect("open store");
        (path, store)
    }

    fn sample(dlg: &DialogueKey, id: &str, header_seq: u64) -> OutboundTransfer {
        OutboundTransfer {
            transfer_id: id.to_string(),
            dialogue: dlg.clone(),
            header_seq,
            chunk_count: 3,
            chunk_sizes: vec![10, 20, 30],
            cache_path: "/tmp/x.bin".to_string(),
            filename: "x.bin".to_string(),
            mime_type: "application/octet-stream".to_string(),
            kind: AttachmentKind::Image,
            total_size: 60,
            group_id: Some("grp1".to_string()),
            timestamp: Utc::now(),
            attempts: 0,
        }
    }

    #[test]
    fn outbound_roundtrip_and_delete() {
        let (path, store) = tmp_store();
        let dlg = DialogueKey { a: "a".into(), b: "b".into() };
        store.insert_outbound(&sample(&dlg, "tid1", 5)).unwrap();

        let list = store.list_outbound(&dlg).unwrap();
        assert_eq!(list.len(), 1);
        let t = &list[0];
        assert_eq!(t.transfer_id, "tid1");
        assert_eq!(t.header_seq, 5);
        assert_eq!(t.chunk_count, 3);
        assert_eq!(t.chunk_sizes, vec![10, 20, 30]); // воспроизводимая нарезка
        assert_eq!(t.kind, AttachmentKind::Image);
        assert_eq!(t.group_id.as_deref(), Some("grp1"));

        // Чужой диалог не виден.
        let other = DialogueKey { a: "c".into(), b: "d".into() };
        assert!(store.list_outbound(&other).unwrap().is_empty());

        assert_eq!(store.bump_outbound_attempts("tid1").unwrap(), 1);
        assert_eq!(store.bump_outbound_attempts("tid1").unwrap(), 2);

        store.delete_outbound("tid1").unwrap();
        assert!(store.list_outbound(&dlg).unwrap().is_empty());
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn outbound_insert_is_idempotent_by_transfer_id() {
        let (path, store) = tmp_store();
        let dlg = DialogueKey { a: "a".into(), b: "b".into() };
        store.insert_outbound(&sample(&dlg, "dup", 1)).unwrap();
        store.insert_outbound(&sample(&dlg, "dup", 1)).unwrap();
        assert_eq!(store.list_outbound(&dlg).unwrap().len(), 1);
        let _ = std::fs::remove_file(&path);
    }
}
