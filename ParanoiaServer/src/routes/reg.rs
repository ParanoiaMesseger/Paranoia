use crate::{AppState, crypto};
use axum::{Json, extract::State};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tracing::{info, warn};

#[derive(Deserialize)]
pub struct RegRequest {
    pub username: String,
    pub pub_key: String,   // base64, 32 bytes
    pub admin_sig: String, // base64, 64 bytes
}

#[derive(Serialize)]
pub struct ApiResponse {
    success: bool,
    message: String,
}

pub async fn handle(
    State(state): State<Arc<AppState>>,
    Json(req): Json<RegRequest>,
) -> Json<ApiResponse> {
    let result = do_reg(state, req).await;
    Json(result)
}

async fn do_reg(state: Arc<AppState>, req: RegRequest) -> ApiResponse {
    // Decode fields
    let admin_sig = match crypto::decode_b64(&req.admin_sig) {
        Ok(v) => v,
        Err(e) => {
            return fail(format!("Bad admin_sig: {e}"));
        }
    };
    let user_pub = match crypto::decode_b64(&req.pub_key) {
        Ok(v) => v,
        Err(e) => {
            return fail(format!("Bad pub_key: {e}"));
        }
    };
    if user_pub.len() != 32 {
        return fail("pub_key must be 32 bytes".into());
    }

    // Регистрация — операция уровня BASE: принимаем подпись base- или
    // extended-ключа (extended ⊇ base).
    let signed_msg = format!("{}{}", req.username, req.pub_key);
    if let Err(e) = crate::routes::admin::verify_admin_sig(
        &state,
        signed_msg.as_bytes(),
        &admin_sig,
        crate::routes::admin::Capability::Base,
    )
    .await
    {
        warn!("Rejected registration for '{}': {e}", req.username);
        return fail(format!("Invalid admin signature: {e}"));
    }

    // Register user
    let mut cfg = state.config.write().await;
    if cfg.users.contains_key(&req.username) {
        return fail("User already exists".into());
    }
    cfg.users.insert(req.username.clone(), req.pub_key);
    drop(cfg);

    // Persist
    let cfg = state.config.read().await;
    if let Err(e) = cfg.save("./configs/Paranoia.json") {
        warn!("Failed to save config: {e}");
    }

    info!("User '{}' registered", req.username);
    ok("OK".into())
}

fn ok(msg: String) -> ApiResponse {
    ApiResponse {
        success: true,
        message: msg,
    }
}
fn fail(msg: String) -> ApiResponse {
    ApiResponse {
        success: false,
        message: msg,
    }
}
