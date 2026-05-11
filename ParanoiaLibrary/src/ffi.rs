use base64::{Engine, engine::general_purpose::STANDARD as B64};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::cell::RefCell;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Arc;
use tokio::runtime::Runtime;

use crate::{
    ClientConfig, Dialogue, ParanoiaClient,
    error_classify::{
        classify_exchange_error, classify_keyring_error, classify_network_error,
        classify_send_error,
    },
    qr_exchange,
    types::DialogueKeyEntry,
    types::{DialogueConfig, DialogueKey, Message, MessageContent},
};

macro_rules! ffi_try {
    ($expr:expr, $invalid:expr) => {
        match $expr {
            Ok(value) => value,
            Err(_) => return $invalid,
        }
    };
}

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

fn clear_last_error() {
    set_last_error("");
}

fn ffi_catch_ptr<F>(fallback_error: &str, f: F) -> *mut c_char
where
    F: FnOnce() -> *mut c_char,
{
    ffi_catch_value(panic_error_code(fallback_error), std::ptr::null_mut(), f)
}

fn ffi_catch_value<T, F>(fallback_error: &str, fallback_value: T, f: F) -> T
where
    F: FnOnce() -> T,
{
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(value) => value,
        Err(_) => {
            set_last_error(fallback_error);
            fallback_value
        }
    }
}

fn ffi_catch_i32<F>(fallback_error: &str, f: F) -> i32
where
    F: FnOnce() -> i32,
{
    ffi_catch_value(panic_error_code(fallback_error), -1, f)
}

fn panic_error_code(fallback_error: &str) -> &str {
    match fallback_error {
        "send_error" => "send_panic",
        "attachment_error" => "attachment_panic",
        "receive_error" => "receive_panic",
        "notify_error" => "notify_panic",
        "history_error" => "history_panic",
        "determinate_error" => "determinate_panic",
        "client_init_error" => "client_init_panic",
        "last_seq_error" => "last_seq_panic",
        _ => fallback_error,
    }
}

fn invalid_argument_ptr() -> *mut c_char {
    set_last_error("invalid_argument");
    std::ptr::null_mut()
}

fn invalid_qr_argument_ptr() -> *mut c_char {
    set_last_error("invalid_qr_argument");
    std::ptr::null_mut()
}

fn invalid_argument_i32() -> i32 {
    set_last_error("invalid_argument");
    -1
}

fn invalid_argument_null<T>() -> *mut T {
    set_last_error("invalid_argument");
    std::ptr::null_mut()
}

fn anyhow_error_chain(error: &anyhow::Error) -> String {
    error
        .chain()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join(": ")
}

/// Получить строку последней ошибки FFI для текущего потока.
/// Указатель действителен до следующего вызова любой FFI-функции в этом потоке.
/// Не нужно освобождать через paranoia_free_string.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_last_error() -> *const c_char {
    LAST_ERROR.with(|e| e.borrow().as_ptr())
}

/// Инициализировать Android certificate verifier для rustls-platform-verifier.
/// raw_env — JNIEnv*, raw_context — android.content.Context jobject.
/// Вызывать один раз при старте Android-приложения, до сетевых FFI-вызовов.
#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_android_init(
    raw_env: *mut std::ffi::c_void,
    raw_context: *mut std::ffi::c_void,
) -> i32 {
    ffi_catch_i32("android_init_error", || {
        clear_last_error();

        if raw_env.is_null() || raw_context.is_null() {
            return invalid_argument_i32();
        }

        let mut env = match unsafe { jni::JNIEnv::from_raw(raw_env as *mut jni::sys::JNIEnv) } {
            Ok(env) => env,
            Err(_) => {
                set_last_error("android_init_error");
                return -1;
            }
        };
        let context = unsafe { jni::objects::JObject::from_raw(raw_context as jni::sys::jobject) };

        match rustls_platform_verifier::android::init_with_env(&mut env, context) {
            Ok(()) => 0,
            Err(_) => {
                set_last_error("android_init_error");
                -1
            }
        }
    })
}

// ── Хэндл клиента ────────────────────────────────────────────────────────────

