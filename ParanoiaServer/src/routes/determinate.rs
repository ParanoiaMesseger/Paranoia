use crate::{crypto, AppState};
use axum::{extract::State, Json};
use serde::{Deserialize, Serialize};
use std::sync::Arc;

#[derive(Deserialize)]
pub struct DeterminateRequest {
    pub sender: String,
    pub recver: String,
    pub cut_seq: u64,
    pub sig: String, // подпись от sender+recver+cut_seq
}

#[derive(Serialize)]
pub struct ApiResponse {
    pub success: bool,
    pub message: String,
}

pub async fn handle(
    State(state): State<Arc<AppState>>,
    Json(req): Json<DeterminateRequest>,
) -> Json<ApiResponse> {
    Json(do_determinate(state, req).await)
}

async fn do_determinate(state: Arc<AppState>, req: DeterminateRequest) -> ApiResponse {
    let m = &state.metrics;

    let sig = match crypto::decode_b64(&req.sig) {
        Ok(v) => v,
        Err(_) => {
            m.inc_determinate_fail();
            return fail("Bad sig encoding".into());
        }
    };

    // Удалить может любой участник диалога — проверяем обоих
    let (sender_pub, recver_pub) = {
        let cfg = state.config.read().await;
        let s = cfg.user_pubkey_bytes(&req.sender);
        let r = cfg.user_pubkey_bytes(&req.recver);
        match (s, r) {
            (Some(s), Some(r)) => (s, r),
            _ => {
                m.inc_determinate_fail();
                return fail("One user in pair not registered".into());
            }
        }
    };

    let signed_msg = format!("{}{}{}", req.sender, req.recver, req.cut_seq);
    let valid = crypto::verify_signature(&sender_pub, signed_msg.as_bytes(), &sig).is_ok()
        || crypto::verify_signature(&recver_pub, signed_msg.as_bytes(), &sig).is_ok();

    if !valid {
        m.inc_determinate_fail();
        dbg!(
            "Invalid determinate signature for dialogue {}<->{}",
            req.sender,
            req.recver
        );
        return fail("Invalid signature".into());
    }

    let dialogue_id = crypto::make_dialogue_id(&req.sender, &req.recver);
    match state.store.remove_until(&dialogue_id, req.cut_seq) {
        Ok(_) => {
            m.inc_determinate_success();
            dbg!(
                "Dialogue {}<->{}: removed up to seq {}",
                req.sender,
                req.recver,
                req.cut_seq
            );
            ok("OK".into())
        }
        Err(e) => {
            m.inc_determinate_fail();
            fail(format!("{e}"))
        }
    }
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
