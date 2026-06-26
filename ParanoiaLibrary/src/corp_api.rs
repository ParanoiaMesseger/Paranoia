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

/// Если активен профиль с видом `node` — отправить дескриптор операции через
/// cover-туннель ноды и вернуть `(status, body_text)`. Иначе `None` (слать
/// плоско). Маскирует distribution-трафик (corp/commercial) тем же профилем.
fn node_tunnel(dist_url: &str, descriptor: &Value) -> Result<Option<(u16, String)>> {
    let Some(profile) = crate::admin_api::active_masking_profile() else {
        return Ok(None);
    };
    let Some(spec) = profile.kinds.get("node") else {
        return Ok(None);
    };
    let inner = serde_json::to_vec(descriptor)?;
    let covered = paranoia_cover::wrap_auto(&profile, "node", &inner)
        .map_err(|e| anyhow!("cover wrap: {e}"))?;
    let rt = Runtime::new()?;
    let text = rt.block_on(put_json(dist_url, &spec.path, &covered))?;
    let resp_cover: Value =
        serde_json::from_str(&text).map_err(|_| anyhow!("bad cover response"))?;
    let resp_inner = paranoia_cover::unwrap(&profile, "node_resp", &resp_cover)
        .map_err(|e| anyhow!("cover unwrap: {e}"))?;
    let resp: Value = serde_json::from_slice(&resp_inner)?;
    let status = resp.get("status").and_then(|v| v.as_u64()).unwrap_or(0) as u16;
    let body = resp.get("body").cloned().unwrap_or(Value::Null);
    Ok(Some((status, serde_json::to_string(&body)?)))
}

/// Отправить write-операцию (corp.put/delete, commercial.put): через туннель,
/// если профиль активен, иначе плоско на `plain_path`. Возвращает тело ответа.
fn send_write(dist_url: &str, plain_path: &str, op: &str, body: &Value) -> Result<String> {
    if let Some((status, text)) =
        node_tunnel(dist_url, &json!({ "op": op, "body": body }))?
    {
        if (200..300).contains(&status) {
            return Ok(text);
        }
        bail!("http {}: {}", status, text);
    }
    let rt = Runtime::new()?;
    rt.block_on(put_json(dist_url, plain_path, body))
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
    send_write(dist_url, "/corp/put", "corp.put", &body)
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
    send_write(dist_url, "/corp/delete", "corp.delete", &body)
}

/// Запушить РОСТЕР сотрудника (список доступных диалогов БЕЗ ключей, шифртекст
/// `corp::seal(.., CTX_ROSTER, ..)`). Нода хранит его отдельным ресурсом
/// `/corp/{server_id}/roster`. Ленивая раздача: клиент тянет ростер, чтобы
/// показать «какие диалоги можно добавить», ключи качает по одному отдельно.
pub fn corp_push_roster(
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
    // resource="roster" в extra — нода привязывает запись к ресурсу ростера.
    let extra = format!("{server_id}\nroster\n{version}\n{}", sha256_hex(&blob));
    let sig = kp.sign_canonical(&canonical_write("corp.put.roster", &nonce, ts, &extra));
    let body = json!({
        "op": "corp.put.roster", "nonce": nonce, "ts": ts,
        "server_id": server_id, "version": version, "blob_b64": blob_b64, "sig": sig,
    });
    send_write(dist_url, "/corp/put", "corp.put.roster", &body)
}

/// Запушить ключ ОДНОГО диалога сотрудника с `partner_server_id` (шифртекст
/// `corp::seal(.., ctx_dialogue(partner), ..)`). Нода хранит его ресурсом
/// `/corp/{server_id}/dialogue/{partner_server_id}`. Ленивая раздача — клиент
/// качает только нужные диалоги.
pub fn corp_push_dialogue(
    dist_url: &str,
    admin_secret_b64: &str,
    server_id: &str,
    partner_server_id: &str,
    version: u64,
    blob_b64: &str,
) -> Result<String> {
    let kp =
        AdminKeyPair::from_secret_b64(admin_secret_b64).map_err(|_| anyhow!("invalid_admin_key"))?;
    let blob = decode_b64(blob_b64).map_err(|_| anyhow!("invalid_blob_b64"))?;
    let nonce = Uuid::new_v4().to_string();
    let ts = now_secs();
    // resource="dlg:<partner>" в extra — привязывает запись к ресурсу диалога.
    let extra = format!("{server_id}\ndlg:{partner_server_id}\n{version}\n{}", sha256_hex(&blob));
    let sig = kp.sign_canonical(&canonical_write("corp.put.dialogue", &nonce, ts, &extra));
    let body = json!({
        "op": "corp.put.dialogue", "nonce": nonce, "ts": ts,
        "server_id": server_id, "partner_server_id": partner_server_id,
        "version": version, "blob_b64": blob_b64, "sig": sig,
    });
    send_write(dist_url, "/corp/put", "corp.put.dialogue", &body)
}

