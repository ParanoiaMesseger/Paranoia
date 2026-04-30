// src/ffi.rs
use base64::Engine;
use std::cell::RefCell;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::Arc;
use tokio::runtime::Runtime;

use crate::{
    ClientConfig, ParanoiaClient,
    types::{DialogueConfig, DialogueKey, Message, MessageContent},
};

// ── Thread-local хранилище последней ошибки ──────────────────────────────────

thread_local! {
    static LAST_ERROR: RefCell<CString> = RefCell::new(CString::new("").unwrap());
}

fn set_last_error(msg: &str) {
    LAST_ERROR.with(|e| {
        *e.borrow_mut() =
            CString::new(msg).unwrap_or_else(|_| CString::new("unknown error").unwrap());
    });
}

/// Получить строку последней ошибки FFI для текущего потока.
/// Указатель действителен до следующего вызова любой FFI-функции в этом потоке.
/// Не нужно освобождать через paranoia_free_string.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_last_error() -> *const c_char {
    LAST_ERROR.with(|e| e.borrow().as_ptr())
}

// ── Хэндл клиента ────────────────────────────────────────────────────────────

/// Непрозрачный хэндл для C++
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
    let server_url = unsafe { CStr::from_ptr(server_url) }
        .to_str()
        .unwrap_or("")
        .to_string();
    let username = unsafe { CStr::from_ptr(username) }
        .to_str()
        .unwrap_or("")
        .to_string();
    let sk_b64 = unsafe { CStr::from_ptr(signing_key_b64) }
        .to_str()
        .unwrap_or("");
    let db_path = unsafe { CStr::from_ptr(db_path) }
        .to_str()
        .unwrap_or("")
        .to_string();

    let sk_bytes = match base64::engine::general_purpose::STANDARD.decode(sk_b64) {
        Ok(b) if b.len() == 32 => b,
        _ => {
            set_last_error("invalid_signing_key: expected 32 bytes base64");
            return std::ptr::null_mut();
        }
    };
    let sk_arr: [u8; 32] = sk_bytes.try_into().unwrap();
    let signing_key = ed25519_dalek::SigningKey::from_bytes(&sk_arr);

    let cfg = ClientConfig {
        server_url,
        username,
        signing_key,
        db_path,
    };
    let rt = Runtime::new().unwrap();

    match ParanoiaClient::new(cfg) {
        Ok(client) => Box::into_raw(Box::new(ParanoiaHandle { client, rt })),
        Err(_) => {
            set_last_error("client_init_error");
            std::ptr::null_mut()
        }
    }
}

/// Освободить память хэндла.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_client_free(handle: *mut ParanoiaHandle) {
    if !handle.is_null() {
        unsafe {
            drop(Box::from_raw(handle));
        }
    }
}

/// Отправить текстовое сообщение.
/// Возвращает 0 при успехе, -1 при ошибке. Ошибку см. paranoia_last_error().
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_send_text(
    handle: *mut ParanoiaHandle,
    user_a: *const c_char,
    user_b: *const c_char,
    session_key: *const u8, // 32 байта
    text: *const c_char,
) -> i32 {
    let h = unsafe { &*handle };
    let a = unsafe { CStr::from_ptr(user_a) }
        .to_str()
        .unwrap_or("")
        .to_string();
    let b = unsafe { CStr::from_ptr(user_b) }
        .to_str()
        .unwrap_or("")
        .to_string();
    let text = unsafe { CStr::from_ptr(text) }
        .to_str()
        .unwrap_or("")
        .to_string();
    let key: [u8; 32] = unsafe { std::slice::from_raw_parts(session_key, 32) }
        .try_into()
        .unwrap();

    let cfg = DialogueConfig {
        key: DialogueKey::new(&a, &b),
        session_key: key,
    };
    let dialogue = h.client.open_dialogue(cfg);

    match h.rt.block_on(dialogue.send_text(text)) {
        Ok(_) => 0,
        Err(e) => {
            set_last_error(&classify_send_error(&e.to_string()));
            -1
        }
    }
}

