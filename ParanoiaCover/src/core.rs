//! Единый формат «внутреннего ядра» сообщений — то, что запечатывается в
//! cover-конверт. Общий для клиента и сервера, чтобы поля гарантированно
//! совпадали (иначе wrap на клиенте и unwrap на сервере разъехались бы).
//!
//! Эти структуры сериализуются в байты (`serde_json`), запечатываются AEAD
//! ([`crate::engine`]) и раскладываются по полям-носителям схемы. Имена ключей
//! здесь НЕ видны в трафике (они внутри шифртекста), поэтому выбраны короткими.

use serde::{Deserialize, Serialize};

// ── запросы ─────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PushCore {
    pub sender: String,
    pub recver: String,
    pub seq: u64,
    /// base64 шифртекста сообщения.
    pub payload: String,
    /// base64 подписи Ed25519.
    pub sig: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PullCore {
    pub sender: String,
    pub recver: String,
    pub after_seq: u64,
    pub to_seq: u64,
    pub sig: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct MapCore {
    pub sender: String,
    pub recver: String,
    pub after_seq: u64,
    pub to_seq: u64,
    pub sig: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct NotifyCore {
    pub sender: String,
    pub partner: String,
    pub seq: u64,
    pub sig: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DeterminateCore {
    pub sender: String,
    pub recver: String,
    pub from_seq: u64,
    pub to_seq: u64,
    pub sig: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CallSignalCore {
    pub sender: String,
    pub recver: String,
    pub kind: u8,
    pub payload: String,
    pub ts_ms: i64,
    pub sig: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CallPollCore {
    pub user: String,
    pub nonce: u64,
    pub long_poll_ms: u32,
    pub sig: String,
}

// ── ответы ──────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PacketCore {
    pub seq: u64,
    /// base64 payload.
    pub payload: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct EnvelopeCore {
    pub sender: String,
    pub kind: u8,
    pub payload: String,
    pub ts_ms: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PushRespCore {
    pub ok: bool,
    #[serde(default)]
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PullRespCore {
    pub ok: bool,
    #[serde(default)]
    pub packets: Vec<PacketCore>,
    #[serde(default)]
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct MapRespCore {
    pub ok: bool,
    #[serde(default)]
    pub runs: Vec<(u64, u64)>,
    #[serde(default)]
    pub last_seq: u64,
    #[serde(default)]
    pub truncated: bool,
    #[serde(default)]
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct NotifyRespCore {
    pub ok: bool,
    #[serde(default)]
    pub n: u64,
    #[serde(default)]
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SimpleRespCore {
    pub ok: bool,
    #[serde(default)]
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CallPollRespCore {
    pub ok: bool,
    #[serde(default)]
    pub items: Vec<EnvelopeCore>,
    #[serde(default)]
    pub message: String,
}

/// Канонические имена видов пакетов (ключи в `MaskingProfile.kinds`).
pub mod kind {
    pub const PUSH: &str = "push";
    pub const PULL: &str = "pull";
    pub const MAP: &str = "map";
    pub const NOTIFY: &str = "notify";
    pub const DETERMINATE: &str = "determinate";
    pub const CALL_SIGNAL: &str = "call_signal";
    pub const CALL_POLL: &str = "call_poll";

    pub const PUSH_RESP: &str = "push_resp";
    pub const PULL_RESP: &str = "pull_resp";
    pub const MAP_RESP: &str = "map_resp";
    pub const NOTIFY_RESP: &str = "notify_resp";
    pub const DETERMINATE_RESP: &str = "determinate_resp";
    pub const CALL_SIGNAL_RESP: &str = "call_signal_resp";
    pub const CALL_POLL_RESP: &str = "call_poll_resp";
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn push_core_json_roundtrip() {
        let c = PushCore {
            sender: "a".into(),
            recver: "b".into(),
            seq: 7,
            payload: "cGF5".into(),
            sig: "c2ln".into(),
        };
        let bytes = serde_json::to_vec(&c).unwrap();
        let back: PushCore = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(c, back);
    }

    #[test]
    fn pull_resp_defaults_tolerate_missing_fields() {
        let back: PullRespCore = serde_json::from_str(r#"{"ok":true}"#).unwrap();
        assert!(back.ok && back.packets.is_empty() && back.message.is_empty());
    }
}