/// Удалить ключ ОДНОГО диалога сотрудника (отзыв доступа к конкретному диалогу
/// без снятия всей связки). Нода удаляет ресурс
/// `/corp/{server_id}/dialogue/{partner_server_id}`.
pub fn corp_delete_dialogue(
    dist_url: &str,
    admin_secret_b64: &str,
    server_id: &str,
    partner_server_id: &str,
) -> Result<String> {
    let kp =
        AdminKeyPair::from_secret_b64(admin_secret_b64).map_err(|_| anyhow!("invalid_admin_key"))?;
    let nonce = Uuid::new_v4().to_string();
    let ts = now_secs();
    let extra = format!("{server_id}\ndlg:{partner_server_id}");
    let sig = kp.sign_canonical(&canonical_write("corp.delete.dialogue", &nonce, ts, &extra));
    let body = json!({
        "op": "corp.delete.dialogue", "nonce": nonce, "ts": ts,
        "server_id": server_id, "partner_server_id": partner_server_id, "sig": sig,
    });
    send_write(dist_url, "/corp/delete", "corp.delete.dialogue", &body)
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
    send_write(dist_url, "/commercial/put", "commercial.put", &body)
}

/// Запушить ПОДПИСАННЫЙ masking-профиль на ноду (PUT /masking/profile). Нода
/// начинает раздавать его клиентам сразу — те применяют при следующем запросе.
/// `signed_profile_json` — конверт SignedProfile (подписан extended-ключом).
pub fn masking_publish(
    dist_url: &str,
    admin_secret_b64: &str,
    signed_profile_json: &str,
) -> Result<String> {
    let kp =
        AdminKeyPair::from_secret_b64(admin_secret_b64).map_err(|_| anyhow!("invalid_admin_key"))?;
    // Валидируем как JSON, но подписываем/шлём сырую строку — чтобы sha256
    // совпал на ноде без риска ре-сериализации.
    let _: Value = serde_json::from_str(signed_profile_json).map_err(|_| anyhow!("invalid_profile_json"))?;
    let nonce = Uuid::new_v4().to_string();
    let ts = now_secs();
    let extra = sha256_hex(signed_profile_json.as_bytes());
    let sig = kp.sign_canonical(&canonical_write("masking.put", &nonce, ts, &extra));
    let body = json!({
        "op": "masking.put", "nonce": nonce, "ts": ts, "profile": signed_profile_json, "sig": sig,
    });
    send_write(dist_url, "/masking/profile", "masking.put", &body)
}

// ── Чтение (клиент сотрудника) ──────────────────────────────────────────────
//
// Контракт ноды (приватный `ParanoiaAdminPanel/AdminApi`), RESTful-чтение по
// owner-proof (заголовки X-Pubkey/X-Ts/X-Sig, `server_id` выводится из pubkey):
//   GET /corp/{server_id}                          → вся связка   (CTX_KEYRING)
//   GET /corp/{server_id}/roster                   → ростер       (CTX_ROSTER)
//   GET /corp/{server_id}/dialogue/{partner_id}    → ключ диалога (ctx_dialogue)
// Ответ всех трёх: `{ "blob_b64": "<corp::seal>" }` либо 404, если блоба нет.
// Owner-proof одинаков для всех ресурсов (сотрудник вправе читать любой свой
// блоб); подмену блоба одного ресурса под другой ловит AAD-context в corp::open,
// поэтому ресурс в подпись не вшиваем — нода различает его по пути URL.

async fn http_get_blob(
    base: &str,
    server_id: &str,
    path_suffix: &str,
    pubkey_b64: &str,
    ts: u64,
    sig_b64: &str,
) -> Result<(u16, String)> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(20))
        .build()?;
    let resp = client
        .get(format!("{}/corp/{}{}", trim_url(base), server_id, path_suffix))
        .header("X-Pubkey", pubkey_b64)
        .header("X-Ts", ts.to_string())
        .header("X-Sig", sig_b64)
        .send()
        .await?;
    let status = resp.status().as_u16();
    let text = resp.text().await.unwrap_or_default();
    Ok((status, text))
}

