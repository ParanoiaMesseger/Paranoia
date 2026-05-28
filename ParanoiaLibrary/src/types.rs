use anyhow::{Result, bail};
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Deserializer, Serialize, Serializer};

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
    #[serde(default)]
    pub data: Vec<u8>,
    #[serde(default)]
    pub transfer_id: Option<String>,
    #[serde(default)]
    pub cache_path: Option<String>,
    #[serde(default)]
    pub chunk_count: u32,
    #[serde(default)]
    pub body_from_seq: u64,
    #[serde(default)]
    pub body_to_seq: u64,
    #[serde(default)]
    pub downloaded: bool,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AttachmentKind {
    File,
    Image,
    Voice,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum MessageContent {
    Text(String),
    TextReply {
        text: String,
        reply_to_id: MessageId,
        reply_sender: String,
        reply_text: String,
    },
    File(FileAttachment),
    Image(FileAttachment),
    Voice(FileAttachment),
    /// Заголовок файла. За ним сразу идут `chunks` body-пакетов FileChunk.
    FileHeader {
        transfer_id: String,
        kind: AttachmentKind,
        filename: String,
        mime_type: String,
        total_size: usize,
        chunks: u32,
    },
    /// Один чанк файла — сервер не знает что это
    FileChunk {
        transfer_id: String, // UUID одной передачи файла
        index: u32,          // номер чанка (0-based)
        total: u32,          // всего чанков
        filename: String,
        mime_type: String,
        total_size: usize,
        #[serde(with = "base64_vec")]
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
    /// Реакция на конкретное сообщение.
    Reaction {
        target_id: MessageId,
        emoji: String,
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
    pub reserve_server_urls: Vec<String>,
    pub username: String,
    pub signing_key: ed25519_dalek::SigningKey,
    pub db_path: String,
}

pub const CHUNK_SIZE_MIN: usize = 1024; // 1 KB
pub const CHUNK_SIZE_MAX: usize = 192 * 1024; // 192 KB raw, safe after JSON/base64 cover expansion

mod base64_vec {
    use super::*;

    pub fn serialize<S>(data: &[u8], serializer: S) -> std::result::Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(&B64.encode(data))
    }

    pub fn deserialize<'de, D>(deserializer: D) -> std::result::Result<Vec<u8>, D::Error>
    where
        D: Deserializer<'de>,
    {
        let s = String::deserialize(deserializer)?;
        B64.decode(&s).map_err(serde::de::Error::custom)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn file_chunk_data_serializes_as_base64_string() {
        let content = MessageContent::FileChunk {
            transfer_id: "transfer".to_string(),
            index: 0,
            total: 1,
            filename: "payload.bin".to_string(),
            mime_type: "application/octet-stream".to_string(),
            total_size: 4,
            data: vec![1, 2, 3, 4],
        };

        let value = serde_json::to_value(&content).expect("serialize chunk");
        assert_eq!(value["FileChunk"]["data"], json!("AQIDBA=="));
    }

}
