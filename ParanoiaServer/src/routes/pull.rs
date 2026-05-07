use crate::{crypto, AppState};
use axum::{extract::State, Json};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::sync::Arc;
use tracing::warn;

#[derive(Deserialize)]
pub struct PullRequest {
    pub sender: String,
    pub recver: String,
    pub after_seq: u64,
    pub sig: String, // подпись от sender+recver+after_seq
}

#[derive(Serialize)]
pub struct ApiResponse {
    pub success: bool,
    pub message: Value,
}

pub async fn handle(State(state): State<Arc<AppState>>, Json(body): Json<Value>) -> Json<Value> {
    // Cover → Core
    let req = match state.cover.unwrap_pull(&body) {
        Ok(r) => r,
        Err(e) => {
            state.metrics.inc_pull_fail();
            warn!("Bad cover in pull: {e}");
            return Json(json!({
                "ok": false,
                "status": "error",
                "message": format!("Bad cover: {e}"),
            }));
        }
    };

    let core_resp = do_pull(&state, req).await;
    let wrapped = state.cover.wrap_pull_response(&core_resp);
    Json(wrapped)
}

async fn do_pull(state: &Arc<AppState>, req: PullRequest) -> ApiResponse {
    let m = &state.metrics;

    let sig = match crypto::decode_b64(&req.sig) {
        Ok(v) => v,
        Err(_) => {
            m.inc_pull_fail();
            return fail("Bad sig encoding".into());
        }
    };

    // Подписать может любой из участников диалога — проверяем обоих
    let (sender_pub, recver_pub) = {
        let cfg = state.config.read().await;
        let s = cfg.user_pubkey_bytes(&req.sender);
        let r = cfg.user_pubkey_bytes(&req.recver);
        match (s, r) {
            (Some(s), Some(r)) => (s, r),
            _ => {
                m.inc_pull_fail();
                return fail("One user in pair not registered".into());
            }
        }
    };

    let signed_msg = format!("{}{}{}", req.sender, req.recver, req.after_seq);
    let valid = crypto::verify_signature(&sender_pub, signed_msg.as_bytes(), &sig).is_ok()
        || crypto::verify_signature(&recver_pub, signed_msg.as_bytes(), &sig).is_ok();

    if !valid {
        m.inc_pull_fail();
        dbg!(
            "Invalid pull signature for dialogue {}<->{}",
            req.sender,
            req.recver
        );
        return fail("Invalid signature".into());
    }

    let dialogue_id = crypto::make_dialogue_id(&req.sender, &req.recver);
    match state.store.pull(&dialogue_id, req.after_seq) {
        Ok(packets) => {
            let arr: Vec<Value> = packets
                .into_iter()
                .map(|(seq, data)| {
                    serde_json::json!({
                        "seq":     seq,
                        "payload": crypto::encode_b64(&data),
                    })
                })
                .collect();
            m.inc_pull_success();
            ApiResponse {
                success: true,
                message: Value::Array(arr),
            }
        }
        Err(e) => {
            m.inc_pull_fail();
            fail(format!("{e}"))
        }
    }
}

fn fail(msg: String) -> ApiResponse {
    ApiResponse {
        success: false,
        message: Value::String(msg),
    }
}
