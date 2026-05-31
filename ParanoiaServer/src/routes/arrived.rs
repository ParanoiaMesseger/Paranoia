use crate::{AppState, crypto};
use axum::{
    Json,
    extract::{Query, State},
    http::{HeaderMap, header},
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};
use tracing::warn;

#[derive(Deserialize)]
pub struct ArrivedGetQuery {
    pub dialogue_id: String,
    pub partner: String,
}

#[derive(Deserialize)]
pub struct ArrivedSetRequest {
    pub dialogue_id: String,
    pub receipts_enabled: bool,
    pub sig: String,
}

struct ArrivedAuth {
    username: String,
    sig: String,
}

pub async fn handle_get(
    State(state): State<Arc<AppState>>,
    Query(query): Query<ArrivedGetQuery>,
    headers: HeaderMap,
) -> Json<Value> {
    let auth = match parse_authorization(&headers) {
        Ok(auth) => auth,
        Err(e) => return Json(fail(e)),
    };

    if query.dialogue_id.is_empty() || query.partner.is_empty() {
        return Json(fail("Invalid arrived request".into()));
    }

    let expected_dialogue_id = crypto::make_dialogue_id(&auth.username, &query.partner);
    if expected_dialogue_id != query.dialogue_id {
        return Json(fail("Invalid dialogue_id".into()));
    }

    let signed_msg = arrived_get_signed_msg(&auth.username, &query.partner, &query.dialogue_id);
    if let Err(e) = verify_user_signature(
        &state,
        &auth.username,
        &query.partner,
        &signed_msg,
        &auth.sig,
    )
    .await
    {
        warn!(
            "Invalid arrived GET signature from '{}': {e}",
            auth.username
        );
        return Json(fail(e));
    }

    match state
        .store
        .receipt_state(&query.partner, &query.dialogue_id)
    {
        Ok(receipt) => Json(json!({
            "partner_last_seq": if receipt.receipts_enabled { json!(receipt.last_seq) } else { Value::Null },
            "ts": if receipt.updated_at == 0 { now_unix_ts() } else { receipt.updated_at },
        })),
        Err(e) => Json(fail(format!("{e}"))),
    }
}

pub async fn handle_put(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(body): Json<ArrivedSetRequest>,
) -> Json<Value> {
    let auth = match parse_authorization(&headers) {
        Ok(auth) => auth,
        Err(e) => return Json(fail(e)),
    };

    if body.dialogue_id.is_empty() {
        return Json(fail("Invalid arrived request".into()));
    }
    if auth.sig != body.sig {
        return Json(fail("Signature mismatch".into()));
    }

    let signed_msg =
        arrived_put_signed_msg(&auth.username, &body.dialogue_id, body.receipts_enabled);
    if let Err(e) = verify_user_signature(
        &state,
        &auth.username,
        &auth.username,
        &signed_msg,
        &auth.sig,
    )
    .await
    {
        warn!(
            "Invalid arrived PUT signature from '{}': {e}",
            auth.username
        );
        return Json(fail(e));
    }

    match state
        .store
        .set_receipts_enabled(&auth.username, &body.dialogue_id, body.receipts_enabled)
    {
        Ok(()) => Json(json!({})),
        Err(e) => Json(fail(format!("{e}"))),
    }
}

fn parse_authorization(headers: &HeaderMap) -> Result<ArrivedAuth, String> {
    let raw = headers
        .get(header::AUTHORIZATION)
        .ok_or_else(|| "Missing authorization".to_string())?
        .to_str()
        .map_err(|_| "Invalid authorization".to_string())?;
    // Снимаем любую схему-префикс (например "Bearer "), не привязываясь к
    // конкретному слову — клиент маскирует её под обычный bearer-токен и может
    // менять схему через профиль маскировки.
    let token_b64 = raw.rsplit(' ').next().unwrap_or(raw).trim();
    // Токен — это base64("username:sig_b64"); разворачиваем обратно.
    let decoded = crypto::decode_b64(token_b64).map_err(|_| "Invalid authorization".to_string())?;
    let token = String::from_utf8(decoded).map_err(|_| "Invalid authorization".to_string())?;
    let (username, sig) = token
        .split_once(':')
        .ok_or_else(|| "Invalid authorization".to_string())?;
    if username.is_empty() || sig.is_empty() {
        return Err("Invalid authorization".into());
    }
    Ok(ArrivedAuth {
        username: username.to_string(),
        sig: sig.to_string(),
    })
}

async fn verify_user_signature(
    state: &Arc<AppState>,
    username: &str,
    partner: &str,
    signed_msg: &str,
    sig_b64: &str,
) -> Result<(), String> {
    let sig = crypto::decode_b64(sig_b64).map_err(|_| "Bad sig encoding".to_string())?;
    let user_pubkey = {
        let cfg = state.config.read().await;
        if !cfg.users.contains_key(partner) {
            return Err("One user in pair not registered".into());
        }
        cfg.user_pubkey_bytes(username)
            .ok_or_else(|| "One user in pair not registered".to_string())?
    };
    crypto::verify_signature(&user_pubkey, signed_msg.as_bytes(), &sig)
        .map_err(|_| "Invalid signature".to_string())
}

fn arrived_get_signed_msg(sender: &str, partner: &str, dialogue_id: &str) -> String {
    format!("arrived:get:{sender}:{partner}:{dialogue_id}")
}

fn arrived_put_signed_msg(sender: &str, dialogue_id: &str, receipts_enabled: bool) -> String {
    format!("arrived:put:{sender}:{dialogue_id}:{receipts_enabled}")
}

fn now_unix_ts() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0)
}

fn fail(msg: String) -> Value {
    json!({
        "success": false,
        "message": msg,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::HeaderValue;

    #[test]
    fn parse_authorization_unwraps_masked_bearer_token() {
        let token = crypto::encode_b64(b"alice:c2ln");
        let mut headers = HeaderMap::new();
        headers.insert(
            header::AUTHORIZATION,
            HeaderValue::from_str(&format!("Bearer {token}")).unwrap(),
        );
        let auth = parse_authorization(&headers).expect("valid token");
        assert_eq!(auth.username, "alice");
        assert_eq!(auth.sig, "c2ln");
    }

    #[test]
    fn parse_authorization_accepts_token_without_scheme() {
        let token = crypto::encode_b64(b"bob:c2ln");
        let mut headers = HeaderMap::new();
        headers.insert(
            header::AUTHORIZATION,
            HeaderValue::from_str(&token).unwrap(),
        );
        let auth = parse_authorization(&headers).expect("valid token");
        assert_eq!(auth.username, "bob");
    }

    #[test]
    fn parse_authorization_rejects_garbage() {
        let mut headers = HeaderMap::new();
        headers.insert(
            header::AUTHORIZATION,
            HeaderValue::from_static("Bearer not_base64!!!"),
        );
        assert!(parse_authorization(&headers).is_err());
    }
}
