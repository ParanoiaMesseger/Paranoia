//! Admin-операции над конфигурацией сервера.
//!
//! Менять разрешено только безопасные поля (`port`, `stun_bind`,
//! `turn_public_ip`, `turn_relay_port_range`). `admin_key`, `users` и
//! `store_path` через этот API не изменяются.

use super::{AdminEnvelope, Capability, config_path, err_json, verify};
use crate::AppState;
use axum::{Json, extract::State};
use serde_json::{Value, json};
use std::sync::Arc;
use tracing::{info, warn};

/// `PUT /admin/config/get` — вернуть безопасное представление конфига.
pub async fn get(State(state): State<Arc<AppState>>, Json(env): Json<AdminEnvelope>) -> Json<Value> {
    if let Err(e) = verify(&state, &env, "get_config", "", Capability::Extended).await {
        return err_json(&e);
    }
    let cfg = state.config.read().await;
    Json(json!({
        "success": true,
        "config": {
            "port": cfg.port,
            "store_path": cfg.store_path,
            "admin_key": cfg.admin_key,
            "stun_bind": cfg.stun_bind,
            "turn_public_ip": cfg.turn_public_ip,
            "turn_relay_port_range": cfg.turn_relay_port_range,
            "users_count": cfg.users.len(),
        }
    }))
}

/// Каноническая compact-сериализация патча (для подписи). Должна совпадать с
/// клиентом.
fn patch_extra(patch: &Option<Value>) -> String {
    serde_json::to_string(&patch.clone().unwrap_or(Value::Null)).unwrap_or_default()
}

/// `PUT /admin/config/set` — применить патч безопасных полей и сохранить конфиг.
pub async fn set(State(state): State<Arc<AppState>>, Json(env): Json<AdminEnvelope>) -> Json<Value> {
    let extra = patch_extra(&env.patch);
    if let Err(e) = verify(&state, &env, "set_config", &extra, Capability::Extended).await {
        return err_json(&e);
    }
    let Some(patch) = env.patch.clone() else {
        return err_json("missing_patch");
    };
    let Some(obj) = patch.as_object() else {
        return err_json("patch_must_be_object");
    };

    let mut cfg = state.config.write().await;

    if let Some(v) = obj.get("port") {
        match v.as_u64() {
            Some(p) if (1..=65535).contains(&p) => cfg.port = p as u16,
            _ => return err_json("invalid_port"),
        }
    }
    // Строковые опции: null → сбросить в None, строка → задать.
    if let Some(v) = obj.get("stun_bind") {
        cfg.stun_bind = string_or_null(v);
    }
    if let Some(v) = obj.get("turn_public_ip") {
        cfg.turn_public_ip = string_or_null(v);
    }
    if let Some(v) = obj.get("turn_relay_port_range") {
        cfg.turn_relay_port_range = string_or_null(v);
    }

    if let Err(e) = cfg.save(&config_path()) {
        warn!("Failed to persist config after admin set: {e}");
        return err_json("config_save_failed");
    }
    info!("Admin updated server config");
    Json(json!({ "success": true, "message": "OK" }))
}

fn string_or_null(v: &Value) -> Option<String> {
    match v {
        Value::Null => None,
        Value::String(s) if s.trim().is_empty() => None,
        Value::String(s) => Some(s.clone()),
        _ => None,
    }
}
