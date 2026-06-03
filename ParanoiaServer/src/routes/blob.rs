//! Эндпоинт эфемерных больших файлов (вне истории диалога).
//!
//! Мультиплексирует три операции под одним путём (как и просил дизайн):
//!   * `info` — отдать границы из конфига сервера (клиент узнаёт лимиты);
//!   * `put`  — загрузить один чанк большого файла в эфемерное хранилище (TTL);
//!   * `get`  — скачать один чанк.
//!
//! Аутентификация — подписью Ed25519 **ключа пользователя** (`user`) над
//! канонической строкой запроса (включает `nonce` против повтора). Сервер видит
//! только шифр-блобы (E2E), про содержимое ничего не знает. Эндпоинт может идти
//! как плоско (`/blob`), так и под маскировкой (вид `blob` профиля, см.
//! [`crate::routes::cover_gateway::blob_gateway`]).

use crate::{AppState, crypto};
use axum::{Json, extract::State};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::{HashSet, VecDeque};
use std::sync::Arc;
use tracing::warn;

#[derive(Deserialize)]
pub struct BlobRequest {
    pub op: String,   // "info" | "put" | "get"
    pub user: String, // отправитель/получатель — чьим ключом подписано
    pub nonce: String,
    pub sig: String, // base64 Ed25519 над канонической строкой
    #[serde(default)]
    pub peer: String, // второй участник пары (для dialogue_id)
    #[serde(default)]
    pub file_id: String,
    #[serde(default)]
    pub chunk_index: u32,
    #[serde(default)]
    pub total_chunks: u32,
    #[serde(default)]
    pub total_size: u64,
    #[serde(default)]
    pub payload: String, // base64-чанк (для put)
}

/// Anti-replay: ограниченный LRU уже виденных nonce'ов.
pub struct NonceGuard {
    seen: HashSet<String>,
    order: VecDeque<String>,
    cap: usize,
}

impl NonceGuard {
    pub fn new(cap: usize) -> Self {
        Self {
            seen: HashSet::new(),
            order: VecDeque::new(),
            cap,
        }
    }

    /// `true`, если nonce ранее не встречался (запрос свежий); регистрирует его.
    pub fn insert_fresh(&mut self, nonce: &str) -> bool {
        if nonce.is_empty() || self.seen.contains(nonce) {
            return false;
        }
        while self.order.len() >= self.cap {
            if let Some(old) = self.order.pop_front() {
                self.seen.remove(&old);
            } else {
                break;
            }
        }
        self.seen.insert(nonce.to_string());
        self.order.push_back(nonce.to_string());
        true
    }
}

pub async fn handle(State(state): State<Arc<AppState>>, Json(req): Json<BlobRequest>) -> Json<Value> {
    Json(do_blob(&state, req).await)
}

fn err(msg: &str) -> Value {
    json!({ "success": false, "message": msg })
}

/// Каноническая строка для подписи — биндит все security-значимые поля операции.
fn canonical(req: &BlobRequest) -> Option<String> {
    Some(match req.op.as_str() {
        "info" => format!("blob.info|{}|{}", req.user, req.nonce),
        "put" => format!(
            "blob.put|{}|{}|{}|{}|{}|{}|{}|{}",
            req.user,
            req.peer,
            req.file_id,
            req.chunk_index,
            req.total_chunks,
            req.total_size,
            req.nonce,
            req.payload
        ),
        "get" => format!(
            "blob.get|{}|{}|{}|{}|{}",
            req.user, req.peer, req.file_id, req.chunk_index, req.nonce
        ),
        _ => return None,
    })
}

pub async fn do_blob(state: &Arc<AppState>, req: BlobRequest) -> Value {
    // 1. Пользователь зарегистрирован?
    let pubkey = {
        let cfg = state.config.read().await;
        match cfg.user_pubkey_bytes(&req.user) {
            Some(k) => k,
            None => return err("user not registered"),
        }
    };
    // 2. Подпись над канонической строкой операции.
    let Some(canon) = canonical(&req) else {
        return err("unknown op");
    };
    let sig = match crypto::decode_b64(&req.sig) {
        Ok(v) => v,
        Err(_) => return err("bad sig encoding"),
    };
    if crypto::verify_signature(&pubkey, canon.as_bytes(), &sig).is_err() {
        warn!("blob: invalid signature from '{}'", req.user);
        return err("invalid signature");
    }
    // 3. Anti-replay по nonce.
    if !state.blob_nonces.lock().await.insert_fresh(&req.nonce) {
        return err("replay");
    }

    match req.op.as_str() {
        "info" => {
            let cfg = state.config.read().await;
            json!({
                "success": true,
                "max_history_file_size": cfg.max_history_file_size,
                "large_file_max": cfg.large_file_max,
                "ephemeral_retention_secs": cfg.ephemeral_retention_secs,
            })
        }
        "put" => {
            let (large_max, retention) = {
                let c = state.config.read().await;
                (c.large_file_max, c.ephemeral_retention_secs)
            };
            if req.total_size > large_max {
                return err("file too large");
            }
            if req.file_id.is_empty() || req.peer.is_empty() {
                return err("bad request");
            }
            let data = match crypto::decode_b64(&req.payload) {
                Ok(v) => v,
                Err(_) => return err("bad payload encoding"),
            };
            let dialogue_id = crypto::make_dialogue_id(&req.user, &req.peer);
            match state.store.ephemeral_put_chunk(
                &dialogue_id,
                &req.file_id,
                req.chunk_index,
                req.total_chunks,
                req.total_size,
                &data,
                retention,
            ) {
                Ok(_) => json!({ "success": true }),
                Err(e) => err(&format!("store error: {e}")),
            }
        }
        "get" => {
            if req.file_id.is_empty() || req.peer.is_empty() {
                return err("bad request");
            }
            let dialogue_id = crypto::make_dialogue_id(&req.user, &req.peer);
            match state
                .store
                .ephemeral_get_chunk(&dialogue_id, &req.file_id, req.chunk_index)
            {
                Ok(Some(data)) => json!({
                    "success": true,
                    "payload": crypto::encode_b64(&data),
                }),
                // Просрочен/нет файла — отдельный флаг, чтобы клиент показал
                // «срок хранения истёк», а не «сетевая ошибка».
                Ok(None) => json!({ "success": false, "expired": true, "message": "expired or not found" }),
                Err(e) => err(&format!("store error: {e}")),
            }
        }
        _ => err("unknown op"),
    }
}
