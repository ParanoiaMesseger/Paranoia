//! Admin-операции над реестром пользователей.

use super::{AdminEnvelope, Capability, config_path, err_json, verify};
use crate::AppState;
use axum::{Json, extract::State};
use serde_json::{Map, Value, json};
use std::sync::Arc;
use tracing::{info, warn};

/// `PUT /admin/users/list` — вернуть реестр `username → pubkey_b64` и его размер.
pub async fn list(
    State(state): State<Arc<AppState>>,
    Json(env): Json<AdminEnvelope>,
) -> Json<Value> {
    if let Err(e) = verify(&state, &env, "list_users", "", Capability::Base).await {
        return err_json(&e);
    }
    let cfg = state.config.read().await;
    let users: Map<String, Value> = cfg
        .users
        .iter()
        .map(|(k, v)| (k.clone(), Value::String(v.clone())))
        .collect();
    Json(json!({
        "success": true,
        "count": users.len(),
        "users": users,
    }))
}

/// `PUT /admin/users/delete` — удалить пользователя из `config.users`.
pub async fn delete(
    State(state): State<Arc<AppState>>,
    Json(env): Json<AdminEnvelope>,
) -> Json<Value> {
    let username = match env.username.clone() {
        Some(u) if !u.is_empty() => u,
        _ => return err_json("missing_username"),
    };
    if let Err(e) = verify(&state, &env, "delete_user", &username, Capability::Base).await {
        return err_json(&e);
    }

    let mut cfg = state.config.write().await;
    if cfg.users.remove(&username).is_none() {
        return err_json("user_not_found");
    }
    if let Err(e) = cfg.save(&config_path()) {
        warn!("Failed to persist config after deleting '{username}': {e}");
        return err_json("config_save_failed");
    }
    info!("Admin deleted user '{username}'");
    Json(json!({ "success": true, "message": "OK" }))
}
