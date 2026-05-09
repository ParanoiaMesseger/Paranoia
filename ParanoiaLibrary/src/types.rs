use anyhow::{Result, bail};
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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DialogueKeyEntry {
    pub start_seq: u64,
    pub key: [u8; 32],
}

#[derive(Debug, Clone)]
pub struct DialogueConfig {
    pub key: DialogueKey,
    pub keyring: Vec<DialogueKeyEntry>,
}

impl DialogueConfig {
    pub fn single_key(key: DialogueKey, session_key: [u8; 32]) -> Self {
        Self {
            key,
            keyring: vec![DialogueKeyEntry {
                start_seq: 1,
                key: session_key,
            }],
        }
    }

    pub fn with_keyring(key: DialogueKey, mut keyring: Vec<DialogueKeyEntry>) -> Result<Self> {
        normalize_keyring(&mut keyring)?;
        Ok(Self { key, keyring })
    }

    pub fn normalize(&mut self) -> Result<()> {
        normalize_keyring(&mut self.keyring)
    }

    pub fn key_for_seq(&self, seq: u64) -> Result<&[u8; 32]> {
        self.keyring
            .iter()
            .rev()
            .find(|entry| entry.start_seq <= seq)
            .map(|entry| &entry.key)
            .ok_or_else(|| anyhow::anyhow!("no dialogue key for seq {seq}"))
    }
}

fn normalize_keyring(keyring: &mut Vec<DialogueKeyEntry>) -> Result<()> {
    if keyring.is_empty() {
        bail!("empty dialogue keyring");
    }
    keyring.sort_by_key(|entry| entry.start_seq);
    let mut previous = None;
    for entry in keyring.iter() {
        if entry.start_seq == 0 {
            bail!("invalid keyring start_seq");
        }
        if previous == Some(entry.start_seq) {
            bail!("duplicate keyring start_seq");
        }
        previous = Some(entry.start_seq);
    }
    Ok(())
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
