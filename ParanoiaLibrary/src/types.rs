use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

pub type MessageId = String;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum MessageStatus {
    Sending,
    Sent,
    Delivered,
    Read,
    Failed,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileAttachment {
    pub filename: String,
    pub mime_type: String,
    pub size: usize,
    pub data: Vec<u8>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum MessageContent {
    Text(String),
    File(FileAttachment),
    Image(FileAttachment),
    Voice(FileAttachment),
    /// Один чанк файла — сервер не знает что это
    FileChunk {
        transfer_id: String, // UUID одной передачи файла
        index: u32,          // номер чанка (0-based)
        total: u32,          // всего чанков
        filename: String,
        mime_type: String,
        total_size: usize,
        data: Vec<u8>, // данные чанка (до CHUNK_SIZE байт)
    },
    /// Служебный: прочитано до seq включительно
    ReadReceipt {
        up_to_seq: u64,
    },
    /// Служебный: удалить сообщение
    Delete {
        target_id: MessageId,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Message {
    pub id: MessageId,
    pub dialogue: DialogueKey,
    pub sender: String,
    pub content: MessageContent,
    pub timestamp: DateTime<Utc>,
    pub status: MessageStatus,
    pub server_seq: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
pub struct DialogueKey {
    pub a: String,
    pub b: String,
}

impl DialogueKey {
    pub fn new(x: &str, y: &str) -> Self {
        if x < y {
            Self {
                a: x.into(),
                b: y.into(),
            }
        } else {
            Self {
                a: y.into(),
                b: x.into(),
            }
        }
    }
    pub fn participants(&self) -> (&str, &str) {
        (&self.a, &self.b)
    }
}

#[derive(Debug, Clone)]
pub struct DialogueConfig {
    pub key: DialogueKey,
    pub session_key: [u8; 32],
}

#[derive(Debug, Clone)]
pub struct ClientConfig {
    pub server_url: String,
    pub username: String,
    pub signing_key: ed25519_dalek::SigningKey,
    pub db_path: String,
}

pub const CHUNK_SIZE_MIN: usize = 1024; // 1 KB
pub const CHUNK_SIZE_MAX: usize = 768 * 1024; // 768 KB