/// Непрозрачный хэндл для C++
pub struct ParanoiaHandle {
    client: ParanoiaClient,
    rt: Runtime,
}

fn handle_ref<'a>(handle: *mut ParanoiaHandle) -> anyhow::Result<&'a ParanoiaHandle> {
    if handle.is_null() {
        anyhow::bail!("null handle");
    }
    Ok(unsafe { &*handle })
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
    ffi_catch_value("client_init_error", std::ptr::null_mut(), || {
        clear_last_error();
        let server_url = ffi_try!(cstr_arg(server_url), invalid_argument_null());
        let username = ffi_try!(cstr_arg(username), invalid_argument_null());
        let sk_b64 = ffi_try!(cstr_arg(signing_key_b64), invalid_argument_null());
        let db_path = ffi_try!(cstr_arg(db_path), invalid_argument_null());

        let signing_key = match decode_b64_32(&sk_b64) {
            Ok(sk) => ed25519_dalek::SigningKey::from_bytes(&sk),
            _ => {
                set_last_error("invalid_signing_key: expected 32 bytes base64");
                return std::ptr::null_mut();
            }
        };

        let cfg = ClientConfig {
            server_url,
            username,
            signing_key,
            db_path,
        };
        let rt = match Runtime::new() {
            Ok(rt) => rt,
            Err(_) => {
                set_last_error("runtime_error");
                return std::ptr::null_mut();
            }
        };

        match ParanoiaClient::new(cfg) {
            Ok(client) => Box::into_raw(Box::new(ParanoiaHandle { client, rt })),
            Err(_) => {
                set_last_error("client_init_error");
                std::ptr::null_mut()
            }
        }
    })
}

/// Вывести server_id из Ed25519 signing key.
/// Возвращает hex SHA256("paranoia:server-id:v1\n" || public_key_bytes) или NULL при ошибке.
/// Освободить через paranoia_free_string.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_derive_server_id(signing_key_b64: *const c_char) -> *mut c_char {
    ffi_catch_ptr("derive_server_id_error", || {
        clear_last_error();
        let sk_b64 = ffi_try!(cstr_arg(signing_key_b64), invalid_argument_ptr());
        let sk_bytes = match decode_b64_32(&sk_b64) {
            Ok(bytes) => bytes,
            Err(_) => {
                set_last_error("invalid_signing_key");
                return std::ptr::null_mut();
            }
        };
        let signing_key = ed25519_dalek::SigningKey::from_bytes(&sk_bytes);
        let pub_key = signing_key.verifying_key().to_bytes();
        let mut hasher = Sha256::new();
        hasher.update(b"paranoia:server-id:v1\n");
        hasher.update(pub_key);
        string_to_c(hex::encode(hasher.finalize()))
    })
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

use crate::AdminKeyPair;

/// Генерировать новую пару ключей администратора.
/// Возвращает приватный ключ в base64 через out_secret (caller должен освободить через paranoia_free_string).
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_generate_keypair(
    out_secret: *mut *mut c_char,
    out_pubkey: *mut *mut c_char,
) {
    ffi_catch_value("keypair_error", (), || {
        clear_last_error();
        let kp = AdminKeyPair::generate();
        write_two_out_params(out_secret, kp.secret_b64(), out_pubkey, kp.pubkey_b64());
    })
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
    ffi_catch_i32("register_error", || {
        clear_last_error();
        let sk = ffi_try!(cstr_arg(secret_b64), invalid_argument_i32());
        let server_url = ffi_try!(cstr_arg(server_url), invalid_argument_i32());
        let username = ffi_try!(cstr_arg(username), invalid_argument_i32());
        let pubkey = ffi_try!(cstr_arg(user_pubkey_b64), invalid_argument_i32());
        let sig = match AdminKeyPair::from_secret_b64(&sk) {
            Ok(kp) => kp.sign_user_registration(&username, &pubkey),
            Err(_) => {
                set_last_error("invalid_admin_key");
                return -1;
            }
        };
        let rt = match Runtime::new() {
            Ok(r) => r,
            Err(_) => {
                set_last_error("runtime_error");
                return -1;
            }
        };
        let cover = Arc::new(crate::client_cover_food::FoodDeliveryClientCover::new());
        let transport = crate::transport::Transport::new(&server_url, cover);
        match rt.block_on(transport.reg(&username, &pubkey, sig.as_str())) {
            Ok(_) => 0,
            Err(e) => {
                set_last_error(&classify_network_error(
                    &anyhow_error_chain(&e),
                    "register_error",
                ));
                -1
            }
        }
    })
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
    ffi_catch_ptr("send_error", || {
        clear_last_error();
        let text = ffi_try!(cstr_arg(text), invalid_argument_ptr());
        with_keyring_dialogue(
            handle,
            user_a,
            user_b,
            keyring_json,
            std::ptr::null_mut(),
            |h, dialogue| match h.rt.block_on(dialogue.send_text(text)) {
                Ok(msg) => message_to_c_string(&msg),
                Err(e) => {
                    set_last_error(&classify_send_error(&anyhow_error_chain(&e)));
                    std::ptr::null_mut()
                }
            },
        )
    })
}