/// Отправить текстовое сообщение и вернуть сохранённое локальное представление.
/// NULL означает ошибку отправки/сохранения. Ошибку см. paranoia_last_error().
/// Освободить через paranoia_free_string.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_send_text_json(
    handle: *mut ParanoiaHandle,
    user_a: *const c_char,
    user_b: *const c_char,
    session_key: *const u8,
    text: *const c_char,
) -> *mut c_char {
    let h = unsafe { &*handle };
    let a = unsafe { CStr::from_ptr(user_a) }
        .to_str()
        .unwrap_or("")
        .to_string();
    let b = unsafe { CStr::from_ptr(user_b) }
        .to_str()
        .unwrap_or("")
        .to_string();
    let text = unsafe { CStr::from_ptr(text) }
        .to_str()
        .unwrap_or("")
        .to_string();
    let key: [u8; 32] = unsafe { std::slice::from_raw_parts(session_key, 32) }
        .try_into()
        .unwrap();

    let cfg = DialogueConfig {
        key: DialogueKey::new(&a, &b),
        session_key: key,
    };
    let dialogue = h.client.open_dialogue(cfg);

    match h.rt.block_on(dialogue.send_text(text)) {
        Ok(msg) => message_to_c_string(&msg),
        Err(e) => {
            set_last_error(&classify_send_error(&e.to_string()));
            std::ptr::null_mut()
        }
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
/// Возвращает 0 при успехе, -1 при ошибке. Ошибку см. paranoia_last_error().
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_register_user(
    server_url: *const c_char,
    username: *const c_char,
    user_pubkey_b64: *const c_char,
    secret_b64: *const c_char,
) -> i32 {
    let sk = unsafe { CStr::from_ptr(secret_b64) }.to_str().unwrap_or("");
    let server_url = unsafe { CStr::from_ptr(server_url) }.to_str().unwrap_or("");
    let username = unsafe { CStr::from_ptr(username) }.to_str().unwrap_or("");
    let pubkey = unsafe { CStr::from_ptr(user_pubkey_b64) }
        .to_str()
        .unwrap_or("");
    let sig = match AdminKeyPair::from_secret_b64(sk) {
        Ok(kp) => kp.sign_user_registration(username, pubkey),
        Err(_) => {
            set_last_error("invalid_admin_key");
            return -1;
        }
    };
    let rt = match tokio::runtime::Runtime::new() {
        Ok(r) => r,
        Err(_) => {
            set_last_error("runtime_error");
            return -1;
        }
    };
    let cover = Arc::new(crate::client_cover_food::FoodDeliveryClientCover::new());
    let transport = crate::transport::Transport::new(server_url, cover);
    match rt.block_on(transport.reg(username, pubkey, sig.as_str())) {
        Ok(_) => 0,
        Err(e) => {
            set_last_error(&classify_network_error(&e.to_string(), "register_error"));
            -1
        }
    }
}

/// Получить новые сообщения из диалога.
/// Возвращает JSON-строку вида [{"id":"...","sender":"...","content":"...","ts":...,"seq":...}, ...]
/// Пустой массив [] означает нет новых сообщений.
/// NULL означает ошибку (сервер недоступен). Ошибку см. paranoia_last_error().
/// Освободить через paranoia_free_string.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_receive(
    handle: *mut ParanoiaHandle,
    user_a: *const c_char,
    user_b: *const c_char,
    session_key: *const u8,
) -> *mut c_char {
    let h = unsafe { &*handle };
    let a = unsafe { CStr::from_ptr(user_a) }
        .to_str()
        .unwrap_or("")
        .to_string();
    let b = unsafe { CStr::from_ptr(user_b) }
        .to_str()
        .unwrap_or("")
        .to_string();
    let key: [u8; 32] = unsafe { std::slice::from_raw_parts(session_key, 32) }
        .try_into()
        .unwrap();

    let cfg = DialogueConfig {
        key: DialogueKey::new(&a, &b),
        session_key: key,
    };
    let dialogue = h.client.open_dialogue(cfg);

    match h.rt.block_on(dialogue.receive()) {
        Ok((msgs, decrypt_errors)) => {
            if decrypt_errors > 0 {
                set_last_error(&format!("decryption_failed:{decrypt_errors}"));
            }
            messages_to_c_string(&msgs)
        }
        Err(e) => {
            let err = e.to_string();
            set_last_error(&classify_network_error(&err, "receive_error"));
            std::ptr::null_mut()
        }
    }
}

/// Получить локальную историю диалога из SQLite.
/// Возвращает JSON-массив в том же формате, что paranoia_receive.
/// NULL при ошибке. Освободить через paranoia_free_string.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_history(
    handle: *mut ParanoiaHandle,
    user_a: *const c_char,
    user_b: *const c_char,
    session_key: *const u8,
    limit: usize,
) -> *mut c_char {
    let h = unsafe { &*handle };
    let a = unsafe { CStr::from_ptr(user_a) }
        .to_str()
        .unwrap_or("")
        .to_string();
    let b = unsafe { CStr::from_ptr(user_b) }
        .to_str()
        .unwrap_or("")
        .to_string();
    let key: [u8; 32] = unsafe { std::slice::from_raw_parts(session_key, 32) }
        .try_into()
        .unwrap();

    let cfg = DialogueConfig {
        key: DialogueKey::new(&a, &b),
        session_key: key,
    };
    let dialogue = h.client.open_dialogue(cfg);

    match h.rt.block_on(dialogue.history(limit, None)) {
        Ok(msgs) => messages_to_c_string(&msgs),
        Err(_) => {
            set_last_error("history_error");
            std::ptr::null_mut()
        }
    }
}

