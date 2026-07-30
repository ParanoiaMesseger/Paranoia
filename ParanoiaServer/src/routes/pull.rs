use crate::{AppState, crypto};
use axum::{Json, extract::State};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::sync::Arc;
use tracing::warn;

#[derive(Deserialize)]
pub struct PullRequest {
    pub sender: String,
    pub recver: String,
    pub after_seq: u64,
    pub to_seq: u64, // строго > after_seq
    pub sig: String, // подпись от sender+recver+after_seq+to_seq
}

#[derive(Serialize)]
pub struct ApiResponse {
    pub success: bool,
    /// Пакеты `(seq, base64-payload)` при `success`; на ошибке пусто. Типизировано
    /// (не `Value`), чтобы cover-слой оборачивал готовые поля без повторного парса и
    /// без второй копии всех payload'ов (02#2).
    pub packets: Vec<(u64, String)>,
    /// Текст ошибки при `!success`; пусто при `success`.
    pub message: String,
}

pub async fn handle(State(state): State<Arc<AppState>>, Json(body): Json<Value>) -> Json<Value> {
    // Cover → Core
    let req = match state.cover.unwrap_pull(&body) {
        Ok(r) => r,
        Err(e) => {
            warn!("Bad cover in pull: {e}");
            return Json(json!({
                "ok": false,
                "status": "error",
                "message": format!("Bad cover: {e}"),
            }));
        }
    };

    let core_resp = do_pull(&state, req).await;
    let wrapped = state.cover.wrap_pull_response(core_resp);
    Json(wrapped)
}

async fn do_pull(state: &Arc<AppState>, req: PullRequest) -> ApiResponse {
    let sig = match crypto::decode_b64(&req.sig) {
        Ok(v) => v,
        Err(_) => {
            return fail("Bad sig encoding".into());
        }
    };

    if req.to_seq == 0 || req.to_seq <= req.after_seq {
        return fail("Invalid pull range".into());
    }

    // Подписать может любой из участников диалога — проверяем обоих
    let (sender_pub, recver_pub) = {
        let cfg = state.config.read().await;
        let s = cfg.user_pubkey_bytes(&req.sender);
        let r = cfg.user_pubkey_bytes(&req.recver);
        match (s, r) {
            (Some(s), Some(r)) => (s, r),
            _ => {
                return fail("One user in pair not registered".into());
            }
        }
    };

    let signed_msg = format!(
        "{}{}{}{}",
        req.sender, req.recver, req.after_seq, req.to_seq
    );
    let signer = if crypto::verify_signature(&sender_pub, signed_msg.as_bytes(), &sig).is_ok() {
        req.sender.clone()
    } else if crypto::verify_signature(&recver_pub, signed_msg.as_bytes(), &sig).is_ok() {
        req.recver.clone()
    } else {
        warn!(
            "Invalid pull signature for dialogue {}<->{}",
            req.sender, req.recver
        );
        return fail("Invalid signature".into());
    };

    let dialogue_id = crypto::make_dialogue_id(&req.sender, &req.recver);
    // Чтение диапазона пакетов + подъём last_seq + base64-кодирование payload'ов —
    // всё блокирующее либо CPU-тяжёлое (диапазон бывает большим). Уводим целиком на
    // spawn_blocking, чтобы горячий роут /pull не вставал на tokio-воркере (01#3).
    let pull_result = {
        let state = Arc::clone(state);
        let did = dialogue_id.clone();
        let (after_seq, to_seq) = (req.after_seq, req.to_seq);
        tokio::task::spawn_blocking(move || -> Result<Vec<(u64, String)>, anyhow::Error> {
            let packets = state.store.pull(&did, after_seq, to_seq)?;
            if let Some(pulled_seq) = packets.iter().map(|(seq, _)| *seq).max() {
                state.store.update_last_seq(&signer, &did, pulled_seq)?;
            }
            Ok(packets
                .into_iter()
                .map(|(seq, data)| (seq, crypto::encode_b64(&data)))
                .collect())
        })
        .await
    };
    match pull_result {
        Ok(Ok(packets)) => ApiResponse {
            success: true,
            packets,
            message: String::new(),
        },
        Ok(Err(e)) => fail(format!("{e}")),
        Err(e) => fail(format!("join error: {e}")),
    }
}

fn fail(msg: String) -> ApiResponse {
    ApiResponse {
        success: false,
        packets: Vec::new(),
        message: msg,
    }
}
