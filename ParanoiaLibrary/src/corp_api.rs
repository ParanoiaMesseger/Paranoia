//! Клиент corporate/commercial distribution-ноды (приватный сервис
//! `ParanoiaAdminPanel/AdminApi`, не в opensource).
//!
//! Панель (админ) пушит подписанные блобы/датасеты; клиент сотрудника забирает
//! свой блоб, доказав владение signing-ключом, и расшифровывает его PSK.
//!
//! Канонические сообщения ДОЛЖНЫ ПОБАЙТОВО совпадать с проверкой на сервере
//! (`ParanoiaAdminPanel/AdminApi/src/auth.rs`).

use anyhow::{Result, anyhow, bail};
use ed25519_dalek::{Signer, SigningKey};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::runtime::Runtime;
use uuid::Uuid;

use crate::AdminKeyPair;
use crate::corp;
use crate::crypto::{decode_b64, encode_b64};

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn sha256_hex(data: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(data);
    hex::encode(h.finalize())
}

/// Каноническое сообщение для админ-записи (подписывается admin-ключом).
fn canonical_write(op: &str, nonce: &str, ts: u64, extra: &str) -> String {
    format!("paranoia-adminapi\n{op}\n{nonce}\n{ts}\n{extra}")
}

/// Каноническое сообщение owner-proof для чтения (подписывается ключом сотрудника).
fn canonical_read(server_id: &str, ts: u64) -> String {
    format!("paranoia-adminapi-read\ncorp.get\n{server_id}\n{ts}")
}

fn trim_url(url: &str) -> String {
    url.trim_end_matches('/').to_string()
}

async fn put_json(base: &str, path: &str, body: &Value) -> Result<String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(20))
        .build()?;
    let resp = client
        .put(format!("{}{}", trim_url(base), path))
        .json(body)
        .send()
        .await?;
    let status = resp.status();
    let text = resp.text().await.unwrap_or_default();
    if !status.is_success() {
        bail!("http {}: {}", status.as_u16(), text);
    }
    Ok(text)
}

// ── Запись (панель/админ) ───────────────────────────────────────────────────

/// Запушить шифрованный блоб связки сотрудника. blob_b64 — выход `corp::seal`.
pub fn corp_push(
    dist_url: &str,
    admin_secret_b64: &str,
    server_id: &str,
    version: u64,
    blob_b64: &str,
) -> Result<String> {
    let kp =
        AdminKeyPair::from_secret_b64(admin_secret_b64).map_err(|_| anyhow!("invalid_admin_key"))?;
    let blob = decode_b64(blob_b64).map_err(|_| anyhow!("invalid_blob_b64"))?;
    let nonce = Uuid::new_v4().to_string();
    let ts = now_secs();
    let extra = format!("{server_id}\n{version}\n{}", sha256_hex(&blob));
    let sig = kp.sign_canonical(&canonical_write("corp.put", &nonce, ts, &extra));
    let body = json!({
        "op": "corp.put", "nonce": nonce, "ts": ts,
        "server_id": server_id, "version": version, "blob_b64": blob_b64, "sig": sig,
    });
    let rt = Runtime::new()?;
    rt.block_on(put_json(dist_url, "/corp/put", &body))
}

/// Удалить блоб сотрудника (увольнение/удаление).
pub fn corp_delete(dist_url: &str, admin_secret_b64: &str, server_id: &str) -> Result<String> {
    let kp =
        AdminKeyPair::from_secret_b64(admin_secret_b64).map_err(|_| anyhow!("invalid_admin_key"))?;
    let nonce = Uuid::new_v4().to_string();
    let ts = now_secs();
    let sig = kp.sign_canonical(&canonical_write("corp.delete", &nonce, ts, server_id));
    let body = json!({
        "op": "corp.delete", "nonce": nonce, "ts": ts, "server_id": server_id, "sig": sig,
    });
    let rt = Runtime::new()?;
    rt.block_on(put_json(dist_url, "/corp/delete", &body))
}

