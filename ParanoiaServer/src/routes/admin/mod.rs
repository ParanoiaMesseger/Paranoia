//! Admin-API: маршруты управления сервером, подписанные ключом администратора.
//!
//! Каждый запрос — JSON-конверт [`AdminEnvelope`], подписанный admin
//! `SigningKey`. Сервер сверяет подпись с `config.admin_key` (тем же ключом,
//! что используется для регистрации пользователей), проверяет временное окно и
//! защищается от replay по `nonce`.
//!
//! Каноническое сообщение для подписи строится в [`canonical_message`] и должно
//! ПОБАЙТОВО совпадать с тем, что формирует клиент в
//! `ParanoiaLibrary/src/admin_api.rs`.

use crate::{AppState, crypto};
use axum::{Json, Router, routing::put};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::{Arc, LazyLock, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

pub mod dialogues;
pub mod server_config;
pub mod users;

/// Допустимый перекос времени admin-запроса (вместе с nonce — защита от replay).
const MAX_TS_SKEW_SECS: u64 = 300;

/// Виденные nonce → ts. Очищается от устаревших записей при каждой проверке.
static SEEN_NONCES: LazyLock<Mutex<HashMap<String, u64>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

#[derive(Deserialize)]
pub struct AdminEnvelope {
    /// Имя операции (должно совпадать с маршрутом, см. `verify`).
    pub op: String,
    /// Одноразовый идентификатор запроса (защита от replay).
    pub nonce: String,
    /// Unix-время клиента (секунды).
    pub ts: u64,
    /// Имя пользователя для операций над пользователем.
    #[serde(default)]
    pub username: Option<String>,
    /// Патч конфигурации для `config/set`.
    #[serde(default)]
    pub patch: Option<Value>,
    /// Base64 Ed25519-подпись канонического сообщения.
    pub sig: String,
}

pub fn router() -> Router<Arc<AppState>> {
    Router::new()
        .route("/admin/users/list", put(users::list))
        .route("/admin/users/delete", put(users::delete))
        .route("/admin/dialogues/list", put(dialogues::list))
        .route("/admin/dialogues/prune", put(dialogues::prune))
        .route("/admin/config/get", put(server_config::get))
        .route("/admin/config/set", put(server_config::set))
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Каноническое сообщение для подписи. `extra` — op-специфичная часть
/// (пустая строка для list-операций, username для delete, compact-JSON патча для
/// set_config).
pub fn canonical_message(op: &str, nonce: &str, ts: u64, extra: &str) -> String {
    format!("paranoia-admin\n{op}\n{nonce}\n{ts}\n{extra}")
}

/// Проверить admin-конверт: соответствие op, временное окно, replay по nonce и
/// Ed25519-подпись над каноническим сообщением. Возвращает машиночитаемый код
/// ошибки при провале.
pub async fn verify(
    state: &Arc<AppState>,
    env: &AdminEnvelope,
    expected_op: &str,
    extra: &str,
) -> Result<(), String> {
    if env.op != expected_op {
        return Err("op_mismatch".into());
    }

    let now = now_secs();
    if env.ts > now.saturating_add(MAX_TS_SKEW_SECS)
        || now.saturating_sub(env.ts) > MAX_TS_SKEW_SECS
    {
        return Err("stale_or_future_timestamp".into());
    }

    {
        let mut seen = SEEN_NONCES.lock().unwrap();
        seen.retain(|_, t| now.saturating_sub(*t) <= MAX_TS_SKEW_SECS);
        if seen.contains_key(&env.nonce) {
            return Err("nonce_replayed".into());
        }
        seen.insert(env.nonce.clone(), env.ts);
    }

    let sig = crypto::decode_b64(&env.sig).map_err(|_| "bad_sig_encoding".to_string())?;
    let admin_pub = {
        let cfg = state.config.read().await;
        cfg.admin_pubkey_bytes()
            .map_err(|e| format!("server_config_error: {e}"))?
    };
    let msg = canonical_message(&env.op, &env.nonce, env.ts, extra);
    crypto::verify_signature(&admin_pub, msg.as_bytes(), &sig)
        .map_err(|_| "invalid_admin_signature".to_string())?;
    Ok(())
}

/// Путь к конфигу сервера (тот же, что использует `main.rs`).
pub fn config_path() -> String {
    std::env::var("PARANOIA_CONFIG").unwrap_or_else(|_| "./configs/Paranoia.json".to_string())
}

pub fn err_json(message: &str) -> Json<Value> {
    Json(json!({ "success": false, "message": message }))
}
