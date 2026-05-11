use crate::{AppState, crypto};
use axum::{Json, extract::State};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::sync::Arc;
use tracing::warn;

#[derive(Deserialize)]
pub struct NotifyRequest {
    pub sender: String,
    pub partner: String,
    pub seq: u64,
    pub sig: String, // подпись от sender+partner+seq
}

#[derive(Serialize)]
pub struct ApiResponse {
    pub success: bool,
    pub n: u64,
    pub message: String,
}

pub async fn handle(State(state): State<Arc<AppState>>, Json(body): Json<Value>) -> Json<Value> {
    // Cover -> Core
    let req = match state.cover.unwrap_notify(&body) {
        Ok(r) => r,
        Err(e) => {
            warn!("Bad cover in notify: {e}");
            return Json(json!({
                "ok": false,
                "status": "error",
                "message": format!("Bad cover: {e}"),
            }));
        }
    };

    let core_resp = do_notify(&state, req).await;
    let wrapped = state.cover.wrap_notify_response(&core_resp);
    Json(wrapped)
}

async fn do_notify(state: &Arc<AppState>, req: NotifyRequest) -> ApiResponse {
    let sig = match crypto::decode_b64(&req.sig) {
        Ok(v) => v,
        Err(_) => return fail("Bad sig encoding".into()),
    };

    let sender_pubkey = {
        let cfg = state.config.read().await;
        if !cfg.users.contains_key(&req.partner) {
            return fail("One user in pair not registered".into());
        }
        match cfg.user_pubkey_bytes(&req.sender) {
            Some(k) => k,
            None => return fail("One user in pair not registered".into()),
        }
    };

    let signed_msg = format!("{}{}{}", req.sender, req.partner, req.seq);
    if let Err(e) = crypto::verify_signature(&sender_pubkey, signed_msg.as_bytes(), &sig) {
        warn!("Invalid notify signature from '{}': {e}", req.sender);
        return fail("Invalid signature".into());
    }

    let dialogue_id = crypto::make_dialogue_id(&req.sender, &req.partner);
    match state.store.count_after(&dialogue_id, req.seq) {
        Ok(n) => ApiResponse {
            success: true,
            n,
            message: String::new(),
        },
        Err(e) => fail(format!("{e}")),
    }
}

fn fail(msg: String) -> ApiResponse {
    ApiResponse {
        success: false,
        n: 0,
        message: msg,
    }
}
