// src/ffi.rs
use base64::Engine;
use serde::Deserialize;
use std::cell::RefCell;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::Arc;
use tokio::runtime::Runtime;

use crate::{
    ClientConfig, ParanoiaClient, qr_exchange,
    types::DialogueKeyEntry,
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

    let cfg = DialogueConfig::single_key(DialogueKey::new(&a, &b), key);
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

    let cfg = DialogueConfig::single_key(DialogueKey::new(&a, &b), key);
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

    let cfg = DialogueConfig::single_key(DialogueKey::new(&a, &b), key);
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

    let cfg = DialogueConfig::single_key(DialogueKey::new(&a, &b), key);
    let dialogue = h.client.open_dialogue(cfg);

    match h.rt.block_on(dialogue.history(limit, None)) {
        Ok(msgs) => messages_to_c_string(&msgs),
        Err(_) => {
            set_last_error("history_error");
            std::ptr::null_mut()
        }
    }
}

/// Отправить текстовое сообщение с локальным keyring JSON.
/// keyring_json: [{"start_seq":1,"key":"base64-32-bytes"}, ...]
/// NULL означает ошибку отправки/сохранения. Ошибку см. paranoia_last_error().
/// Освободить через paranoia_free_string.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_send_text_json_keyring(
    handle: *mut ParanoiaHandle,
    user_a: *const c_char,
    user_b: *const c_char,
    keyring_json: *const c_char,
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

    let cfg = match dialogue_config_from_keyring_json(&a, &b, keyring_json) {
        Ok(cfg) => cfg,
        Err(e) => {
            set_last_error(&classify_keyring_error(&e.to_string()));
            return std::ptr::null_mut();
        }
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

/// Получить новые сообщения с сервера, выбирая ключ по start_seq из keyring JSON.
/// Возвращает JSON-массив или NULL при ошибке. Освободить через paranoia_free_string.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_receive_keyring(
    handle: *mut ParanoiaHandle,
    user_a: *const c_char,
    user_b: *const c_char,
    keyring_json: *const c_char,
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

    let cfg = match dialogue_config_from_keyring_json(&a, &b, keyring_json) {
        Ok(cfg) => cfg,
        Err(e) => {
            set_last_error(&classify_keyring_error(&e.to_string()));
            return std::ptr::null_mut();
        }
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
            set_last_error(&classify_network_error(&e.to_string(), "receive_error"));
            std::ptr::null_mut()
        }
    }
}

