use std::sync::Arc;
use axum::{extract::State, Json};
use serde::{Deserialize, Serialize};
use tracing::{info, warn};
use crate::{AppState, crypto};

#[derive(Deserialize)]
pub struct RegRequest {
    username:  String,
    pub_key:   String, // base64, 32 bytes
    admin_sig: String, // base64, 64 bytes
}

#[derive(Serialize)]
pub struct ApiResponse {
    success: bool,
    message: String,
}

pub async fn handle(
    State(state): State<Arc<AppState>>,
    Json(req): Json<RegRequest>,
) -> Json<ApiResponse> {
    let result = do_reg(state, req).await;
    Json(result)
}

async fn do_reg(state: Arc<AppState>, req: RegRequest) -> ApiResponse {
    let m = &state.metrics;

    // Decode fields
    let admin_sig = match crypto::decode_b64(&req.admin_sig) {
        Ok(v) => v,
        Err(e) => {
            m.inc_reg_fail();
            return fail(format!("Bad admin_sig: {e}"));
        }
    };
    let user_pub = match crypto::decode_b64(&req.pub_key) {
        Ok(v) => v,
        Err(e) => {
            m.inc_reg_fail();
            return fail(format!("Bad pub_key: {e}"));
        }
    };
    if user_pub.len() != 32 {
        m.inc_reg_fail();
        return fail("pub_key must be 32 bytes".into());
    }

    // Verify admin signature over username+pub_key (base64 string)
    let admin_pubkey = {
        let cfg = state.config.read().await;
        match cfg.admin_pubkey_bytes() {
            Ok(k) => k,
            Err(e) => {
                m.inc_reg_fail();
                return fail(format!("Server config error: {e}"));
            }
        }
    };
    let signed_msg = format!("{}{}", req.username, req.pub_key);
    if let Err(e) = crypto::verify_signature(&admin_pubkey, signed_msg.as_bytes(), &admin_sig) {
        m.inc_reg_fail();
        warn!("Rejected registration for '{}': {e}", req.username);
        return fail("Invalid admin signature".into());
    }

    // Register user
    let mut cfg = state.config.write().await;
    if cfg.users.contains_key(&req.username) {
        m.inc_reg_fail();
        return fail("User already exists".into());
    }
    cfg.users.insert(req.username.clone(), req.pub_key);
    drop(cfg);

    // Persist
    let cfg = state.config.read().await;
    if let Err(e) = cfg.save("./configs/Paranoia.json") {
        warn!("Failed to save config: {e}");
    }

    m.inc_reg_success();
    info!("User '{}' registered", req.username);
    ok("OK".into())
}

fn ok(msg: String)   -> ApiResponse { ApiResponse { success: true,  message: msg } }
fn fail(msg: String) -> ApiResponse { ApiResponse { success: false, message: msg } }
