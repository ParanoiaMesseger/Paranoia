use crate::{AppState, crypto};
use axum::{Json, extract::State};
use futures_util::future::select_all;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tracing::warn;

/// Один диалог в multi-режиме: партнёр + курсор `seq`.
#[derive(Deserialize, Clone)]
pub struct NotifyItem {
    pub partner: String,
    #[serde(default)]
    pub seq: u64,
}

#[derive(Deserialize)]
pub struct NotifyRequest {
    pub sender: String,
    /// Одиночный режим: один партнёр. В multi-режиме пусто (см. `items`).
    #[serde(default)]
    pub partner: String,
    #[serde(default)]
    pub seq: u64,
    pub sig: String, // подпись: одиночный — sender+partner+seq; multi — sender+(partner+seq)*
    /// Желаемое удержание long-poll (мс). `0`/отсутствует — мгновенный ответ.
    /// НЕ входит в подпись: величина капается сервером и прав не несёт.
    #[serde(default)]
    pub long_poll_ms: u32,
    /// Multi-notify: список диалогов в одном запросе. Пусто → одиночный режим.
    #[serde(default)]
    pub items: Vec<NotifyItem>,
}

/// Зажжённый диалог в multi-ответе.
#[derive(Serialize, Clone)]
pub struct NotifyRespItem {
    pub partner: String,
    pub n: u64,
}

#[derive(Serialize)]
pub struct ApiResponse {
    pub success: bool,
    pub n: u64,
    pub message: String,
    /// Multi-режим: диалоги с новыми сообщениями (`n>0`). Пусто в одиночном.
    pub items: Vec<NotifyRespItem>,
}

/// Потолок числа диалогов в одном multi-/notify — гард от раздувания запроса.
/// Клиент чанкует, если диалогов больше (редкость).
const MAX_NOTIFY_ITEMS: usize = 512;

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

    // Shape-detect: непустой items → multi, иначе старая одиночная логика.
    let core_resp = if req.items.is_empty() {
        do_notify(&state, req).await
    } else {
        do_notify_multi(&state, req).await
    };
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

    // Считаем «новые» относительно собственного last_seq отправителя (см. подробный
    // комментарий ниже в multi-ветке — логика идентична).

    // Быстрая ветка: уже есть новые — отдать сразу.
    match state.store.count_new_for_user(&dialogue_id, req.seq, &req.sender) {
        Ok(n) if n > 0 => return ok(n),
        Ok(_) => {}
        Err(e) => return fail(format!("{e}")),
    }

    let wait_ms = req.long_poll_ms.min(long_poll_cap);
    if wait_ms == 0 {
        return ok(0);
    }

    // Берём waker ДО повторной проверки count — иначе можно пропустить notify,
    // случившийся между count и подпиской (тот же паттерн, что в call/poll).
    let waker = state.dialogue_notify.waker(&dialogue_id).await;
    let notified = waker.notified();
    tokio::pin!(notified);
    match state.store.count_new_for_user(&dialogue_id, req.seq, &req.sender) {
        Ok(n) if n > 0 => return ok(n),
        Ok(_) => {}
        Err(e) => return fail(format!("{e}")),
    }

    let _ = tokio::time::timeout(Duration::from_millis(wait_ms as u64), notified.as_mut()).await;
    match state.store.count_new_for_user(&dialogue_id, req.seq, &req.sender) {
        Ok(n) => ok(n),
        Err(e) => fail(format!("{e}")),
    }
}