/// Отправить файл, прочитав его с локального пути, через keyring-конфигурацию.
/// Возвращает JSON-массив сообщений или NULL при ошибке.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_send_file_json_keyring(
    handle: *mut ParanoiaHandle,
    user_a: *const c_char,
    user_b: *const c_char,
    keyring_json: *const c_char,
    file_path: *const c_char,
    mime_type: *const c_char,
) -> *mut c_char {
    ffi_catch_ptr("send_error", || {
        clear_last_error();
        let path = ffi_try!(cstr_arg(file_path), invalid_argument_ptr());
        let mime_type = cstr_arg(mime_type).unwrap_or_default();
        let filename = std::path::Path::new(&path)
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("attachment.bin")
            .to_string();
        let mime_type = if mime_type.trim().is_empty() {
            "application/octet-stream".to_string()
        } else {
            mime_type
        };

        with_keyring_dialogue(
            handle,
            user_a,
            user_b,
            keyring_json,
            std::ptr::null_mut(),
            |h, dialogue| match h.rt.block_on(dialogue.send_file_path(
                filename,
                mime_type,
                std::path::Path::new(&path),
            )) {
                Ok(msgs) => messages_to_c_string(&msgs),
                Err(e) => {
                    set_last_error(&classify_send_error(&anyhow_error_chain(&e)));
                    std::ptr::null_mut()
                }
            },
        )
    })
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
    ffi_catch_ptr("receive_error", || {
        clear_last_error();
        with_keyring_dialogue(
            handle,
            user_a,
            user_b,
            keyring_json,
            std::ptr::null_mut(),
            |h, dialogue| match h.rt.block_on(dialogue.receive()) {
                Ok((msgs, decrypt_errors)) => {
                    if decrypt_errors > 0 {
                        set_last_error(&format!("decryption_failed:{decrypt_errors}"));
                    }
                    messages_to_c_string(&msgs)
                }
                Err(e) => {
                    set_last_error(&classify_network_error(
                        &anyhow_error_chain(&e),
                        "receive_error",
                    ));
                    std::ptr::null_mut()
                }
            },
        )
    })
}

/// Проверить количество новых серверных сообщений без загрузки payload.
/// Возвращает 0 при успехе и пишет результат в out_count.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_notify_count_keyring(
    handle: *mut ParanoiaHandle,
    user_a: *const c_char,
    user_b: *const c_char,
    keyring_json: *const c_char,
    out_count: *mut u64,
) -> i32 {
    ffi_catch_i32("notify_error", || {
        clear_last_error();
        if out_count.is_null() {
            return invalid_argument_i32();
        }
        with_keyring_dialogue(
            handle,
            user_a,
            user_b,
            keyring_json,
            -1,
            |h, dialogue| match h.rt.block_on(dialogue.notify_count()) {
                Ok(count) => {
                    unsafe { *out_count = count };
                    0
                }
                Err(e) => {
                    set_last_error(&classify_network_error(
                        &anyhow_error_chain(&e),
                        "notify_error",
                    ));
                    -1
                }
            },
        )
    })
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
    ffi_catch_ptr("history_error", || {
        clear_last_error();
        with_keyring_dialogue(
            handle,
            user_a,
            user_b,
            keyring_json,
            std::ptr::null_mut(),
            |h, dialogue| match h.rt.block_on(dialogue.history(limit, None)) {
                Ok(msgs) => messages_to_c_string(&msgs),
                Err(_) => {
                    set_last_error("history_error");
                    std::ptr::null_mut()
                }
            },
        )
    })
}

