//! `PUT /call/signal` — отправитель кладёт сигнальный конверт в очередь recver'a.
//!
//! Конверт зашифрован dialog master key'ом (сервер его не расшифровывает).
//! Сервер видит только {sender, recver, kind, payload_size, ts}.

use crate::{
    AppState,
    call_signal::{CallEnvelope, MAX_PAYLOAD_LEN},
    crypto,
};
use axum::{Json, extract::State};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Instant;
use tracing::warn;

#[derive(Deserialize)]
pub struct CallSignalRequest {
    pub sender: String,
    pub recver: String,
    pub kind: u8,
    pub payload: String, // base64 шифротекста (см. clients voip::signaling::seal)
    pub ts_ms: i64,
    pub sig: String, // ed25519: sign(sender + recver + kind + ts_ms + payload)
}

#[derive(Serialize)]
pub struct ApiResponse {
    pub success: bool,
    pub message: String,
}

pub async fn handle(State(state): State<Arc<AppState>>, Json(body): Json<Value>) -> Json<Value> {
    let req = match state.cover.unwrap_call_signal(&body) {
        Ok(r) => r,
        Err(e) => {
            warn!("Bad cover in call/signal: {e}");
            return Json(json!({
                "ok": false,
                "status": "error",
                "message": format!("Bad cover: {e}"),
            }));
        }
    };
    let core_resp = do_signal(&state, req).await;
    Json(state.cover.wrap_call_signal_response(&core_resp))
}

async fn do_signal(state: &Arc<AppState>, req: CallSignalRequest) -> ApiResponse {
    let sig = match crypto::decode_b64(&req.sig) {
        Ok(v) => v,
        Err(_) => return fail("Bad sig encoding".into()),
    };
    let payload_bytes = match crypto::decode_b64(&req.payload) {
        Ok(v) => v,
        Err(_) => return fail("Bad payload encoding".into()),
    };
    if payload_bytes.len() > MAX_PAYLOAD_LEN {
        return fail(format!(
            "Payload too large: {} > {MAX_PAYLOAD_LEN}",
            payload_bytes.len()
        ));
    }

    // Проверка регистрации обоих и подписи отправителя.
    let sender_pubkey = {
        let cfg = state.config.read().await;
        if !cfg.users.contains_key(&req.recver) {
            return fail("recver not registered".into());
        }
        match cfg.user_pubkey_bytes(&req.sender) {
            Some(k) => k,
            None => return fail("sender not registered".into()),
        }
    };

    let signed_msg = format!(
        "{}{}{}{}{}",
        req.sender, req.recver, req.kind, req.ts_ms, req.payload
    );
    if let Err(e) = crypto::verify_signature(&sender_pubkey, signed_msg.as_bytes(), &sig) {
        warn!("Invalid call/signal signature from '{}': {e}", req.sender);
        return fail("Invalid signature".into());
    }

    let envelope = CallEnvelope {
        sender: req.sender,
        kind: req.kind,
        payload: payload_bytes,
        ts_ms: req.ts_ms,
        received: Instant::now(),
    };
    state.call_signals.push(req.recver, envelope).await;
    ok("queued".into())
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