/// Multi-notify: один запрос следит за N диалогами, long-poll просыпается на ПЕРВОМ
/// зажёгшемся. Сервер слеп (видит только хеши `dialogue_id` + счётчики). Подпись
/// одна (sender над всем списком), `make_dialogue_id(sender, partner)` всегда
/// включает sender → запросить можно лишь СВОИ диалоги. Незарегистрированных
/// партнёров пропускаем (устаревший справочник не должен валить весь батч).
async fn do_notify_multi(state: &Arc<AppState>, req: NotifyRequest) -> ApiResponse {
    if req.items.len() > MAX_NOTIFY_ITEMS {
        return fail(format!("too many items (>{MAX_NOTIFY_ITEMS})"));
    }
    let sig = match crypto::decode_b64(&req.sig) {
        Ok(v) => v,
        Err(_) => return fail("Bad sig encoding".into()),
    };

    let (sender_pubkey, long_poll_cap) = {
        let cfg = state.config.read().await;
        let pk = match cfg.user_pubkey_bytes(&req.sender) {
            Some(k) => k,
            None => return fail("sender not registered".into()),
        };
        (pk, cfg.notify_long_poll_max_ms)
    };

    // Подпись над канон. сериализацией: sender ‖ (partner ‖ seq) по порядку как пришли.
    let mut signed_msg = req.sender.clone();
    for it in &req.items {
        signed_msg.push_str(&it.partner);
        signed_msg.push_str(&it.seq.to_string());
    }
    if let Err(e) = crypto::verify_signature(&sender_pubkey, signed_msg.as_bytes(), &sig) {
        warn!("Invalid multi-notify signature from '{}': {e}", req.sender);
        return fail("Invalid signature".into());
    }

    // Резолвим (partner, dialogue_id, seq), пропуская незарегистрированных партнёров.
    let pairs: Vec<(String, String, u64)> = {
        let cfg = state.config.read().await;
        req.items
            .iter()
            .filter(|it| cfg.users.contains_key(&it.partner))
            .map(|it| {
                (
                    it.partner.clone(),
                    crypto::make_dialogue_id(&req.sender, &it.partner),
                    it.seq,
                )
            })
            .collect()
    };
    if pairs.is_empty() {
        return ok_multi(Vec::new());
    }

    // Быстрая ветка: какие диалоги уже с новыми.
    match scan_pairs(state, &pairs, &req.sender) {
        Ok(lit) if !lit.is_empty() => return ok_multi(lit),
        Ok(_) => {}
        Err(e) => return fail(e),
    }

    let wait_ms = req.long_poll_ms.min(long_poll_cap);
    if wait_ms == 0 {
        return ok_multi(Vec::new());
    }

    // Подписка на ВСЕ wakers ДО повторного скана (анти-гонка, как в одиночной ветке):
    // push поднимает last_seq отправителя ДО пробуждения, поэтому пере-скан после
    // подписки ловит сообщение, проскочившее между первым сканом и подпиской.
    let wakers: Vec<Arc<tokio::sync::Notify>> = {
        let mut v = Vec::with_capacity(pairs.len());
        for (_, did, _) in &pairs {
            v.push(state.dialogue_notify.waker(did).await);
        }
        v
    };
    let futs: Vec<_> = wakers.iter().map(|w| Box::pin(w.notified())).collect();
    match scan_pairs(state, &pairs, &req.sender) {
        Ok(lit) if !lit.is_empty() => return ok_multi(lit),
        Ok(_) => {}
        Err(e) => return fail(e),
    }

    // Просыпаемся на ПЕРВОМ зажёгшемся диалоге или по таймауту, затем пере-скан всех.
    let _ = tokio::time::timeout(Duration::from_millis(wait_ms as u64), select_all(futs)).await;
    match scan_pairs(state, &pairs, &req.sender) {
        Ok(lit) => ok_multi(lit),
        Err(e) => fail(e),
    }
}

/// Посчитать новые по каждому диалогу; вернуть только зажжённые (`n>0`).
fn scan_pairs(
    state: &Arc<AppState>,
    pairs: &[(String, String, u64)],
    sender: &str,
) -> Result<Vec<NotifyRespItem>, String> {
    let mut lit = Vec::new();
    for (partner, dialogue_id, seq) in pairs {
        match state.store.count_new_for_user(dialogue_id, *seq, sender) {
            Ok(n) if n > 0 => lit.push(NotifyRespItem {
                partner: partner.clone(),
                n,
            }),
            Ok(_) => {}
            Err(e) => return Err(format!("{e}")),
        }
    }
    Ok(lit)
}

fn ok(n: u64) -> ApiResponse {
    ApiResponse {
        success: true,
        n,
        message: String::new(),
        items: Vec::new(),
    }
}

fn ok_multi(items: Vec<NotifyRespItem>) -> ApiResponse {
    ApiResponse {
        success: true,
        n: 0,
        message: String::new(),
        items,
    }
}

fn fail(msg: String) -> ApiResponse {
    ApiResponse {
        success: false,
        n: 0,
        message: msg,
        items: Vec::new(),
    }
}
