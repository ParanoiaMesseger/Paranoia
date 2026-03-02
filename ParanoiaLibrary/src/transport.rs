use crate::crypto;
use anyhow::{bail, Result};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Serialize)]
struct RegRequest<'a> {
    username: &'a str,
    pub_key: &'a str,
    admin_sig: &'a str,
}

#[derive(Serialize)]
struct PushRequest<'a> {
    sender: &'a str,
    recver: &'a str,
    seq: u64,
    payload: &'a str,
    sig: &'a str,
}

#[derive(Serialize)]
struct PullRequest<'a> {
    sender: &'a str,
    recver: &'a str,
    after_seq: u64,
    sig: &'a str,
}

#[derive(Serialize)]
struct DeterminateRequest<'a> {
    sender: &'a str,
    recver: &'a str,
    cut_seq: u64,
    sig: &'a str,
}

#[derive(Deserialize, Debug)]
struct ApiResponse {
    success: bool,
    message: Value,
}

#[derive(Debug, Clone)]
pub struct RawPacket {
    pub seq: u64,
    pub payload: Vec<u8>, // уже декодированный из base64
}

pub struct Transport {
    client: Client,
    server_url: String,
}

impl Transport {
    pub fn new(server_url: &str) -> Self {
        Self {
            client: Client::new(),
            server_url: server_url.trim_end_matches('/').to_string(),
        }
    }

    pub async fn push(
        &self,
        signing_key: &ed25519_dalek::SigningKey,
        sender: &str,
        recver: &str,
        seq: u64,
        payload_bytes: &[u8],
    ) -> Result<()> {
        let payload_b64 = crypto::encode_b64(payload_bytes);
        // Подпись: sender + recver + seq + payload(base64)
        let msg = format!("{sender}{recver}{seq}{payload_b64}");
        let sig = crypto::sign(signing_key, msg.as_bytes());
        let sig_b64 = crypto::encode_b64(&sig);

        let req = PushRequest {
            sender,
            recver,
            seq,
            payload: &payload_b64,
            sig: &sig_b64,
        };
        let resp = self.post("/push", &req).await?;
        if !resp.success {
            bail!("Push failed: {}", resp.message);
        }
        Ok(())
    }

    pub async fn pull(
        &self,
        signing_key: &ed25519_dalek::SigningKey,
        sender: &str,
        recver: &str,
        after_seq: u64,
    ) -> Result<Vec<RawPacket>> {
        let msg = format!("{sender}{recver}{after_seq}");
        let sig = crypto::sign(signing_key, msg.as_bytes());
        let sig_b64 = crypto::encode_b64(&sig);

        let req = PullRequest {
            sender,
            recver,
            after_seq,
            sig: &sig_b64,
        };
        let resp = self.post("/pull", &req).await?;
        if !resp.success {
            bail!("Pull failed: {}", resp.message);
        }

        // message — массив { seq, payload }
        let arr = resp
            .message
            .as_array()
            .ok_or_else(|| anyhow::anyhow!("Pull: expected array in message"))?;

        let mut packets = Vec::new();
        for item in arr {
            let seq = item["seq"]
                .as_u64()
                .ok_or_else(|| anyhow::anyhow!("Missing seq in packet"))?;
            let payload_b64 = item["payload"]
                .as_str()
                .ok_or_else(|| anyhow::anyhow!("Missing payload in packet"))?;
            let payload = crypto::decode_b64(payload_b64)?;
            packets.push(RawPacket { seq, payload });
        }
        Ok(packets)
    }

    pub async fn determinate(
        &self,
        signing_key: &ed25519_dalek::SigningKey,
        sender: &str,
        recver: &str,
        cut_seq: u64,
    ) -> Result<()> {
        let msg = format!("{sender}{recver}{cut_seq}");
        let sig = crypto::sign(signing_key, msg.as_bytes());
        let sig_b64 = crypto::encode_b64(&sig);

        let req = DeterminateRequest {
            sender,
            recver,
            cut_seq,
            sig: &sig_b64,
        };
        let resp = self.post("/determinate", &req).await?;
        if !resp.success {
            bail!("Determinate failed: {}", resp.message);
        }
        Ok(())
    }

    async fn post<T: Serialize>(&self, path: &str, body: &T) -> Result<ApiResponse> {
        let url = format!("{}{}", self.server_url, path);
        let resp = self
            .client
            .post(&url)
            .json(body)
            .send()
            .await?
            .json::<ApiResponse>()
            .await?;
        Ok(resp)
    }
}
