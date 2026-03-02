use crate::client_cover::ClientCover;
use anyhow::Result;
use reqwest::Client;
use serde::Serialize;
use serde_json::Value;
use std::sync::Arc;

/// Внутренний пакет на отправку (push).
pub struct CorePush {
    pub sender:  String,
    pub recver:  String,
    pub seq:     u64,
    pub payload: Vec<u8>, // зашифрованный бинарь (ciphertext)
    pub sig:     Vec<u8>, // подпись Ed25519 (64 байта)
}

/// Внутренний запрос pull.
pub struct CorePull {
    pub sender:    String,
    pub recver:    String,
    pub after_seq: u64,
    pub sig:       Vec<u8>,
}

/// Внутренний запрос determinate.
pub struct CoreDeterminate {
    pub sender:  String,
    pub recver:  String,
    pub cut_seq: u64,
    pub sig:     Vec<u8>,
}

/// Ответ одного пакета с сервера (после pull).
#[derive(Debug, Clone)]
pub struct RawPacket {
    pub seq:     u64,
    pub payload: Vec<u8>, // уже декодированный из base64
}

// Для /reg оставляем простой формат без cover.
#[derive(Serialize)]
struct RegRequest<'a> {
    username:  &'a str,
    pub_key:   &'a str,
    admin_sig: &'a str,
}

pub struct Transport {
    client:     Client,
    server_url: String,
    cover:      Arc<dyn ClientCover>,
}

impl Transport {
    pub fn new(server_url: &str, cover: Arc<dyn ClientCover>) -> Self {
        Self {
            client: Client::new(),
            server_url: server_url.trim_end_matches('/').to_string(),
            cover,
        }
    }

    // ── регистрировать пользователя (без cover) ─────────────────────────

    pub async fn reg(
        &self,
        username: &str,
        user_pubkey_b64: &str,
        admin_sig_b64: &str,
    ) -> Result<()> {
        let req = RegRequest {
            username,
            pub_key: user_pubkey_b64,
            admin_sig: admin_sig_b64,
        };
        let resp = self.post_json("/reg", &serde_json::to_value(&req)?).await?;
        let success = resp.get("success").and_then(|v| v.as_bool()).unwrap_or(false);
        if !success {
            anyhow::bail!("Reg failed: {}", resp);
        }
        Ok(())
    }

    // ── ядро протокола через cover ──────────────────────────────────────

    pub async fn push(&self, core: &CorePush) -> Result<()> {
        let body = self.cover.wrap_push(core)?;
        let resp = self.post_json("/push", &body).await?;
        self.cover.unwrap_push_response(&resp)
    }

    pub async fn pull(&self, core: &CorePull) -> Result<Vec<RawPacket>> {
        let body = self.cover.wrap_pull(core)?;
        let resp = self.post_json("/pull", &body).await?;
        self.cover.unwrap_pull_response(&resp)
    }

    pub async fn determinate(&self, core: &CoreDeterminate) -> Result<()> {
        let body = self.cover.wrap_determinate(core)?;
        let resp = self.post_json("/determinate", &body).await?;
        self.cover.unwrap_determinate_response(&resp)
    }

    // ── HTTP утилита ────────────────────────────────────────────────────

    async fn post_json(&self, path: &str, body: &Value) -> Result<Value> {
        let url = format!("{}{}", self.server_url, path);
        let resp = self
            .client
            .post(&url)
            .json(body)
            .send()
            .await?
            .json::<Value>()
            .await?;
        Ok(resp)
    }
}
