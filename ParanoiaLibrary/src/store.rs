use crate::types::{DialogueKey, Message, MessageStatus};
use anyhow::Result;
use chrono::{DateTime, Utc};
use rusqlite::{Connection, params};
use std::sync::Mutex;

pub struct LocalStore {
    pub(crate) conn: Mutex<Connection>,
}

impl LocalStore {
    pub fn open(path: &str) -> Result<Self> {
        let conn = Connection::open(path)?;
        conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")?;
        let store = Self {
            conn: Mutex::new(conn),
        };
        store.migrate()?;
        Ok(store)
    }

    fn migrate(&self) -> Result<()> {
        let conn = self.conn.lock().unwrap();
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
        ",
        )?;
        Ok(())
    }

    // ── seq management ────────────────────────────────────────────────────

    /// Атомарно получить следующий локально известный seq и инкрементировать счётчик.
    /// Перед отправкой Dialogue синхронизирует last_pulled_seq через серверный pull.
    pub fn next_send_seq(&self, dialogue: &DialogueKey) -> Result<u64> {
        let conn = self.conn.lock().unwrap();
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

    pub fn get_last_pulled_seq(&self, dialogue: &DialogueKey) -> Result<u64> {
        let conn = self.conn.lock().unwrap();
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
        let conn = self.conn.lock().unwrap();
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
        let conn = self.conn.lock().unwrap();
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
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "UPDATE messages SET status = ?1 WHERE id = ?2",
            params![serde_json::to_string(&status)?, message_id],
        )?;
        Ok(())
    }

    /// Батч READ RECEIPT: помечаем все сообщения с server_seq <= up_to_seq как Read.
    pub fn mark_read_until(&self, dialogue: &DialogueKey, up_to_seq: u64) -> Result<usize> {
        let conn = self.conn.lock().unwrap();
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

    pub fn get_message_by_seq(&self, dialogue: &DialogueKey, seq: u64) -> Result<Option<String>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id
             FROM messages
             WHERE dialogue_a = ?1
               AND dialogue_b = ?2
               AND server_seq = ?3
             LIMIT 1",
        )?;
        let mut rows = stmt.query(params![
            dialogue.a, dialogue.b,
            seq as i64, // в БД server_seq уже как INTEGER/i64
        ])?;

        if let Some(row) = rows.next()? {
            let id: String = row.get(0)?;
            Ok(Some(id))
        } else {
            Ok(None)
        }
    }

    pub fn get_messages(
        &self,
        dialogue: &DialogueKey,
        limit: usize,
        before: Option<DateTime<Utc>>,
    ) -> Result<Vec<Message>> {
        let conn = self.conn.lock().unwrap();
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
            let (id, sender, content_json, ts_str, status_json, seq) = row?;
            messages.push(Message {
                id,
                dialogue: dialogue.clone(),
                sender,
                content: serde_json::from_str(&content_json)?,
                timestamp: ts_str.parse::<DateTime<Utc>>()?,
                status: serde_json::from_str(&status_json)?,
                server_seq: seq.map(|s| s as u64),
            });
        }
        messages.reverse();
        Ok(messages)
    }

    // ── dialogue deletion ─────────────────────────────────────────────────

    /// Удалить все локальные данные диалога из SQLite.
    pub fn delete_dialogue(&self, dialogue: &DialogueKey) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "DELETE FROM messages WHERE dialogue_a = ?1 AND dialogue_b = ?2",
            params![dialogue.a, dialogue.b],
        )?;
        conn.execute(
            "DELETE FROM seq_map WHERE dialogue_a = ?1 AND dialogue_b = ?2",
            params![dialogue.a, dialogue.b],
        )?;
        conn.execute(
            "DELETE FROM dialogue_state WHERE dialogue_a = ?1 AND dialogue_b = ?2",
            params![dialogue.a, dialogue.b],
        )?;
        conn.execute(
            "DELETE FROM incoming_chunks WHERE dialogue_a = ?1 AND dialogue_b = ?2",
            params![dialogue.a, dialogue.b],
        )?;
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
        let conn = self.conn.lock().unwrap();
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
        let conn = self.conn.lock().unwrap();

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
        for chunk in chunks {
            assembled.extend_from_slice(&chunk);
        }

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