/// Сохранить вложение в файл, скачав body-пакеты через bounded pull при необходимости.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_save_attachment_keyring(
    handle: *mut ParanoiaHandle,
    user_a: *const c_char,
    user_b: *const c_char,
    keyring_json: *const c_char,
    message_id: *const c_char,
    target_path: *const c_char,
) -> i32 {
    ffi_catch_i32("attachment_error", || {
        clear_last_error();
        let message_id = ffi_try!(cstr_arg(message_id), invalid_argument_i32());
        let target_path = ffi_try!(cstr_arg(target_path), invalid_argument_i32());
        with_keyring_dialogue(
            handle,
            user_a,
            user_b,
            keyring_json,
            -1,
            |h, dialogue| match h
                .rt
                .block_on(dialogue.download_attachment(&message_id, &target_path))
            {
                Ok(()) => 0,
                Err(e) => {
                    set_last_error(&anyhow_error_chain(&e));
                    -1
                }
            },
        )
    })
}

/// Сохранить вложение во внутренний cache приложения и вернуть локальный путь.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_cache_attachment_keyring(
    handle: *mut ParanoiaHandle,
    user_a: *const c_char,
    user_b: *const c_char,
    keyring_json: *const c_char,
    message_id: *const c_char,
) -> *mut c_char {
    ffi_catch_ptr("attachment_error", || {
        clear_last_error();
        let message_id = ffi_try!(cstr_arg(message_id), invalid_argument_ptr());
        with_keyring_dialogue(
            handle,
            user_a,
            user_b,
            keyring_json,
            std::ptr::null_mut(),
            |h, dialogue| match h.rt.block_on(dialogue.cache_attachment(&message_id)) {
                Ok(path) => string_to_c(path),
                Err(e) => {
                    set_last_error(&anyhow_error_chain(&e));
                    std::ptr::null_mut()
                }
            },
        )
    })
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
    ffi_catch_i32("determinate_error", || {
        clear_last_error();
        with_keyring_dialogue(
            handle,
            user_a,
            user_b,
            keyring_json,
            -1,
            |h, dialogue| match h.rt.block_on(dialogue.clear_server_history(cut_seq)) {
                Ok(_) => 0,
                Err(e) => {
                    set_last_error(&classify_network_error(
                        &anyhow_error_chain(&e),
                        "determinate_error",
                    ));
                    -1
                }
            },
        )
    })
}

/// Удалить локальные сообщения диалога до cut_seq включительно при keyring-конфигурации.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_delete_local_until_keyring(
    handle: *mut ParanoiaHandle,
    user_a: *const c_char,
    user_b: *const c_char,
    keyring_json: *const c_char,
    cut_seq: u64,
) -> i32 {
    ffi_catch_i32("delete_local_error", || {
        clear_last_error();
        with_keyring_dialogue(handle, user_a, user_b, keyring_json, -1, |_h, dialogue| {
            match dialogue.delete_local_until(cut_seq) {
                Ok(_) => 0,
                Err(e) => {
                    set_last_error(&anyhow_error_chain(&e));
                    -1
                }
            }
        })
    })
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
    ffi_catch_i32("last_seq_error", || {
        clear_last_error();
        if out_seq.is_null() {
            return invalid_argument_i32();
        }
        let h = ffi_try!(handle_ref(handle), invalid_argument_i32());
        let a = ffi_try!(cstr_arg(user_a), invalid_argument_i32());
        let b = ffi_try!(cstr_arg(user_b), invalid_argument_i32());
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
    })
}