/// Owner-proof GET одного блоба. `path_suffix`: `""` → вся связка, `"/roster"`,
/// `"/dialogue/{partner}"`. Возвращает сырой блоб (выход `corp::seal`) или `None`
/// (404 — блоба ещё нет). Через cover-туннель, если активен masking-профиль ноды.
fn fetch_blob(
    dist_url: &str,
    server_id: &str,
    path_suffix: &str,
    op: &str,
    signing_key_b64: &str,
) -> Result<Option<Vec<u8>>> {
    let sk_bytes = decode_b64(signing_key_b64).map_err(|_| anyhow!("invalid_signing_key"))?;
    if sk_bytes.len() != 32 {
        bail!("invalid_signing_key");
    }
    let mut seed = [0u8; 32];
    seed.copy_from_slice(&sk_bytes);
    let sk = SigningKey::from_bytes(&seed);
    let vk = sk.verifying_key();

    let ts = now_secs();
    let canon = canonical_read(server_id, ts);
    let sig = sk.sign(canon.as_bytes()).to_bytes();
    let pubkey_b64 = encode_b64(vk.to_bytes().as_slice());
    let sig_b64 = encode_b64(sig.as_slice());

    let descriptor = json!({
        "op": op, "server_id": server_id, "path_suffix": path_suffix,
        "x_pubkey": pubkey_b64, "x_ts": ts.to_string(), "x_sig": sig_b64,
    });
    let (status, text) = match node_tunnel(dist_url, &descriptor)? {
        Some(r) => r,
        None => {
            let rt = Runtime::new()?;
            rt.block_on(http_get_blob(dist_url, server_id, path_suffix, &pubkey_b64, ts, &sig_b64))?
        }
    };
    if status == 404 {
        return Ok(None); // блоба ещё нет
    }
    if status != 200 {
        bail!("http {}: {}", status, text);
    }
    let v: Value = serde_json::from_str(&text).map_err(|_| anyhow!("bad_response"))?;
    let blob_b64 = v.get("blob_b64").and_then(|x| x.as_str()).unwrap_or("");
    if blob_b64.is_empty() {
        return Ok(None);
    }
    let blob = decode_b64(blob_b64).map_err(|_| anyhow!("invalid_blob_b64"))?;
    Ok(Some(blob))
}

/// Забрать и расшифровать ВСЮ связку сотрудника (legacy/жадный путь). Возвращает
/// plaintext keyring JSON, либо пустую строку, если блоба ещё нет.
pub fn corp_sync(
    dist_url: &str,
    server_id: &str,
    signing_key_b64: &str,
    psk_b64: &str,
) -> Result<String> {
    let psk = decode_b64(psk_b64).map_err(|_| anyhow!("invalid_psk"))?;
    match fetch_blob(dist_url, server_id, "", "corp.get", signing_key_b64)? {
        None => Ok(String::new()),
        Some(blob) => {
            let (_v, pt) = corp::open(&psk, server_id, corp::CTX_KEYRING, &blob)?;
            String::from_utf8(pt).map_err(|_| anyhow!("bad_utf8"))
        }
    }
}

/// Забрать и расшифровать РОСТЕР сотрудника — список доступных диалогов БЕЗ
/// ключей (ленивая раздача). Возвращает plaintext roster JSON, либо пустую
/// строку, если ростера ещё нет. Клиент показывает его в «Добавить диалог».
pub fn corp_fetch_roster(
    dist_url: &str,
    server_id: &str,
    signing_key_b64: &str,
    psk_b64: &str,
) -> Result<String> {
    let psk = decode_b64(psk_b64).map_err(|_| anyhow!("invalid_psk"))?;
    match fetch_blob(dist_url, server_id, "/roster", "corp.get.roster", signing_key_b64)? {
        None => Ok(String::new()),
        Some(blob) => {
            let (_v, pt) = corp::open(&psk, server_id, corp::CTX_ROSTER, &blob)?;
            String::from_utf8(pt).map_err(|_| anyhow!("bad_utf8"))
        }
    }
}

/// Забрать и расшифровать ключ ОДНОГО диалога с `partner_server_id` (ленивая
/// раздача — скачивается, когда сотрудник добавляет именно этот диалог).
/// Возвращает plaintext dialogue-key JSON, либо пустую строку, если ключа нет.
pub fn corp_fetch_dialogue(
    dist_url: &str,
    server_id: &str,
    partner_server_id: &str,
    signing_key_b64: &str,
    psk_b64: &str,
) -> Result<String> {
    let psk = decode_b64(psk_b64).map_err(|_| anyhow!("invalid_psk"))?;
    let suffix = format!("/dialogue/{partner_server_id}");
    match fetch_blob(dist_url, server_id, &suffix, "corp.get.dialogue", signing_key_b64)? {
        None => Ok(String::new()),
        Some(blob) => {
            let ctx = corp::ctx_dialogue(partner_server_id);
            let (_v, pt) = corp::open(&psk, server_id, &ctx, &blob)?;
            String::from_utf8(pt).map_err(|_| anyhow!("bad_utf8"))
        }
    }
}