/// Запушить весь коммерческий датасет (несекретный; раздаётся ботам на чтение).
pub fn commercial_push(dist_url: &str, admin_secret_b64: &str, data_json: &str) -> Result<String> {
    let kp =
        AdminKeyPair::from_secret_b64(admin_secret_b64).map_err(|_| anyhow!("invalid_admin_key"))?;
    // Проверяем, что это валидный JSON (но подписываем и шлём сырую строку —
    // чтобы sha256 совпал на сервере без риска ре-сериализации).
    let _: Value = serde_json::from_str(data_json).map_err(|_| anyhow!("invalid_data_json"))?;
    let nonce = Uuid::new_v4().to_string();
    let ts = now_secs();
    let extra = sha256_hex(data_json.as_bytes());
    let sig = kp.sign_canonical(&canonical_write("commercial.put", &nonce, ts, &extra));
    let body = json!({
        "op": "commercial.put", "nonce": nonce, "ts": ts, "data_json": data_json, "sig": sig,
    });
    let rt = Runtime::new()?;
    rt.block_on(put_json(dist_url, "/commercial/put", &body))
}

// ── Чтение (клиент сотрудника) ──────────────────────────────────────────────

async fn corp_get(base: &str, server_id: &str, pubkey_b64: &str, ts: u64, sig_b64: &str) -> Result<(u16, String)> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(20))
        .build()?;
    let resp = client
        .get(format!("{}/corp/{}", trim_url(base), server_id))
        .header("X-Pubkey", pubkey_b64)
        .header("X-Ts", ts.to_string())
        .header("X-Sig", sig_b64)
        .send()
        .await?;
    let status = resp.status().as_u16();
    let text = resp.text().await.unwrap_or_default();
    Ok((status, text))
}

/// Забрать и расшифровать связку сотрудника. Возвращает plaintext keyring JSON,
/// либо пустую строку, если блоба ещё нет (404). Owner-proof: подпись
/// signing-ключом сотрудника; server_id обязан выводиться из его pubkey.
pub fn corp_sync(
    dist_url: &str,
    server_id: &str,
    signing_key_b64: &str,
    psk_b64: &str,
) -> Result<String> {
    let sk_bytes = decode_b64(signing_key_b64).map_err(|_| anyhow!("invalid_signing_key"))?;
    if sk_bytes.len() != 32 {
        bail!("invalid_signing_key");
    }
    let mut seed = [0u8; 32];
    seed.copy_from_slice(&sk_bytes);
    let sk = SigningKey::from_bytes(&seed);
    let vk = sk.verifying_key();
    let psk = decode_b64(psk_b64).map_err(|_| anyhow!("invalid_psk"))?;

    let ts = now_secs();
    let canon = canonical_read(server_id, ts);
    let sig = sk.sign(canon.as_bytes()).to_bytes();
    let pubkey_b64 = encode_b64(vk.to_bytes().as_slice());
    let sig_b64 = encode_b64(sig.as_slice());

    let rt = Runtime::new()?;
    let (status, text) = rt.block_on(corp_get(dist_url, server_id, &pubkey_b64, ts, &sig_b64))?;
    if status == 404 {
        return Ok(String::new()); // блоба ещё нет
    }
    if status != 200 {
        bail!("http {}: {}", status, text);
    }
    let v: Value = serde_json::from_str(&text).map_err(|_| anyhow!("bad_response"))?;
    let blob_b64 = v.get("blob_b64").and_then(|x| x.as_str()).unwrap_or("");
    if blob_b64.is_empty() {
        return Ok(String::new());
    }
    let blob = decode_b64(blob_b64).map_err(|_| anyhow!("invalid_blob_b64"))?;
    let (_version, pt) = corp::open(&psk, server_id, &blob)?;
    String::from_utf8(pt).map_err(|_| anyhow!("bad_utf8"))
}