/// Удалить локальные данные диалога из SQLite (сообщения, состояние seq).
/// Возвращает 0 при успехе, -1 при ошибке. Ошибку см. paranoia_last_error().
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_delete_local_dialogue(
    handle: *mut ParanoiaHandle,
    user_a: *const c_char,
    user_b: *const c_char,
) -> i32 {
    ffi_catch_i32("delete_local_error", || {
        clear_last_error();
        let h = ffi_try!(handle_ref(handle), invalid_argument_i32());
        let a = ffi_try!(cstr_arg(user_a), invalid_argument_i32());
        let b = ffi_try!(cstr_arg(user_b), invalid_argument_i32());
        let key = DialogueKey::new(&a, &b);

        match h.client.delete_local_dialogue(&key) {
            Ok(_) => 0,
            Err(_) => {
                set_last_error("delete_local_error");
                -1
            }
        }
    })
}

/// Создать QR/JSON invitation для out-of-band обмена ключом.
/// Возвращает JSON-объект ExchangeBundle: {"state": {...}, "payload": {...}}.
/// payload можно передавать собеседнику, state должен оставаться локальным.
/// NULL означает ошибку. Ошибку см. paranoia_last_error().
/// Освободить через paranoia_free_string.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_qr_create_invitation(initiator_id: *const c_char) -> *mut c_char {
    ffi_catch_ptr("qr_exchange_error", || {
        clear_last_error();
        let initiator_id = ffi_try!(cstr_arg(initiator_id), invalid_qr_argument_ptr());
        exchange_string_to_c(
            qr_exchange::create_invitation(&initiator_id, now_unix())
                .and_then(|bundle| qr_exchange::to_json(&bundle)),
        )
    })
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
    ffi_catch_ptr("qr_exchange_error", || {
        clear_last_error();
        let invitation_payload_json =
            ffi_try!(cstr_arg(invitation_payload_json), invalid_qr_argument_ptr());
        let responder_id = ffi_try!(cstr_arg(responder_id), invalid_qr_argument_ptr());

        exchange_string_to_c(
            qr_exchange::payload_from_json(&invitation_payload_json)
                .and_then(|payload| {
                    qr_exchange::create_response(&payload, &responder_id, now_unix())
                })
                .and_then(|bundle| qr_exchange::to_json(&bundle)),
        )
    })
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
    ffi_catch_ptr("qr_exchange_error", || {
        clear_last_error();
        exchange_string_to_c(
            complete_qr_exchange_from_json(local_state_json, peer_payload_json)
                .map(|completed| completed.fingerprint),
        )
    })
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
    ffi_catch_ptr("qr_exchange_error", || {
        clear_last_error();
        let confirmed_fingerprint =
            ffi_try!(cstr_arg(confirmed_fingerprint), invalid_qr_argument_ptr());
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
        exchange_string_to_c(qr_exchange::to_json(&completed))
    })
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
/// out_private_key и out_pubkey заполняются base64-строками (освободить через paranoia_free_string).
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_ecies_generate_keypair(
    out_private_key: *mut *mut c_char,
    out_pubkey: *mut *mut c_char,
) {
    ffi_catch_value("ecies_keypair_error", (), || {
        clear_last_error();
        let (priv_bytes, pub_bytes) = crate::export::generate_device_keypair();
        let priv_b64 = B64.encode(priv_bytes);
        let pub_b64 = B64.encode(pub_bytes);
        write_two_out_params(out_private_key, priv_b64, out_pubkey, pub_b64);
    })
}

