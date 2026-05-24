use crate::{AppState, crypto, store::MapResult};
use axum::{Json, extract::State};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::sync::Arc;
use tracing::warn;

/// Максимальное число runs в одном ответе. При превышении клиент дозапрашивает
/// с `after_seq = последний_возвращённый_end`.
pub const MAP_MAX_RUNS: usize = 8192;

#[derive(Deserialize)]
pub struct MapRequest {
    pub sender: String,
    pub recver: String,
    pub after_seq: u64,
    pub to_seq: u64, // 0 = открытый правый конец
    pub sig: String, // подпись от sender+recver+after_seq+to_seq
}

#[derive(Serialize)]
pub struct ApiResponse {
    pub success: bool,
    pub runs: Vec<(u64, u64)>,
    pub last_seq: u64,
    pub truncated: bool,
    pub message: String,
}

pub async fn handle(State(state): State<Arc<AppState>>, Json(body): Json<Value>) -> Json<Value> {
    let req = match state.cover.unwrap_map(&body) {
        Ok(r) => r,
        Err(e) => {
            warn!("Bad cover in map: {e}");
            return Json(json!({
                "ok": false,
                "status": "error",
                "message": format!("Bad cover: {e}"),
            }));
        }
    };

    let core_resp = do_map(&state, req).await;
    let wrapped = state.cover.wrap_map_response(&core_resp);
    Json(wrapped)
}

async fn do_map(state: &Arc<AppState>, req: MapRequest) -> ApiResponse {
    let sig = match crypto::decode_b64(&req.sig) {
        Ok(v) => v,
        Err(_) => return fail("Bad sig encoding".into()),
    };

    if req.to_seq != 0 && req.to_seq <= req.after_seq {
        return fail("Invalid map range".into());
    }

    // Подписать может любой участник диалога — проверяем обоих.
    let (sender_pub, recver_pub) = {
        let cfg = state.config.read().await;
        let s = cfg.user_pubkey_bytes(&req.sender);
        let r = cfg.user_pubkey_bytes(&req.recver);
        match (s, r) {
            (Some(s), Some(r)) => (s, r),
            _ => return fail("One user in pair not registered".into()),
        }
    };

    let signed_msg = format!(
        "{}{}{}{}",
        req.sender, req.recver, req.after_seq, req.to_seq
    );
    let valid = crypto::verify_signature(&sender_pub, signed_msg.as_bytes(), &sig).is_ok()
        || crypto::verify_signature(&recver_pub, signed_msg.as_bytes(), &sig).is_ok();
    if !valid {
        warn!(
            "Invalid map signature for dialogue {}<->{}",
            req.sender, req.recver
        );
        return fail("Invalid signature".into());
    }

    let dialogue_id = crypto::make_dialogue_id(&req.sender, &req.recver);
    match state
        .store
        .map(&dialogue_id, req.after_seq, req.to_seq, MAP_MAX_RUNS)
    {
        Ok(MapResult {
            runs,
            last_seq,
            truncated,
        }) => ApiResponse {
            success: true,
            runs,
            last_seq,
            truncated,
            message: String::new(),
        },
        Err(e) => fail(format!("{e}")),
    }
}

fn fail(msg: String) -> ApiResponse {
    ApiResponse {
        success: false,
        runs: Vec::new(),
        last_seq: 0,
        truncated: false,
        message: msg,
    }
}