/// Получить локальную историю диалога из SQLite при keyring-конфигурации.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_history_keyring(
    handle: *mut ParanoiaHandle,
    user_a: *const c_char,
    user_b: *const c_char,
    keyring_json: *const c_char,
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

    let cfg = match dialogue_config_from_keyring_json(&a, &b, keyring_json) {
        Ok(cfg) => cfg,
        Err(e) => {
            set_last_error(&classify_keyring_error(&e.to_string()));
            return std::ptr::null_mut();
        }
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

/// Удалить серверную историю диалога до cut_seq включительно при keyring-конфигурации.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_determinate_keyring(
    handle: *mut ParanoiaHandle,
    user_a: *const c_char,
    user_b: *const c_char,
    keyring_json: *const c_char,
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

    let cfg = match dialogue_config_from_keyring_json(&a, &b, keyring_json) {
        Ok(cfg) => cfg,
        Err(e) => {
            set_last_error(&classify_keyring_error(&e.to_string()));
            return -1;
        }
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

/// Вернуть последний локально синхронизированный server seq для диалога.
/// Возвращает 0 при успехе и пишет результат в out_seq.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_last_pulled_seq(
    handle: *mut ParanoiaHandle,
    user_a: *const c_char,
    user_b: *const c_char,
    out_seq: *mut u64,
) -> i32 {
    if out_seq.is_null() {
        set_last_error("invalid_argument");
        return -1;
    }
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

    match h.client.last_pulled_seq(&key) {
        Ok(seq) => {
            unsafe { *out_seq = seq };
            0
        }
        Err(_) => {
            set_last_error("last_seq_error");
            -1
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

    let cfg = DialogueConfig::single_key(DialogueKey::new(&a, &b), key);
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

/// Создать QR/JSON invitation для out-of-band обмена ключом.
/// Возвращает JSON-объект ExchangeBundle: {"state": {...}, "payload": {...}}.
/// payload можно передавать собеседнику, state должен оставаться локальным.
/// NULL означает ошибку. Ошибку см. paranoia_last_error().
/// Освободить через paranoia_free_string.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_qr_create_invitation(
    initiator_id: *const c_char,
    responder_id: *const c_char,
) -> *mut c_char {
    let initiator_id = match cstr_arg(initiator_id) {
        Ok(v) => v,
        Err(_) => {
            set_last_error("invalid_qr_argument");
            return std::ptr::null_mut();
        }
    };
    let responder_id = match cstr_arg(responder_id) {
        Ok(v) => v,
        Err(_) => {
            set_last_error("invalid_qr_argument");
            return std::ptr::null_mut();
        }
    };

    match qr_exchange::create_invitation(&initiator_id, &responder_id, now_unix())
        .and_then(|bundle| qr_exchange::to_json(&bundle))
    {
        Ok(json) => string_to_c(json),
        Err(e) => {
            set_last_error(&classify_exchange_error(&e.to_string()));
            std::ptr::null_mut()
        }
    }
}

/// Создать QR/JSON response на invitation payload.
/// Возвращает JSON-объект ExchangeBundle: {"state": {...}, "payload": {...}}.
/// payload можно передавать собеседнику, state должен оставаться локальным.
/// NULL означает ошибку. Ошибку см. paranoia_last_error().
/// Освободить через paranoia_free_string.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_qr_create_response(
    invitation_payload_json: *const c_char,
    responder_id: *const c_char,
) -> *mut c_char {
    let invitation_payload_json = match cstr_arg(invitation_payload_json) {
        Ok(v) => v,
        Err(_) => {
            set_last_error("invalid_qr_argument");
            return std::ptr::null_mut();
        }
    };
    let responder_id = match cstr_arg(responder_id) {
        Ok(v) => v,
        Err(_) => {
            set_last_error("invalid_qr_argument");
            return std::ptr::null_mut();
        }
    };

    let result = qr_exchange::payload_from_json(&invitation_payload_json)
        .and_then(|payload| qr_exchange::create_response(&payload, &responder_id, now_unix()))
        .and_then(|bundle| qr_exchange::to_json(&bundle));

    match result {
        Ok(json) => string_to_c(json),
        Err(e) => {
            set_last_error(&classify_exchange_error(&e.to_string()));
            std::ptr::null_mut()
        }
    }
}

/// Посчитать 6-значный SAS/fingerprint для показа пользователю.
/// Ключ диалога эта функция не возвращает.
/// NULL означает ошибку. Ошибку см. paranoia_last_error().
/// Освободить через paranoia_free_string.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_qr_fingerprint(
    local_state_json: *const c_char,
    peer_payload_json: *const c_char,
) -> *mut c_char {
    let completed = match complete_qr_exchange_from_json(local_state_json, peer_payload_json) {
        Ok(v) => v,
        Err(e) => {
            set_last_error(&classify_exchange_error(&e.to_string()));
            return std::ptr::null_mut();
        }
    };

    string_to_c(completed.fingerprint)
}

/// Подтвердить SAS/fingerprint и вернуть completed exchange JSON.
/// Возвращаемый JSON содержит session_key_b64; вызывать только после сравнения
/// SAS пользователем по независимому каналу.
/// NULL означает ошибку. Ошибку см. paranoia_last_error().
/// Освободить через paranoia_free_string.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_qr_confirm_exchange(
    local_state_json: *const c_char,
    peer_payload_json: *const c_char,
    confirmed_fingerprint: *const c_char,
) -> *mut c_char {
    let confirmed_fingerprint = match cstr_arg(confirmed_fingerprint) {
        Ok(v) => v,
        Err(_) => {
            set_last_error("invalid_qr_argument");
            return std::ptr::null_mut();
        }
    };
    let completed = match complete_qr_exchange_from_json(local_state_json, peer_payload_json) {
        Ok(v) => v,
        Err(e) => {
            set_last_error(&classify_exchange_error(&e.to_string()));
            return std::ptr::null_mut();
        }
    };
    if completed.fingerprint != confirmed_fingerprint {
        set_last_error("fingerprint_mismatch");
        return std::ptr::null_mut();
    }

    match qr_exchange::to_json(&completed) {
        Ok(json) => string_to_c(json),
        Err(e) => {
            set_last_error(&classify_exchange_error(&e.to_string()));
            std::ptr::null_mut()
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

// ── ECIES device keypair & шифрование экспорта ───────────────────────────────

/// Сгенерировать X25519 device keypair для шифрования экспорта.
/// out_privkey и out_pubkey заполняются base64-строками (освободить через paranoia_free_string).
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_ecies_generate_keypair(
    out_privkey: *mut *mut c_char,
    out_pubkey: *mut *mut c_char,
) {
    let (priv_bytes, pub_bytes) = crate::export::generate_device_keypair();
    let priv_b64 = base64::engine::general_purpose::STANDARD.encode(priv_bytes);
    let pub_b64 = base64::engine::general_purpose::STANDARD.encode(pub_bytes);
    unsafe {
        *out_privkey = CString::new(priv_b64).unwrap().into_raw();
        *out_pubkey = CString::new(pub_b64).unwrap().into_raw();
    }
}

/// Вывести публичный ключ устройства из base64-приватного ключа.
/// Возвращает base64-строку или NULL при ошибке. Освободить через paranoia_free_string.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_ecies_pubkey(privkey_b64: *const c_char) -> *mut c_char {
    let priv_b64 = match cstr_arg(privkey_b64) {
        Ok(v) => v,
        Err(_) => {
            set_last_error("invalid_argument");
            return std::ptr::null_mut();
        }
    };
    let priv_bytes = match base64::engine::general_purpose::STANDARD.decode(&priv_b64) {
        Ok(b) if b.len() == 32 => {
            let mut arr = [0u8; 32];
            arr.copy_from_slice(&b);
            arr
        }
        _ => {
            set_last_error("invalid_device_key");
            return std::ptr::null_mut();
        }
    };
    let pub_bytes = crate::export::pubkey_from_privkey(&priv_bytes);
    string_to_c(base64::engine::general_purpose::STANDARD.encode(pub_bytes))
}

/// Зашифровать строку на публичном ключе принимающего устройства (ECIES).
/// receiver_pubkey_b64 — base64 X25519 публичный ключ (32 байта).
/// plaintext — UTF-8 строка (обычно JSON payload экспорта).
/// Возвращает JSON-конверт EciesEnvelope или NULL при ошибке.
/// Освободить через paranoia_free_string.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_ecies_encrypt(
    receiver_pubkey_b64: *const c_char,
    plaintext: *const c_char,
) -> *mut c_char {
    let pub_b64 = match cstr_arg(receiver_pubkey_b64) {
        Ok(v) => v,
        Err(_) => {
            set_last_error("invalid_argument");
            return std::ptr::null_mut();
        }
    };
    let plaintext_str = match cstr_arg(plaintext) {
        Ok(v) => v,
        Err(_) => {
            set_last_error("invalid_argument");
            return std::ptr::null_mut();
        }
    };
    let pub_bytes = match base64::engine::general_purpose::STANDARD.decode(&pub_b64) {
        Ok(b) if b.len() == 32 => {
            let mut arr = [0u8; 32];
            arr.copy_from_slice(&b);
            arr
        }
        _ => {
            set_last_error("invalid_device_key");
            return std::ptr::null_mut();
        }
    };
    match crate::export::ecies_encrypt(&pub_bytes, plaintext_str.as_bytes()) {
        Ok(json) => string_to_c(json),
        Err(_) => {
            set_last_error("ecies_encrypt_error");
            std::ptr::null_mut()
        }
    }
}

/// Расшифровать JSON-конверт EciesEnvelope приватным ключом устройства.
/// device_privkey_b64 — base64 X25519 приватный ключ (32 байта).
/// envelope_json — JSON-конверт, полученный от paranoia_ecies_encrypt.
/// Возвращает исходную UTF-8 строку (plaintext) или NULL при ошибке.
/// Освободить через paranoia_free_string.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_ecies_decrypt(
    device_privkey_b64: *const c_char,
    envelope_json: *const c_char,
) -> *mut c_char {
    let priv_b64 = match cstr_arg(device_privkey_b64) {
        Ok(v) => v,
        Err(_) => {
            set_last_error("invalid_argument");
            return std::ptr::null_mut();
        }
    };
    let envelope = match cstr_arg(envelope_json) {
        Ok(v) => v,
        Err(_) => {
            set_last_error("invalid_argument");
            return std::ptr::null_mut();
        }
    };
    let priv_bytes = match base64::engine::general_purpose::STANDARD.decode(&priv_b64) {
        Ok(b) if b.len() == 32 => {
            let mut arr = [0u8; 32];
            arr.copy_from_slice(&b);
            arr
        }
        _ => {
            set_last_error("invalid_device_key");
            return std::ptr::null_mut();
        }
    };
    match crate::export::ecies_decrypt(&priv_bytes, &envelope) {
        Ok(plaintext_bytes) => match String::from_utf8(plaintext_bytes) {
            Ok(s) => string_to_c(s),
            Err(_) => {
                set_last_error("ecies_decrypt_not_utf8");
                std::ptr::null_mut()
            }
        },
        Err(e) => {
            let lower = e.to_string().to_ascii_lowercase();
            if lower.contains("decryption failed") {
                set_last_error("ecies_decrypt_error");
            } else if lower.contains("unsupported") {
                set_last_error("ecies_unsupported_version");
            } else {
                set_last_error("ecies_decrypt_error");
            }
            std::ptr::null_mut()
        }
    }
}