/// Вывести публичный ключ устройства из base64-приватного ключа.
/// Возвращает base64-строку или NULL при ошибке. Освободить через paranoia_free_string.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_ecies_pubkey(private_key_b64: *const c_char) -> *mut c_char {
    ffi_catch_ptr("ecies_pubkey_error", || {
        clear_last_error();
        let priv_b64 = ffi_try!(cstr_arg(private_key_b64), invalid_argument_ptr());
        let Some(priv_bytes) = decode_b64_32_for_ffi(&priv_b64, "invalid_device_key") else {
            return std::ptr::null_mut();
        };
        let pub_bytes = crate::export::pubkey_from_private_key(&priv_bytes);
        string_to_c(B64.encode(pub_bytes))
    })
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
    ffi_catch_ptr("ecies_encrypt_error", || {
        clear_last_error();
        let pub_b64 = ffi_try!(cstr_arg(receiver_pubkey_b64), invalid_argument_ptr());
        let plaintext_str = ffi_try!(cstr_arg(plaintext), invalid_argument_ptr());
        let Some(pub_bytes) = decode_b64_32_for_ffi(&pub_b64, "invalid_device_key") else {
            return std::ptr::null_mut();
        };
        match crate::export::ecies_encrypt(&pub_bytes, plaintext_str.as_bytes()) {
            Ok(json) => string_to_c(json),
            Err(_) => {
                set_last_error("ecies_encrypt_error");
                std::ptr::null_mut()
            }
        }
    })
}

