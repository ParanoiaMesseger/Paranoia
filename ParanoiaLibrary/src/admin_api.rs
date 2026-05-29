//! Клиентская сторона admin-API сервера (см. `ParanoiaServer/src/routes/admin`).
//!
//! Все функции stateless: принимают URL сервера, резервные URL и приватный ключ
//! администратора (base64), строят подписанный конверт, делают plain-JSON `PUT`
//! через [`crate::transport::Transport`] и возвращают тело ответа сервера как
//! JSON-строку.
//!
//! Каноническое сообщение для подписи ДОЛЖНО ПОБАЙТОВО совпадать с
//! `ParanoiaServer/src/routes/admin/mod.rs::canonical_message`.

use anyhow::{Result, anyhow};
use serde_json::{Map, Value};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::runtime::Runtime;
use uuid::Uuid;

use crate::AdminKeyPair;
use crate::client_cover_food::FoodDeliveryClientCover;
use crate::transport::Transport;

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn canonical_message(op: &str, nonce: &str, ts: u64, extra: &str) -> String {
    format!("paranoia-admin\n{op}\n{nonce}\n{ts}\n{extra}")
}

/// Путь маршрута для операции.
fn op_path(op: &str) -> &'static str {
    match op {
        "list_users" => "/admin/users/list",
        "delete_user" => "/admin/users/delete",
        "list_dialogues" => "/admin/dialogues/list",
        "prune" => "/admin/dialogues/prune",
        "get_config" => "/admin/config/get",
        "set_config" => "/admin/config/set",
        _ => "/admin/unknown",
    }
}

/// Выполнить подписанный admin-запрос и вернуть тело ответа как JSON-строку.
fn do_admin(
    server_url: &str,
    reserve_urls: &[String],
    admin_secret_b64: &str,
    op: &str,
    username: Option<&str>,
    patch: Option<Value>,
) -> Result<String> {
    let kp =
        AdminKeyPair::from_secret_b64(admin_secret_b64).map_err(|_| anyhow!("invalid_admin_key"))?;

    let nonce = Uuid::new_v4().to_string();
    let ts = now_secs();

    let extra = match op {
        "delete_user" => username.unwrap_or("").to_string(),
        "set_config" => serde_json::to_string(&patch.clone().unwrap_or(Value::Null))?,
        _ => String::new(),
    };
    let sig = kp.sign_canonical(&canonical_message(op, &nonce, ts, &extra));

    let mut env = Map::new();
    env.insert("op".into(), Value::String(op.to_string()));
    env.insert("nonce".into(), Value::String(nonce));
    env.insert("ts".into(), Value::Number(ts.into()));
    if let Some(u) = username {
        env.insert("username".into(), Value::String(u.to_string()));
    }
    if let Some(p) = patch {
        env.insert("patch".into(), p);
    }
    env.insert("sig".into(), Value::String(sig));
    let body = Value::Object(env);

    let rt = Runtime::new()?;
    let cover = Arc::new(FoodDeliveryClientCover::new());
    let transport = Transport::new(server_url, reserve_urls.iter().map(String::as_str), cover);
    let resp = rt.block_on(transport.put_json(op_path(op), &body))?;
    Ok(serde_json::to_string(&resp)?)
}

pub fn list_users(server_url: &str, reserve_urls: &[String], admin_secret_b64: &str) -> Result<String> {
    do_admin(server_url, reserve_urls, admin_secret_b64, "list_users", None, None)
}

pub fn delete_user(
    server_url: &str,
    reserve_urls: &[String],
    admin_secret_b64: &str,
    username: &str,
) -> Result<String> {
    do_admin(
        server_url,
        reserve_urls,
        admin_secret_b64,
        "delete_user",
        Some(username),
        None,
    )
}

pub fn list_dialogues(
    server_url: &str,
    reserve_urls: &[String],
    admin_secret_b64: &str,
) -> Result<String> {
    do_admin(server_url, reserve_urls, admin_secret_b64, "list_dialogues", None, None)
}

pub fn prune_dialogues(
    server_url: &str,
    reserve_urls: &[String],
    admin_secret_b64: &str,
) -> Result<String> {
    do_admin(server_url, reserve_urls, admin_secret_b64, "prune", None, None)
}

pub fn get_config(server_url: &str, reserve_urls: &[String], admin_secret_b64: &str) -> Result<String> {
    do_admin(server_url, reserve_urls, admin_secret_b64, "get_config", None, None)
}

pub fn set_config(
    server_url: &str,
    reserve_urls: &[String],
    admin_secret_b64: &str,
    patch_json: &str,
) -> Result<String> {
    let patch: Value = serde_json::from_str(patch_json).map_err(|e| anyhow!("invalid_patch_json: {e}"))?;
    do_admin(
        server_url,
        reserve_urls,
        admin_secret_b64,
        "set_config",
        None,
        Some(patch),
    )
}

/// Зарегистрировать пользователя через тот же put_json-путь, что и admin-API
/// (идентично transport.reg, но используется единый код-путь). Возвращает тело
/// ответа сервера как JSON-строку.
pub fn register_user(
    server_url: &str,
    reserve_urls: &[String],
    admin_secret_b64: &str,
    username: &str,
    user_pubkey_b64: &str,
) -> Result<String> {
    let kp =
        AdminKeyPair::from_secret_b64(admin_secret_b64).map_err(|_| anyhow!("invalid_admin_key"))?;
    let sig = kp.sign_user_registration(username, user_pubkey_b64);
    let body = serde_json::json!({
        "username": username,
        "pub_key": user_pubkey_b64,
        "admin_sig": sig,
    });

    let rt = Runtime::new()?;
    let cover = Arc::new(FoodDeliveryClientCover::new());
    let transport = Transport::new(server_url, reserve_urls.iter().map(String::as_str), cover);
    let resp = rt.block_on(transport.put_json("/reg", &body))?;
    Ok(serde_json::to_string(&resp)?)
}

/// Вывести admin-pubkey (base64) из приватного ключа — для QR-экспорта и
/// отображения.
pub fn admin_pubkey(admin_secret_b64: &str) -> Result<String> {
    let kp =
        AdminKeyPair::from_secret_b64(admin_secret_b64).map_err(|_| anyhow!("invalid_admin_key"))?;
    Ok(kp.pubkey_b64())
}
