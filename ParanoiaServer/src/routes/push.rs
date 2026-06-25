use crate::{AppState, crypto};
use axum::{Json, extract::State};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::sync::Arc;
use tracing::warn;

#[derive(Deserialize)]
pub struct PushRequest {
    pub(crate) sender: String,
    pub(crate) recver: String,
    pub(crate) seq: u64,
    pub(crate) payload: String, // base64
    pub(crate) sig: String,     // base64, 64 bytes — подпись от sender+recver+seq+payload(base64)
}

#[derive(Serialize)]
pub struct ApiResponse {
    pub(crate) success: bool,
    pub(crate) message: String,
}

pub async fn handle(State(state): State<Arc<AppState>>, Json(body): Json<Value>) -> Json<Value> {
    // Cover → Core
    let req = match state.cover.unwrap_push(&body) {
        Ok(r) => r,
        Err(e) => {
            return Json(json!({
                "ok": false,
                "status": "error",
                "message": format!("Bad cover: {e}"),
            }));
        }
    };

    // state по ссылке, не перемещаем
    let core_resp = do_push(&state, req).await;
    let wrapped = state.cover.wrap_push_response(&core_resp);
    Json(wrapped)
}

async fn do_push(state: &Arc<AppState>, req: PushRequest) -> ApiResponse {
    let sig = match crypto::decode_b64(&req.sig) {
        Ok(v) => v,
        Err(_) => {
            return fail("Bad sig encoding".into());
        }
    };
    let payload_bytes = match crypto::decode_b64(&req.payload) {
        Ok(v) => v,
        Err(_) => {
            return fail("Bad payload encoding".into());
        }
    };

    // Проверяем регистрацию sender и recver
    let sender_pubkey = {
        let cfg = state.config.read().await;
        if !cfg.users.contains_key(&req.recver) {
            return fail("One user in pair not registered".into());
        }
        match cfg.user_pubkey_bytes(&req.sender) {
            Some(k) => k,
            None => {
                return fail("One user in pair not registered".into());
            }
        }
    };

    // Подписываемое сообщение: sender + recver + seq(decimal string) + payload(base64 string)
    let signed_msg = format!("{}{}{}{}", req.sender, req.recver, req.seq, req.payload);
    if let Err(e) = crypto::verify_signature(&sender_pubkey, signed_msg.as_bytes(), &sig) {
        warn!("Invalid push signature from '{}': {e}", req.sender);
        return fail("Invalid signature".into());
    }

    let dialogue_id = crypto::make_dialogue_id(&req.sender, &req.recver);
    match state.store.push(&dialogue_id, req.seq, &payload_bytes) {
        Ok(_) => {
            // Поднять собственный last_seq отправителя до отправленного seq. Pull-
            // before-push (MultiDevicePolicy) гарантирует, что отправитель уже
            // подтянул всё до этого seq, поэтому отметка корректна и для статуса
            // прочтения у партнёра. Делаем это ДО пробуждения ожидающих /notify,
            // чтобы другие устройства того же аккаунта не посчитали своё сообщение
            // новым (детерминированно закрывает гонку push→pull). Уважает opt-out
            // receipts: при выключенных уведомлениях о прочтении last_seq заморожен
            // (update_last_seq — no-op), и дедуп своих уведомлений для этого диалога
            // не действует — приемлемый редкий край.
            if let Err(e) = state
                .store
                .update_last_seq(&req.sender, &dialogue_id, req.seq)
            {
                warn!("push: failed to bump sender last_seq: {e}");
            }
            // Разбудить long-poll `/notify`, ждущих этот диалог (если такие есть).
            // По dialogue_id будятся обе стороны — каждая пересчитает свои новые.
            state.dialogue_notify.notify(&dialogue_id).await;
            ok("OK".into())
        }
        Err(e) => fail(format!("{e}")),
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