/// Удалить серверную историю диалога до cut_seq включительно.
/// Возвращает 0 при успехе, -1 при ошибке. Ошибку см. paranoia_last_error().
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_determinate(
    handle: *mut ParanoiaHandle,
    user_a: *const c_char,
    user_b: *const c_char,
    session_key: *const u8,
    cut_seq: u64,
) -> i32 {
    let h = unsafe { &*handle };
    let a = unsafe { CStr::from_ptr(user_a) }
        .to_str()
        .unwrap_or("")
        .to_string();
    let b = unsafe { CStr::from_ptr(user_b) }
        .to_str()
        .unwrap_or("")
        .to_string();
    let key: [u8; 32] = unsafe { std::slice::from_raw_parts(session_key, 32) }
        .try_into()
        .unwrap();

    let cfg = DialogueConfig {
        key: DialogueKey::new(&a, &b),
        session_key: key,
    };
    let dialogue = h.client.open_dialogue(cfg);

    match h.rt.block_on(dialogue.clear_server_history(cut_seq)) {
        Ok(_) => 0,
        Err(e) => {
            set_last_error(&classify_network_error(&e.to_string(), "determinate_error"));
            -1
        }
    }
}

/// Удалить локальные данные диалога из SQLite (сообщения, состояние seq).
/// Возвращает 0 при успехе, -1 при ошибке. Ошибку см. paranoia_last_error().
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_delete_local_dialogue(
    handle: *mut ParanoiaHandle,
    user_a: *const c_char,
    user_b: *const c_char,
) -> i32 {
    let h = unsafe { &*handle };
    let a = unsafe { CStr::from_ptr(user_a) }
        .to_str()
        .unwrap_or("")
        .to_string();
    let b = unsafe { CStr::from_ptr(user_b) }
        .to_str()
        .unwrap_or("")
        .to_string();
    let key = DialogueKey::new(&a, &b);

    match h.client.delete_local_dialogue(&key) {
        Ok(_) => 0,
        Err(_) => {
            set_last_error("delete_local_error");
            -1
        }
    }
}

/// Освободить строку, возвращённую библиотекой.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_free_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe {
            drop(CString::from_raw(s));
        }
    }
}

// ── Внутренние вспомогательные функции ───────────────────────────────────────

fn messages_to_c_string(msgs: &[Message]) -> *mut c_char {
    let json = serde_json::json!(msgs.iter().map(message_to_json).collect::<Vec<_>>());
    CString::new(json.to_string()).unwrap().into_raw()
}

fn message_to_c_string(msg: &Message) -> *mut c_char {
    let json = serde_json::json!([message_to_json(msg)]);
    CString::new(json.to_string()).unwrap().into_raw()
}

fn message_to_json(m: &Message) -> serde_json::Value {
    serde_json::json!({
        "id":     m.id,
        "sender": m.sender,
        "content": message_content_for_ui(&m.content),
        "ts":     m.timestamp.timestamp_millis(),
        "seq":    m.server_seq,
    })
}

fn message_content_for_ui(content: &MessageContent) -> String {
    match content {
        MessageContent::Text(text) => format!("Text({text:?})"),
        MessageContent::File(_) => "File(...)".to_string(),
        MessageContent::Image(_) => "Image(...)".to_string(),
        MessageContent::Voice(_) => "Voice(...)".to_string(),
        MessageContent::FileChunk { .. } => "FileChunk(...)".to_string(),
        MessageContent::ReadReceipt { .. } => "ReadReceipt(...)".to_string(),
        MessageContent::Delete { .. } => "Delete(...)".to_string(),
    }
}

/// Классифицировать ошибку отправки в строку для paranoia_last_error().
fn classify_send_error(err: &str) -> String {
    if err.contains("Duplicate seq") || err.contains("duplicate_seq") {
        "duplicate_seq".to_string()
    } else {
        classify_network_error(err, "send_error")
    }
}

fn classify_network_error(err: &str, fallback: &str) -> String {
    let lower = err.to_ascii_lowercase();
    if lower.contains("connection") || lower.contains("connect") || lower.contains("timeout") {
        "server_unavailable".to_string()
    } else {
        fallback.to_string()
    }
}
