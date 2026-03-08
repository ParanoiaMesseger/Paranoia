// src/ffi.rs
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::Arc;
use base64::Engine;
use tokio::runtime::Runtime;

use crate::{
    ParanoiaClient, ClientConfig,
    types::{DialogueKey, DialogueConfig},
};

// Непрозрачный хэндл для C++
pub struct ParanoiaHandle {
    client: ParanoiaClient,
    rt: Runtime,
}

/// Создать клиента. Возвращает NULL при ошибке.
/// server_url, username, db_path — null-terminated UTF-8 строки.
/// signing_key_b64 — base64 Ed25519 private key (32 bytes).
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_client_new(
    server_url: *const c_char,
    username: *const c_char,
    signing_key_b64: *const c_char,
    db_path: *const c_char,
) -> *mut ParanoiaHandle {
    let server_url = unsafe { CStr::from_ptr(server_url) }.to_str().unwrap_or("").to_string();
    let username   = unsafe { CStr::from_ptr(username)   }.to_str().unwrap_or("").to_string();
    let sk_b64     = unsafe { CStr::from_ptr(signing_key_b64) }.to_str().unwrap_or("");
    let db_path    = unsafe { CStr::from_ptr(db_path)    }.to_str().unwrap_or("").to_string();

    let sk_bytes = match base64::engine::general_purpose::STANDARD.decode(sk_b64) {
        Ok(b) if b.len() == 32 => b,
        _ => return std::ptr::null_mut(),
    };
    let sk_arr: [u8; 32] = sk_bytes.try_into().unwrap();
    let signing_key = ed25519_dalek::SigningKey::from_bytes(&sk_arr);

    let cfg = ClientConfig { server_url, username, signing_key, db_path };
    let rt = Runtime::new().unwrap();

    match ParanoiaClient::new(cfg) {
        Ok(client) => Box::into_raw(Box::new(ParanoiaHandle { client, rt })),
        Err(_)     => std::ptr::null_mut(),
    }
}

/// Освободить память хэндла.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_client_free(handle: *mut ParanoiaHandle) {
    if !handle.is_null() {
        unsafe { drop(Box::from_raw(handle)); }
    }
}

/// Отправить текстовое сообщение.
/// Возвращает 0 при успехе, -1 при ошибке.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_send_text(
    handle: *mut ParanoiaHandle,
    user_a: *const c_char,
    user_b: *const c_char,
    session_key: *const u8,   // 32 байта
    text: *const c_char,
) -> i32 {
    let h = unsafe { &*handle };
    let a    = unsafe { CStr::from_ptr(user_a) }.to_str().unwrap_or("").to_string();
    let b    = unsafe { CStr::from_ptr(user_b) }.to_str().unwrap_or("").to_string();
    let text = unsafe { CStr::from_ptr(text)   }.to_str().unwrap_or("").to_string();
    let key: [u8; 32] = unsafe { std::slice::from_raw_parts(session_key, 32) }
        .try_into().unwrap();

    let cfg = DialogueConfig { key: DialogueKey::new(&a, &b), session_key: key };
    let dialogue = h.client.open_dialogue(cfg);

    match h.rt.block_on(dialogue.send_text(text)) {
        Ok(_)  => 0,
        Err(_) => -1,
    }
}

use crate::AdminKeyPair;

/// Генерировать новую пару ключей администратора.
/// Возвращает приватный ключ в base64 через out_secret (caller должен освободить через paranoia_free_string).
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_generate_keypair(
    out_secret: *mut *mut c_char,
    out_pubkey: *mut *mut c_char,
) {
    let kp = AdminKeyPair::generate();
    unsafe {
        *out_secret = CString::new(kp.secret_b64()).unwrap().into_raw();
        *out_pubkey = CString::new(kp.pubkey_b64()).unwrap().into_raw();
    }
}

/// Зарегистрировать пользователя на сервере.
/// Возвращает 0 при успехе, -1 при ошибке.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_register_user(
    server_url: *const c_char,
    username: *const c_char,
    user_pubkey_b64: *const c_char,
    secret_b64: *const c_char,
) -> i32 {
    let sk = unsafe { CStr::from_ptr(secret_b64) }.to_str().unwrap_or("");
    let server_url  = unsafe { CStr::from_ptr(server_url) }.to_str().unwrap_or("");
    let username    = unsafe { CStr::from_ptr(username) }.to_str().unwrap_or("");
    let pubkey      = unsafe { CStr::from_ptr(user_pubkey_b64) }.to_str().unwrap_or("");
    let sig = match AdminKeyPair::from_secret_b64(sk) {
        Ok(kp) => kp.sign_user_registration(username, pubkey),
        Err(_) => return -1,
    };
    let rt = match tokio::runtime::Runtime::new() {
        Ok(r) => r,
        Err(_) => return -1,
    };
    let cover = Arc::new(crate::client_cover_food::FoodDeliveryClientCover::new());
    let transport = crate::transport::Transport::new(server_url, cover);
    match rt.block_on(transport.reg(username, pubkey, sig.as_str())) {
        Ok(_)  => 0,
        Err(_) => -1,
    }
}

/// Получить новые сообщения из диалога.
/// Возвращает JSON-строку вида [{"id":"...","sender":"...","text":"...","ts":...}, ...]
/// или NULL при ошибке. Освободить через paranoia_free_string.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_receive(
    handle: *mut ParanoiaHandle,
    user_a: *const c_char,
    user_b: *const c_char,
    session_key: *const u8,
) -> *mut c_char {
    let h   = unsafe { &*handle };
    let a   = unsafe { CStr::from_ptr(user_a) }.to_str().unwrap_or("").to_string();
    let b   = unsafe { CStr::from_ptr(user_b) }.to_str().unwrap_or("").to_string();
    let key: [u8; 32] = unsafe { std::slice::from_raw_parts(session_key, 32) }
        .try_into().unwrap();

    let cfg = DialogueConfig { key: DialogueKey::new(&a, &b), session_key: key };
    let dialogue = h.client.open_dialogue(cfg);

    match h.rt.block_on(dialogue.receive()) {
        Ok(msgs) => {
            let json = serde_json::json!(msgs.iter().map(|m| serde_json::json!({
                "id":     m.id,
                "sender": m.sender,
                "content": format!("{:?}", m.content),
                "ts":     m.timestamp.timestamp_millis(),
                "seq":    m.server_seq,
            })).collect::<Vec<_>>());
            CString::new(json.to_string()).unwrap().into_raw()
        }
        Err(_) => std::ptr::null_mut(),
    }
}

/// Освободить строку, возвращённую библиотекой.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_free_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe { drop(CString::from_raw(s)); }
    }
}
