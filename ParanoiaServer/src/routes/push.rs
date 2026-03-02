use std::sync::Arc;
use axum::{extract::State, Json};
use serde::{Deserialize, Serialize};
use tracing::warn;
use crate::{AppState, crypto};

#[derive(Deserialize)]
pub struct PushRequest {
    sender:  String,
    recver:  String,
    seq:     u64,
    payload: String, // base64
    sig:     String, // base64, 64 bytes — подпись от sender+recver+seq+payload(base64)
}

#[derive(Serialize)]
pub struct ApiResponse {
    success: bool,
    message: String,
}

pub async fn handle(
    State(state): State<Arc<AppState>>,
    Json(req): Json<PushRequest>,
) -> Json<ApiResponse> {
    Json(do_push(state, req).await)
}

async fn do_push(state: Arc<AppState>, req: PushRequest) -> ApiResponse {
    let m = &state.metrics;

    let sig = match crypto::decode_b64(&req.sig) {
        Ok(v) => v,
        Err(_) => { m.push_fail.inc(); return fail("Bad sig encoding".into()); }
    };
    let payload_bytes = match crypto::decode_b64(&req.payload) {
        Ok(v) => v,
        Err(_) => { m.push_fail.inc(); return fail("Bad payload encoding".into()); }
    };

    // Проверяем регистрацию sender и recver
    let sender_pubkey = {
        let cfg = state.config.read().await;
        if !cfg.users.contains_key(&req.recver) {
            m.push_fail.inc();
            return fail("One user in pair not registered".into());
        }
        match cfg.user_pubkey_bytes(&req.sender) {
            Some(k) => k,
            None => { m.push_fail.inc(); return fail("One user in pair not registered".into()); }
        }
    };

    // Подписываемое сообщение: sender + recver + seq(decimal string) + payload(base64 string)
    let signed_msg = format!("{}{}{}{}", req.sender, req.recver, req.seq, req.payload);
    if let Err(e) = crypto::verify_signature(&sender_pubkey, signed_msg.as_bytes(), &sig) {
        m.push_fail.inc();
        warn!("Invalid push signature from '{}': {e}", req.sender);
        return fail("Invalid signature".into());
    }

    let dialogue_id = crypto::make_dialogue_id(&req.sender, &req.recver);
    match state.store.push(&dialogue_id, req.seq, &payload_bytes) {
        Ok(_)  => { m.push_success.inc(); ok("OK".into()) }
        Err(e) => { m.push_fail.inc(); fail(format!("{e}")) }
    }
}

fn ok(msg: String)   -> ApiResponse { ApiResponse { success: true,  message: msg } }
fn fail(msg: String) -> ApiResponse { ApiResponse { success: false, message: msg } }
