//! Cover-шлюз для admin/reg-трафика.
//!
//! Когда активен masking-профиль с видами `admin`/`reg`, клиенты шлют admin- и
//! reg-запросы замаскированными на профильные пути. Шлюз разворачивает тело
//! (брутфорс по схемам, AEAD-тег), парсит исходный envelope и **переиспользует
//! существующие хендлеры** (auth-логика не дублируется и не трогается), затем
//! запечатывает ответ. Цель — чтобы редкий, но характерный admin/reg-паттерн не
//! выдавал инфраструктуру при расшифровке TLS.

use crate::AppState;
use axum::{Json, extract::State};
use serde_json::{Value, json};
use std::sync::Arc;

use super::admin::{self, AdminEnvelope};
use super::blob::{self, BlobRequest};
use super::reg::{self, RegRequest};

fn cover_fail(msg: &str) -> Json<Value> {
    Json(json!({ "success": false, "message": msg }))
}

/// Запечатать ответ-Value в схему вида `kind`. При ошибке — пустой объект
/// (клиент тогда явно не развернёт — громкий отказ, не тихая подмена).
fn seal_resp(state: &Arc<AppState>, kind: &str, resp: &Value) -> Json<Value> {
    let Some(profile) = state.masking_profile.as_ref() else {
        return Json(json!({}));
    };
    match serde_json::to_vec(resp)
        .ok()
        .and_then(|bytes| paranoia_cover::wrap_auto(profile, kind, &bytes).ok())
    {
        Some(v) => Json(v),
        None => Json(json!({})),
    }
}

/// `POST <profile.admin.path>` — замаскированный admin-конверт. Разворачивает,
/// диспетчеризует по `op` в существующие admin-хендлеры, запечатывает ответ.
pub async fn admin_gateway(
    State(state): State<Arc<AppState>>,
    Json(body): Json<Value>,
) -> Json<Value> {
    let Some(profile) = state.masking_profile.clone() else {
        return cover_fail("masking profile not active");
    };
    let inner = match paranoia_cover::unwrap(&profile, "admin", &body) {
        Ok(b) => b,
        Err(_) => return cover_fail("bad cover"),
    };
    let env: AdminEnvelope = match serde_json::from_slice(&inner) {
        Ok(e) => e,
        Err(_) => return cover_fail("bad admin envelope"),
    };

    // Диспетчеризация в существующие хендлеры (та же auth/capability-логика).
    let resp = match env.op.as_str() {
        "list_users" => admin::users::list(State(Arc::clone(&state)), Json(env)).await,
        "delete_user" => admin::users::delete(State(Arc::clone(&state)), Json(env)).await,
        "list_dialogues" => admin::dialogues::list(State(Arc::clone(&state)), Json(env)).await,
        "prune" => admin::dialogues::prune(State(Arc::clone(&state)), Json(env)).await,
        "get_config" => admin::server_config::get(State(Arc::clone(&state)), Json(env)).await,
        "set_config" => admin::server_config::set(State(Arc::clone(&state)), Json(env)).await,
        _ => cover_fail("unknown_op"),
    };
    seal_resp(&state, "admin_resp", &resp.0)
}

/// `POST <profile.reg.path>` — замаскированная регистрация. Разворачивает →
/// `RegRequest` → существующий reg-хендлер → запечатывает ответ.
pub async fn reg_gateway(
    State(state): State<Arc<AppState>>,
    Json(body): Json<Value>,
) -> Json<Value> {
    let Some(profile) = state.masking_profile.clone() else {
        return cover_fail("masking profile not active");
    };
    let inner = match paranoia_cover::unwrap(&profile, "reg", &body) {
        Ok(b) => b,
        Err(_) => return cover_fail("bad cover"),
    };
    let req: RegRequest = match serde_json::from_slice(&inner) {
        Ok(r) => r,
        Err(_) => return cover_fail("bad reg request"),
    };
    let resp = reg::handle(State(Arc::clone(&state)), Json(req)).await;
    let value = serde_json::to_value(&resp.0).unwrap_or_else(|_| json!({}));
    seal_resp(&state, "reg_resp", &value)
}

/// `POST <profile.blob.path>` — замаскированный blob-запрос (эфемерные большие
/// файлы). Разворачивает → `BlobRequest` → существующий blob-хендлер →
/// запечатывает ответ видом `blob_resp`.
pub async fn blob_gateway(
    State(state): State<Arc<AppState>>,
    Json(body): Json<Value>,
) -> Json<Value> {
    let Some(profile) = state.masking_profile.clone() else {
        return cover_fail("masking profile not active");
    };
    let inner = match paranoia_cover::unwrap(&profile, "blob", &body) {
        Ok(b) => b,
        Err(_) => return cover_fail("bad cover"),
    };
    let req: BlobRequest = match serde_json::from_slice(&inner) {
        Ok(r) => r,
        Err(_) => return cover_fail("bad blob request"),
    };
    let resp = blob::do_blob(&state, req).await;
    seal_resp(&state, "blob_resp", &resp)
}
