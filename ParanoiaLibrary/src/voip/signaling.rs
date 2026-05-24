//! VoIP-сигналинг: payload-структуры (Offer/Answer/Hangup/Ice), сериализация,
//! AEAD-«seal»/«open» поверх dialog master key'а.
//!
//! Сигналинг идёт через отдельный HTTP-канал (`/call/signal` + `/call/poll`),
//! см. серверную часть. Сервер видит метаданные {sender, recver, kind, ts},
//! но не видит содержимого payload'а — он зашифрован тем же ключом, что и
//! сообщения диалога, ChaCha20-Poly1305 со случайным 12-байт nonce.
//!
//! Сессионные ключи (HKDF) живут в [`super::crypto::SessionKeys`] — этот модуль
//! работает на уровне выше: только инициализация звонка и обмен ICE.

use anyhow::{Result, bail};
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use chacha20poly1305::{
    ChaCha20Poly1305, Key, Nonce,
    aead::{Aead, KeyInit},
};
use rand::RngCore;
use serde::{Deserialize, Serialize};

mod base64_session_id {
    use super::*;
    use serde::{Deserializer, Serializer, de::Error as _};

    pub fn serialize<S: Serializer>(bytes: &[u8; 16], s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&B64.encode(bytes))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<[u8; 16], D::Error> {
        let s = <String as Deserialize>::deserialize(d)?;
        let v = B64.decode(s.as_bytes()).map_err(D::Error::custom)?;
        v.try_into().map_err(|_| D::Error::custom("expected 16 bytes"))
    }
}

/// Соответствует `CallSignalKind` на сервере (поле `kind` в конверте).
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CallSignalKind {
    Offer = 0,
    Answer = 1,
    Hangup = 2,
    /// ICE-trickle: добавочные кандидаты после offer/answer.
    Ice = 3,
}

impl CallSignalKind {
    pub fn from_byte(b: u8) -> Option<Self> {
        match b {
            0 => Some(Self::Offer),
            1 => Some(Self::Answer),
            2 => Some(Self::Hangup),
            3 => Some(Self::Ice),
            _ => None,
        }
    }