// ── Внутренние вспомогательные функции ───────────────────────────────────────

fn cstr_arg(ptr: *const c_char) -> anyhow::Result<String> {
    if ptr.is_null() {
        anyhow::bail!("null argument");
    }
    Ok(unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .unwrap_or("")
        .to_string())
}

fn string_to_c(value: String) -> *mut c_char {
    CString::new(value).unwrap().into_raw()
}

fn now_unix() -> i64 {
    chrono::Utc::now().timestamp()
}

fn complete_qr_exchange_from_json(
    local_state_json: *const c_char,
    peer_payload_json: *const c_char,
) -> anyhow::Result<qr_exchange::CompletedExchange> {
    let local_state_json = cstr_arg(local_state_json)?;
    let peer_payload_json = cstr_arg(peer_payload_json)?;
    let state = qr_exchange::state_from_json(&local_state_json)?;
    let payload = qr_exchange::payload_from_json(&peer_payload_json)?;
    qr_exchange::complete_exchange(&state, &payload, now_unix())
}

#[derive(Deserialize)]
struct FfiKeyringEntry {
    start_seq: u64,
    key: String,
}

fn dialogue_config_from_keyring_json(
    user_a: &str,
    user_b: &str,
    keyring_json: *const c_char,
) -> anyhow::Result<DialogueConfig> {
    let keyring_json = cstr_arg(keyring_json)?;
    let raw_entries: Vec<FfiKeyringEntry> = serde_json::from_str(&keyring_json)?;
    let mut entries = Vec::with_capacity(raw_entries.len());
    for entry in raw_entries {
        if entry.start_seq == 0 {
            anyhow::bail!("invalid keyring start_seq");
        }
        let key_bytes = base64::engine::general_purpose::STANDARD.decode(entry.key)?;
        let key: [u8; 32] = key_bytes
            .try_into()
            .map_err(|_| anyhow::anyhow!("invalid keyring key length"))?;
        entries.push(DialogueKeyEntry {
            start_seq: entry.start_seq,
            key,
        });
    }
    DialogueConfig::with_keyring(DialogueKey::new(user_a, user_b), entries)
}

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
/// pub(crate) для unit-тестов.
pub(crate) fn classify_send_error(err: &str) -> String {
    if err.contains("Duplicate seq") || err.contains("duplicate_seq") {
        "duplicate_seq".to_string()
    } else if err.contains("Invalid seq")
        || err.contains("invalid_seq")
        || err.contains("expected seq")
    {
        "invalid_seq".to_string()
    } else {
        classify_network_error(err, "send_error")
    }
}

