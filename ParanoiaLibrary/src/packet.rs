use crate::types::MessageContent;
use anyhow::Result;
use serde::{Deserialize, Serialize};

/// Открытый заголовок внутри зашифрованного payload.
/// Полностью скрыт от сервера — расшифровывается только получателем.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PacketInner {
    /// UUID сообщения на клиенте
    pub id: String,
    /// Unix timestamp (ms)
    pub timestamp: i64,
    /// Имя отправителя (для верификации внутри шифрованного канала)
    pub sender: String,
    /// Содержимое сообщения
    pub content: MessageContent,
    /// Имя темы (ветки диалога), в которую отправлено сообщение. `None` —
    /// «Главная» (без темы). Скрыто от сервера (внутри шифртекста); получатель
    /// пересчитывает `topic_id` локально через [`crate::types::derive_topic_id`].
    /// `skip_serializing_if` — не раздувать payload/cover, когда темы нет.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub topic_name: Option<String>,
}

impl PacketInner {
    /// Сериализовать в байты для шифрования.
    pub fn serialize(&self) -> Result<Vec<u8>> {
        Ok(serde_json::to_vec(self)?)
    }

    /// Десериализовать из расшифрованных байт.
    pub fn deserialize(data: &[u8]) -> Result<Self> {
        Ok(serde_json::from_slice(data)?)
    }
}