    pub fn as_byte(self) -> u8 {
        self as u8
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CallOfferPayload {
    pub call_id: String,
    /// Случайный 16-байт salt для HKDF — приватный, сервер его не знает.
    /// Сериализуется как base64-строка (а не JSON-массив u8) для совместимости
    /// с Qt/QML, где удобнее принимать строку.
    #[serde(with = "base64_session_id")]
    pub session_id: [u8; 16],
    /// Какие потоки участвуют (для будущего видео).
    #[serde(default = "default_voice_only")]
    pub streams: Vec<u8>,
    /// Кандидаты вида "host:port" (без STUN — local-only; со STUN — добавятся
    /// reflexive). Пустой список означает, что отправитель отдаст ICE через
    /// trickle.
    #[serde(default)]
    pub candidates: Vec<String>,
    pub from_username: String,
    pub created_ts_ms: i64,
}

fn default_voice_only() -> Vec<u8> {
    vec![0]
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CallAnswerPayload {
    pub call_id: String,
    pub accept: bool,
    #[serde(default)]
    pub candidates: Vec<String>,
    /// Какие потоки ответчик согласен поддерживать. Обычно — пересечение
    /// потоков, предложенных в Offer.streams, и тех, что ответчик готов
    /// принять (например, без видео если у пользователя нет камеры или он
    /// отклонил доступ к ней). Если поле отсутствует — считается voice-only.
    #[serde(default = "default_voice_only")]
    pub streams: Vec<u8>,
    /// Опциональная причина отказа.
    #[serde(default)]
    pub reason: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CallHangupPayload {
    pub call_id: String,
    pub reason: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CallIcePayload {
    pub call_id: String,
    pub candidate: String,
}

/// Высокоуровневый payload — то, что десериализуется из расшифрованного
/// конверта на принимающей стороне. Сопоставляется с [`CallSignalKind`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CallSignal {
    Offer(CallOfferPayload),
    Answer(CallAnswerPayload),
    Hangup(CallHangupPayload),
    Ice(CallIcePayload),
}

impl CallSignal {
    pub fn kind(&self) -> CallSignalKind {
        match self {
            CallSignal::Offer(_) => CallSignalKind::Offer,
            CallSignal::Answer(_) => CallSignalKind::Answer,
            CallSignal::Hangup(_) => CallSignalKind::Hangup,
            CallSignal::Ice(_) => CallSignalKind::Ice,
        }
    }

    /// Сериализовать payload в JSON-байты (отдельно от kind — он идёт открыто
    /// в конверте сервера).
    pub fn serialize(&self) -> Result<Vec<u8>> {
        Ok(match self {
            CallSignal::Offer(p) => serde_json::to_vec(p)?,
            CallSignal::Answer(p) => serde_json::to_vec(p)?,
            CallSignal::Hangup(p) => serde_json::to_vec(p)?,
            CallSignal::Ice(p) => serde_json::to_vec(p)?,
        })
    }

    pub fn deserialize(kind: CallSignalKind, json: &[u8]) -> Result<Self> {
        Ok(match kind {
            CallSignalKind::Offer => CallSignal::Offer(serde_json::from_slice(json)?),
            CallSignalKind::Answer => CallSignal::Answer(serde_json::from_slice(json)?),
            CallSignalKind::Hangup => CallSignal::Hangup(serde_json::from_slice(json)?),
            CallSignalKind::Ice => CallSignal::Ice(serde_json::from_slice(json)?),
        })
    }
}

/// Зашифровать payload dialog master key'ом.
///
/// Формат: `nonce(12) || ciphertext+tag` — совместим с `crypto::encrypt`,
/// но без AAD: AAD здесь не нужен, потому что метаданные сервера (sender,
/// recver, kind) не привязаны к payload криптографически — их аутентификация
/// делается ed25519-подписью на уровне HTTP-запроса.
pub fn seal(master_key: &[u8; 32], json: &[u8]) -> Result<Vec<u8>> {
    let cipher = ChaCha20Poly1305::new(Key::from_slice(master_key));
    let mut nonce = [0u8; 12];
    rand::rngs::OsRng.fill_bytes(&mut nonce);
    let ct = cipher
        .encrypt(Nonce::from_slice(&nonce), json)
        .map_err(|e| anyhow::anyhow!("Signaling encrypt failed: {e}"))?;
    let mut out = Vec::with_capacity(12 + ct.len());
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&ct);
    Ok(out)
}

/// Расшифровать конверт.
pub fn open(master_key: &[u8; 32], envelope: &[u8]) -> Result<Vec<u8>> {
    if envelope.len() < 12 + 16 {
        bail!("Signaling envelope too short");
    }
    let (nonce, ct) = envelope.split_at(12);
    let cipher = ChaCha20Poly1305::new(Key::from_slice(master_key));
    cipher
        .decrypt(Nonce::from_slice(nonce), ct)
        .map_err(|_| anyhow::anyhow!("Signaling decrypt failed"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn master() -> [u8; 32] {
        [0x11; 32]
    }

    #[test]
    fn offer_roundtrip() {
        let offer = CallOfferPayload {
            call_id: "abc".into(),
            session_id: [42; 16],
            streams: vec![0],
            candidates: vec!["1.2.3.4:50000".into()],
            from_username: "alice".into(),
            created_ts_ms: 1_700_000_000_000,
        };
        let signal = CallSignal::Offer(offer.clone());
        let bytes = signal.serialize().unwrap();
        let back = CallSignal::deserialize(CallSignalKind::Offer, &bytes).unwrap();
        assert_eq!(back, CallSignal::Offer(offer));
    }

    #[test]
    fn seal_open_roundtrip() {
        let key = master();
        let payload = b"{\"call_id\":\"abc\"}";
        let env = seal(&key, payload).unwrap();
        assert!(env.len() > 12 + 16);
        let back = open(&key, &env).unwrap();
        assert_eq!(back, payload);
    }

    #[test]
    fn seal_uses_random_nonce() {
        let key = master();
        let a = seal(&key, b"payload").unwrap();
        let b = seal(&key, b"payload").unwrap();
        assert_ne!(a, b, "two seals must differ — random nonce");
    }

    #[test]
    fn open_rejects_tampered() {
        let key = master();
        let mut env = seal(&key, b"payload").unwrap();
        let last = env.len() - 1;
        env[last] ^= 0x01;
        assert!(open(&key, &env).is_err());
    }

    #[test]
    fn open_rejects_wrong_key() {
        let env = seal(&master(), b"payload").unwrap();
        let other = [0x22; 32];
        assert!(open(&other, &env).is_err());
    }

    #[test]
    fn kind_byte_roundtrip() {
        for k in [
            CallSignalKind::Offer,
            CallSignalKind::Answer,
            CallSignalKind::Hangup,
            CallSignalKind::Ice,
        ] {
            assert_eq!(CallSignalKind::from_byte(k.as_byte()), Some(k));
        }
        assert_eq!(CallSignalKind::from_byte(99), None);
    }
}
