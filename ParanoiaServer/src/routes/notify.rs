use crate::{AppState, crypto};
use axum::{Json, extract::State};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tracing::warn;

#[derive(Deserialize)]
pub struct NotifyRequest {
    pub sender: String,
    pub partner: String,
    pub seq: u64,
    pub sig: String, // подпись от sender+partner+seq
    /// Желаемое удержание long-poll (мс). `0`/отсутствует — мгновенный ответ
    /// (короткий поллинг, как раньше). Иначе сервер держит запрос до
    /// `min(long_poll_ms, config.notify_long_poll_max_ms)` или нового сообщения.
    /// НЕ входит в подпись: тело уже под cover-AEAD, а величина капается сервером
    /// и не несёт прав — это лишь длительность ожидания.
    #[serde(default)]
    pub long_poll_ms: u32,
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

    let (sender_pubkey, long_poll_cap) = {
        let cfg = state.config.read().await;
        if !cfg.users.contains_key(&req.partner) {
            return fail("One user in pair not registered".into());
        }
        let pk = match cfg.user_pubkey_bytes(&req.sender) {
            Some(k) => k,
            None => return fail("One user in pair not registered".into()),
        };
        (pk, cfg.notify_long_poll_max_ms)
    };

    let signed_msg = format!("{}{}{}", req.sender, req.partner, req.seq);
    if let Err(e) = crypto::verify_signature(&sender_pubkey, signed_msg.as_bytes(), &sig) {
        warn!("Invalid notify signature from '{}': {e}", req.sender);
        return fail("Invalid signature".into());
    }

    let dialogue_id = crypto::make_dialogue_id(&req.sender, &req.partner);

    // Быстрая ветка: уже есть новые — отдать сразу.
    match state.store.count_after(&dialogue_id, req.seq) {
        Ok(n) if n > 0 => return ok(n),
        Ok(_) => {}
        Err(e) => return fail(format!("{e}")),
    }

    // Long-poll: держать запрос до нового сообщения или таймаута. Потолок на
    // сервере (config). `wait_ms == 0` → мгновенный ответ (короткий поллинг —
    // клиент не просил long-poll ИЛИ сервер его выключил для CDN-совместимости).
    let wait_ms = req.long_poll_ms.min(long_poll_cap);
    if wait_ms == 0 {
        return ok(0);
    }

    // Берём waker ДО повторной проверки count — иначе можно пропустить notify,
    // случившийся между count и подпиской (тот же паттерн, что в call/poll).
    let waker = state.dialogue_notify.waker(&dialogue_id).await;
    let notified = waker.notified();
    tokio::pin!(notified);
    match state.store.count_after(&dialogue_id, req.seq) {
        Ok(n) if n > 0 => return ok(n),
        Ok(_) => {}
        Err(e) => return fail(format!("{e}")),
    }

    let _ = tokio::time::timeout(Duration::from_millis(wait_ms as u64), notified.as_mut()).await;
    match state.store.count_after(&dialogue_id, req.seq) {
        Ok(n) => ok(n),
        Err(e) => fail(format!("{e}")),
    }
}

fn ok(n: u64) -> ApiResponse {
    ApiResponse {
        success: true,
        n,
        message: String::new(),
    }
}

fn fail(msg: String) -> ApiResponse {
    ApiResponse {
        success: false,
        n: 0,
        message: msg,
    }
}