/// Расшифровать JSON-конверт EciesEnvelope приватным ключом устройства.
/// device_private_key_b64 — base64 X25519 приватный ключ (32 байта).
/// envelope_json — JSON-конверт, полученный от paranoia_ecies_encrypt.
/// Возвращает исходную UTF-8 строку (plaintext) или NULL при ошибке.
/// Освободить через paranoia_free_string.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_ecies_decrypt(
    device_private_key_b64: *const c_char,
    envelope_json: *const c_char,
) -> *mut c_char {
    ffi_catch_ptr("ecies_decrypt_error", || {
        clear_last_error();
        let priv_b64 = ffi_try!(cstr_arg(device_private_key_b64), invalid_argument_ptr());
        let envelope = ffi_try!(cstr_arg(envelope_json), invalid_argument_ptr());
        let Some(priv_bytes) = decode_b64_32_for_ffi(&priv_b64, "invalid_device_key") else {
            return std::ptr::null_mut();
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
    })
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
    CString::new(value)
        .map(CString::into_raw)
        .unwrap_or_else(|_| {
            set_last_error("invalid_string");
            std::ptr::null_mut()
        })
}

fn exchange_string_to_c(result: anyhow::Result<String>) -> *mut c_char {
    result.map(string_to_c).unwrap_or_else(|e| {
        set_last_error(&classify_exchange_error(&e.to_string()));
        std::ptr::null_mut()
    })
}

fn decode_b64_32(value: &str) -> anyhow::Result<[u8; 32]> {
    B64.decode(value)?
        .try_into()
        .map_err(|_| anyhow::anyhow!("invalid key length"))
}

fn decode_b64_32_for_ffi(value: &str, error: &str) -> Option<[u8; 32]> {
    decode_b64_32(value).map_err(|_| set_last_error(error)).ok()
}

fn with_keyring_dialogue<R: Copy>(
    handle: *mut ParanoiaHandle,
    user_a: *const c_char,
    user_b: *const c_char,
    keyring_json: *const c_char,
    invalid: R,
    f: impl FnOnce(&ParanoiaHandle, Dialogue) -> R,
) -> R {
    let h = ffi_try!(handle_ref(handle), invalid_argument_value(invalid));
    let a = ffi_try!(cstr_arg(user_a), invalid_argument_value(invalid));
    let b = ffi_try!(cstr_arg(user_b), invalid_argument_value(invalid));
    match dialogue_config_from_keyring_json(&a, &b, keyring_json) {
        Ok(cfg) => f(h, h.client.open_dialogue(cfg)),
        Err(e) => {
            set_last_error(&classify_keyring_error(&e.to_string()));
            invalid
        }
    }
}

fn invalid_argument_value<T>(value: T) -> T {
    set_last_error("invalid_argument");
    value
}

fn write_two_out_params(
    out_a: *mut *mut c_char,
    val_a: String,
    out_b: *mut *mut c_char,
    val_b: String,
) {
    if out_a.is_null() || out_b.is_null() {
        set_last_error("invalid_argument");
        return;
    }

    let c_a = string_to_c(val_a);
    let c_b = string_to_c(val_b);
    if c_a.is_null() || c_b.is_null() {
        if !c_a.is_null() {
            unsafe { drop(CString::from_raw(c_a)) };
        }
        if !c_b.is_null() {
            unsafe { drop(CString::from_raw(c_b)) };
        }
        return;
    }

    unsafe {
        *out_a = c_a;
        *out_b = c_b;
    }
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
        let key_bytes = B64.decode(entry.key)?;
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
    json_value_to_c_string(json)
}

fn message_to_c_string(msg: &Message) -> *mut c_char {
    let json = serde_json::json!([message_to_json(msg)]);
    json_value_to_c_string(json)
}

fn json_value_to_c_string(value: serde_json::Value) -> *mut c_char {
    match CString::new(value.to_string()) {
        Ok(value) => value.into_raw(),
        Err(_) => {
            set_last_error("json_error");
            std::ptr::null_mut()
        }
    }
}

fn message_to_json(m: &Message) -> serde_json::Value {
    let mut obj = serde_json::Map::new();
    obj.insert("id".into(), serde_json::json!(m.id));
    obj.insert("sender".into(), serde_json::json!(m.sender));
    obj.insert(
        "ts".into(),
        serde_json::json!(m.timestamp.timestamp_millis()),
    );
    obj.insert("seq".into(), serde_json::json!(m.server_seq));

    match &m.content {
        MessageContent::Text(text) => {
            obj.insert("kind".into(), serde_json::json!("text"));
            obj.insert("text".into(), serde_json::json!(text));
            obj.insert(
                "content".into(),
                serde_json::json!(format!("Text({text:?})")),
            );
        }
        MessageContent::File(file) | MessageContent::Image(file) | MessageContent::Voice(file) => {
            let kind = match &m.content {
                MessageContent::Image(_) => "image",
                MessageContent::Voice(_) => "voice",
                _ => "file",
            };
            obj.insert("kind".into(), serde_json::json!(kind));
            obj.insert("text".into(), serde_json::json!(file.filename));
            obj.insert("filename".into(), serde_json::json!(file.filename));
            obj.insert("mime_type".into(), serde_json::json!(file.mime_type));
            obj.insert("size".into(), serde_json::json!(file.size));
            obj.insert("downloadable".into(), serde_json::json!(true));
            obj.insert(
                "downloaded".into(),
                serde_json::json!(
                    file.downloaded
                        || !file.data.is_empty()
                        || file.cache_path.is_some()
                        || file.size == 0
                ),
            );
            obj.insert("transfer_id".into(), serde_json::json!(file.transfer_id));
            obj.insert("cache_path".into(), serde_json::json!(file.cache_path));
            obj.insert(
                "body_from_seq".into(),
                serde_json::json!(file.body_from_seq),
            );
            obj.insert("body_to_seq".into(), serde_json::json!(file.body_to_seq));
            obj.insert("content".into(), serde_json::json!("File(...)"));
        }
        MessageContent::FileHeader {
            filename,
            total_size,
            ..
        } => {
            obj.insert("kind".into(), serde_json::json!("file_header"));
            obj.insert("filename".into(), serde_json::json!(filename));
            obj.insert("size".into(), serde_json::json!(total_size));
            obj.insert("content".into(), serde_json::json!("FileHeader(...)"));
        }
        MessageContent::FileChunk {
            filename,
            total_size,
            ..
        } => {
            obj.insert("kind".into(), serde_json::json!("file_chunk"));
            obj.insert("filename".into(), serde_json::json!(filename));
            obj.insert("size".into(), serde_json::json!(total_size));
            obj.insert("content".into(), serde_json::json!("FileChunk(...)"));
        }
        MessageContent::ReadReceipt { .. } => {
            obj.insert("kind".into(), serde_json::json!("read_receipt"));
            obj.insert("content".into(), serde_json::json!("ReadReceipt(...)"));
        }
        MessageContent::Delete { .. } => {
            obj.insert("kind".into(), serde_json::json!("delete"));
            obj.insert("content".into(), serde_json::json!("Delete(...)"));
        }
    }

    serde_json::Value::Object(obj)
}
