//! `PUT /call/poll` — получатель забирает накопленные конверты с поддержкой long-poll.
//!
//! Возвращает массив конвертов адресованных `user`. Если очередь пуста и
//! `long_poll_ms > 0`, сервер ждёт появления первого конверта до таймаута, после
//! чего отдаёт результат (возможно пустой).

use crate::{AppState, crypto};
use axum::{Json, extract::State};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tracing::warn;

/// Жёсткий потолок long-poll, чтобы не держать соединения дольше HTTP-таймаутов
/// промежуточных прокси.
pub const MAX_LONG_POLL_MS: u32 = 30_000;

#[derive(Deserialize)]
pub struct CallPollRequest {
    pub user: String,
    pub nonce: u64,
    pub long_poll_ms: u32,
    pub sig: String, // ed25519: sign(user + nonce + long_poll_ms)
}

#[derive(Serialize, Clone)]
pub struct CallEnvelopeOut {
    pub sender: String,
    pub kind: u8,
    pub payload: String, // base64
    pub ts_ms: i64,
}

#[derive(Serialize)]
pub struct ApiResponse {
    pub success: bool,
    pub items: Vec<CallEnvelopeOut>,
    pub message: String,
}

pub async fn handle(State(state): State<Arc<AppState>>, Json(body): Json<Value>) -> Json<Value> {
    let req = match state.cover.unwrap_call_poll(&body) {
        Ok(r) => r,
        Err(e) => {
            warn!("Bad cover in call/poll: {e}");
            return Json(json!({
                "ok": false,
                "status": "error",
                "message": format!("Bad cover: {e}"),
            }));
        }
    };
    let core_resp = do_poll(&state, req).await;
    Json(state.cover.wrap_call_poll_response(&core_resp))
}

async fn do_poll(state: &Arc<AppState>, req: CallPollRequest) -> ApiResponse {
    let sig = match crypto::decode_b64(&req.sig) {
        Ok(v) => v,
        Err(_) => return fail("Bad sig encoding".into()),
    };
    let user_pubkey = {
        let cfg = state.config.read().await;
        match cfg.user_pubkey_bytes(&req.user) {
            Some(k) => k,
            None => return fail("user not registered".into()),
        }
    };
    let signed_msg = format!("{}{}{}", req.user, req.nonce, req.long_poll_ms);
    if let Err(e) = crypto::verify_signature(&user_pubkey, signed_msg.as_bytes(), &sig) {
        warn!("Invalid call/poll signature from '{}': {e}", req.user);
        return fail("Invalid signature".into());
    }

    // Быстрая ветка: уже есть конверты — отдать сразу.
    let immediate = state.call_signals.drain(&req.user).await;
    if !immediate.is_empty() {
        return ok(immediate
            .into_iter()
            .map(|e| CallEnvelopeOut {
                sender: e.sender,
                kind: e.kind,
                payload: crypto::encode_b64(&e.payload),
                ts_ms: e.ts_ms,
            })
            .collect());
    }
    if req.long_poll_ms == 0 {
        return ok(Vec::new());
    }

    let wait_ms = req.long_poll_ms.min(MAX_LONG_POLL_MS);
    let waker = state.call_signals.waker(&req.user).await;
    // notified() должен быть взят до повторной проверки drain — иначе можно
    // пропустить notify, случившийся между ними. Но при first-drain мы уже
    // знаем, что было пусто; гонка возможна: push мог произойти между drain и
    // подпиской. Берём notified() заранее и потом ещё раз дренаж — стандартный
    // паттерн.
    let notified = waker.notified();
    tokio::pin!(notified);
    // Перепроверим — могло прийти, пока мы регистрировали waker.
    let pending = state.call_signals.drain(&req.user).await;
    if !pending.is_empty() {
        return ok(pending
            .into_iter()
            .map(|e| CallEnvelopeOut {
                sender: e.sender,
                kind: e.kind,
                payload: crypto::encode_b64(&e.payload),
                ts_ms: e.ts_ms,
            })
            .collect());
    }

    let _ = tokio::time::timeout(Duration::from_millis(wait_ms as u64), notified.as_mut()).await;
    let items = state.call_signals.drain(&req.user).await;
    ok(items
        .into_iter()
        .map(|e| CallEnvelopeOut {
            sender: e.sender,
            kind: e.kind,
            payload: crypto::encode_b64(&e.payload),
            ts_ms: e.ts_ms,
        })
        .collect())
}

fn ok(items: Vec<CallEnvelopeOut>) -> ApiResponse {
    ApiResponse {
        success: true,
        items,
        message: String::new(),
    }
}
fn fail(msg: String) -> ApiResponse {
    ApiResponse {
        success: false,
        items: Vec::new(),
        message: msg,
    }
}