pub(crate) fn classify_network_error(err: &str, fallback: &str) -> String {
    let lower = err.to_ascii_lowercase();
    // reqwest ошибки недоступности сервера содержат одно из этих ключевых слов.
    // "error sending request" — стандартный префикс reqwest при сбое транспорта.
    if lower.contains("connection")
        || lower.contains("connect")
        || lower.contains("timeout")
        || lower.contains("error sending request")
        || lower.contains("refused")
    {
        "server_unavailable".to_string()
    } else {
        fallback.to_string()
    }
}

pub(crate) fn classify_exchange_error(err: &str) -> String {
    let lower = err.to_ascii_lowercase();
    if lower.contains("expired") {
        "exchange_expired".to_string()
    } else if lower.contains("fingerprint_mismatch") || lower.contains("fingerprint mismatch") {
        "fingerprint_mismatch".to_string()
    } else if lower.contains("already used") {
        "exchange_id_reused".to_string()
    } else if lower.contains("mismatch") {
        "participant_mismatch".to_string()
    } else if lower.contains("payload json") || lower.contains("payload") {
        "invalid_exchange_payload".to_string()
    } else if lower.contains("state json") || lower.contains("state") {
        "invalid_exchange_state".to_string()
    } else {
        "qr_exchange_error".to_string()
    }
}

