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
    /// Идентификатор фото-группы (мозаики). `Some` — вложение отправлено в составе
    /// группы из нескольких фото с общей подписью; UI рендерит такие вложения
    /// мозаикой под сообщением-заголовком `PhotoGroup` с тем же `group_id`.
    #[serde(default)]
    pub group_id: Option<String>,
    /// `Some` → большой файл, переданный ЭФЕМЕРНО (вне истории): тело лежит во
    /// временном blob-хранилище сервера под этим `file_id`, а не в seq-истории.
    /// Скачивание идёт через blob-эндпоинт (см. [`crate::transport::Transport::blob`]),
    /// а не history-pull. `body_from_seq/to_seq` для таких вложений не используются.
    #[serde(default)]
    pub ephemeral_file_id: Option<String>,
    /// Unix-время (сек), до которого эфемерный файл доступен для скачивания (TTL
    /// сервера). Для UI «доступно до …».
    #[serde(default)]
    pub ephemeral_expires_at: Option<u64>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AttachmentKind {
    File,
    Image,
    Voice,
    Video,
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
    /// Видео-вложение. Семантика рендеринга как у `Image` (превью в ленте +
    /// полноэкранный просмотр), но получатель показывает кадр-превью с плашкой
    /// «play» и проигрывает через нативный медиаплеер. Отправитель транскодит
    /// исходник в H.264/mp4 перед отправкой.
    Video(FileAttachment),
    /// Заголовок фото-группы (мозаики): подпись (может быть пустой) + id группы.
    /// Сами фото идут отдельными `Image`-сообщениями с тем же `group_id`. Сервер
    /// о группировке не знает — это чисто клиентская семантика рендеринга.
    PhotoGroup {
        group_id: String,
        caption: String,
    },
    /// Заголовок файла. За ним сразу идут `chunks` body-пакетов FileChunk.
    FileHeader {
        transfer_id: String,
        kind: AttachmentKind,
        filename: String,
        mime_type: String,
        total_size: usize,
        chunks: u32,
        /// id фото-группы (если вложение отправлено мозаикой) — единственный
        /// per-фото метаданный, доходящий до получателя по проводу.
        #[serde(default)]
        group_id: Option<String>,
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
    /// Детерминированный id темы (ветки диалога), к которой относится сообщение.
    /// `None` — сообщение в «Главной» (без темы). Производная от `topic_name`
    /// через [`derive_topic_id`]; одинакова у обеих сторон и на всех устройствах.
    #[serde(default)]
    pub topic_id: Option<String>,
    /// Отображаемое имя темы как его ввёл отправитель (last-write-wins). Едет по
    /// проводу внутри шифртекста; `topic_id` пересчитывается из него локально.
    #[serde(default)]
    pub topic_name: Option<String>,
}

/// Нормализовать имя темы для детерминированного ключа: схлопнуть пробелы +
/// lower-case. Гарантирует, что «Релиз», «релиз » и «релиз» сходятся в один
/// `topic_id`. (Unicode-NFC — будущее усиление; здесь без новой зависимости.)
pub fn normalize_topic_name(name: &str) -> String {
    name.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}

/// Детерминированный `topic_id` темы из её имени, привязанный к диалогу.
/// `DialogueKey` канонична (a<b), поэтому обе стороны и все устройства,
/// набрав одно имя, сходятся в один id — без серверного реестра и без
/// координации. Хеш имени живёт ТОЛЬКО внутри E2E-шифртекста, на сервер не
/// попадает (словарная атака доступна лишь тому, у кого уже есть канал).
pub fn derive_topic_id(key: &DialogueKey, name: &str) -> String {
    use sha2::{Digest, Sha256};
    let normalized = normalize_topic_name(name);
    let mut h = Sha256::new();
    h.update(b"paranoia:topic:v1\n");
    h.update(key.a.as_bytes());
    h.update(b"\n");
    h.update(key.b.as_bytes());
    h.update(b"\n");
    h.update(normalized.as_bytes());
    hex::encode(h.finalize())
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

    #[test]
    fn topic_id_is_deterministic_and_normalization_converges() {
        let k = DialogueKey::new("alice", "bob");
        // Регистр и лишние пробелы сходятся в один id.
        let a = derive_topic_id(&k, "Релиз 0.3");
        let b = derive_topic_id(&k, "  релиз   0.3 ");
        assert_eq!(a, b, "нормализация должна сводить варианты к одному id");
        // Разные имена — разные id.
        assert_ne!(a, derive_topic_id(&k, "багфиксы"));
    }

    #[test]
    fn topic_id_is_symmetric_across_participants() {
        // DialogueKey канонична (a<b), поэтому обе стороны сходятся в один id.
        let from_alice = DialogueKey::new("alice", "bob");
        let from_bob = DialogueKey::new("bob", "alice");
        assert_eq!(
            derive_topic_id(&from_alice, "релиз"),
            derive_topic_id(&from_bob, "релиз")
        );
    }

    #[test]
    fn topic_id_is_scoped_to_dialogue() {
        // Одно имя в разных диалогах → разные id (salt = участники).
        let k1 = DialogueKey::new("alice", "bob");
        let k2 = DialogueKey::new("alice", "carol");
        assert_ne!(derive_topic_id(&k1, "общее"), derive_topic_id(&k2, "общее"));
    }
}