pub(crate) fn classify_keyring_error(err: &str) -> String {
    let lower = err.to_ascii_lowercase();
    if lower.contains("duplicate") {
        "invalid_keyring_duplicate_start_seq".to_string()
    } else if lower.contains("start_seq") {
        "invalid_keyring_start_seq".to_string()
    } else if lower.contains("length") {
        "invalid_keyring_key_length".to_string()
    } else {
        "invalid_keyring".to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── classify_send_error ──────────────────────────────────────────────────

    #[test]
    fn duplicate_seq_is_classified() {
        assert_eq!(classify_send_error("Duplicate seq 42"), "duplicate_seq");
        assert_eq!(
            classify_send_error("Push failed: Duplicate seq 1"),
            "duplicate_seq"
        );
        assert_eq!(classify_send_error("error: duplicate_seq"), "duplicate_seq");
    }

    #[test]
    fn invalid_seq_is_classified() {
        assert_eq!(classify_send_error("Invalid seq 42"), "invalid_seq");
        assert_eq!(
            classify_send_error("Push failed: expected seq 7"),
            "invalid_seq"
        );
        assert_eq!(classify_send_error("error: invalid_seq"), "invalid_seq");
    }

    #[test]
    fn duplicate_seq_does_not_leak_server_data() {
        // seq number и dialogue ID не должны появляться в результате
        let raw = "Push failed: Duplicate seq 99 for dialogue:deadbeefcafe0000";
        let classified = classify_send_error(raw);
        assert_eq!(classified, "duplicate_seq");
        assert!(!classified.contains("99"));
        assert!(!classified.contains("deadbeef"));
        assert!(!classified.contains("dialogue"));
    }

    #[test]
    fn network_error_classified_as_server_unavailable() {
        assert_eq!(
            classify_network_error("connection refused", "fallback"),
            "server_unavailable"
        );
        assert_eq!(
            classify_network_error("connect error: refused", "fallback"),
            "server_unavailable"
        );
        assert_eq!(
            classify_network_error("request timeout after 30s", "fallback"),
            "server_unavailable"
        );
    }

    #[test]
    fn network_error_strips_server_url() {
        // URL сервера не должен попасть в результат
        let raw = "connection refused to http://secret.internal.server.example.com:8443/push";
        let classified = classify_network_error(raw, "send_error");
        assert_eq!(classified, "server_unavailable");
        assert!(!classified.contains("secret.internal"));
        assert!(!classified.contains("example.com"));
        assert!(!classified.contains("http://"));
        assert!(!classified.contains("8443"));
    }

    #[test]
    fn send_error_strips_raw_server_response() {
        // Сырой ответ сервера (payload, приватные данные) не должен попасть в результат
        let raw = "Push failed: internal state dump: private_key=abc123 payload_b64=XXXYYY==";
        let classified = classify_send_error(raw);
        assert_eq!(classified, "send_error");
        assert!(!classified.contains("private_key"));
        assert!(!classified.contains("abc123"));
        assert!(!classified.contains("payload_b64"));
        assert!(!classified.contains("XXXYYY"));
    }

    #[test]
    fn receive_error_strips_raw_server_response() {
        let raw =
            "Pull failed: {\"ok\":false,\"error\":\"internal: db_path=/var/data/users/bob.db\"}";
        let classified = classify_network_error(raw, "receive_error");
        assert_eq!(classified, "receive_error");
        assert!(!classified.contains("db_path"));
        assert!(!classified.contains("/var/data"));
        assert!(!classified.contains("bob.db"));
    }

    #[test]
    fn unknown_error_uses_fallback_without_raw_message() {
        let raw = "some unknown internal error with sensitive_token=s3cr3t";
        let classified = classify_send_error(raw);
        assert_eq!(classified, "send_error");
        assert!(!classified.contains("sensitive_token"));
        assert!(!classified.contains("s3cr3t"));
    }

    #[test]
    fn reqwest_error_sending_request_is_server_unavailable() {
        // reqwest 0.13 возвращает "error sending request for url (...)" при сбое транспорта
        let raw = "error sending request for url (http://secret.internal.server:9000/push)";
        let classified = classify_network_error(raw, "send_error");
        assert_eq!(classified, "server_unavailable");
        // URL не должен утечь
        assert!(!classified.contains("secret.internal"));
        assert!(!classified.contains("9000"));
        assert!(!classified.contains("http://"));
    }

    #[test]
    fn exchange_errors_are_classified_without_raw_payload() {
        assert_eq!(
            classify_exchange_error("exchange payload expired"),
            "exchange_expired"
        );
        assert_eq!(
            classify_exchange_error("responder_id mismatch: bob vs mallory"),
            "participant_mismatch"
        );
        assert_eq!(
            classify_exchange_error("invalid exchange payload json: {private_key=abc}"),
            "invalid_exchange_payload"
        );

        let classified =
            classify_exchange_error("invalid exchange payload json: private_key=abc123");
        assert_eq!(classified, "invalid_exchange_payload");
        assert!(!classified.contains("private_key"));
        assert!(!classified.contains("abc123"));
    }

    #[test]
    fn keyring_errors_are_classified_without_raw_key_material() {
        assert_eq!(
            classify_keyring_error("invalid keyring start_seq 0"),
            "invalid_keyring_start_seq"
        );
        assert_eq!(
            classify_keyring_error("invalid keyring key length: secret_b64=abc"),
            "invalid_keyring_key_length"
        );
        assert_eq!(
            classify_keyring_error("duplicate keyring start_seq"),
            "invalid_keyring_duplicate_start_seq"
        );

        let classified = classify_keyring_error("raw keyring [{\"key\":\"SECRET\"}]");
        assert_eq!(classified, "invalid_keyring");
        assert!(!classified.contains("SECRET"));
        assert!(!classified.contains("keyring ["));
    }
}
