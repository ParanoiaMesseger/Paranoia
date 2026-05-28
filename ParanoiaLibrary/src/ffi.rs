use base64::{Engine, engine::general_purpose::STANDARD as B64};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::cell::RefCell;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Arc;
use tokio::runtime::Runtime;

#[cfg(target_os = "android")]
unsafe extern "C" {
    #[link_name = "__android_log_write"]
    fn paranoia_android_log_print(prio: i32, tag: *const c_char, text: *const c_char) -> i32;
}

use crate::{
    ClientConfig, Dialogue, ParanoiaClient,
    error_classify::{
        classify_exchange_error, classify_keyring_error, classify_network_error,
        classify_send_error,
    },
    qr_exchange,
    types::DialogueKeyEntry,
    types::{DialogueConfig, DialogueKey, Message, MessageContent, MessageStatus},
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

pub(crate) fn set_last_error(msg: &str) {
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
        "arrived_error" => "arrived_panic",
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
    // Install a panic hook that forwards Rust panic messages to Android logcat
    // (under tag "ParanoiaService") so notify_panic / send_panic etc. don't
    // silently disappear into stderr.
    static PANIC_HOOK_INSTALLED: std::sync::Once = std::sync::Once::new();
    PANIC_HOOK_INSTALLED.call_once(|| {
        std::panic::set_hook(Box::new(|info| {
            let msg = format!("rust panic: {}", info);
            let tag = std::ffi::CString::new("ParanoiaService").unwrap();
            let cmsg = std::ffi::CString::new(msg)
                .unwrap_or_else(|_| std::ffi::CString::new("rust panic: <bad message>").unwrap());
            unsafe {
                // ANDROID_LOG_ERROR = 6
                paranoia_android_log_print(6, tag.as_ptr(), cmsg.as_ptr());
            }
        }));
    });
    ffi_catch_i32("android_init_error", || {
        clear_last_error();

        if raw_env.is_null() || raw_context.is_null() {
            return invalid_argument_i32();
        }

        let mut unowned = unsafe { jni::EnvUnowned::from_raw(raw_env as *mut jni::sys::JNIEnv) };
        match unowned
            .with_env(|env| -> jni::errors::Result<()> {
                let context = unsafe {
                    jni::objects::JObject::from_raw(env, raw_context as jni::sys::jobject)
                };

                rustls_platform_verifier::android::init_with_env(env, context)
            })
            .into_outcome()
        {
            jni::Outcome::Ok(()) => 0,
            jni::Outcome::Err(_) | jni::Outcome::Panic(_) => {
                set_last_error("android_init_error");
                -1
            }
        }
    })
}

// ── Хэндл клиента ────────────────────────────────────────────────────────────

/// Непрозрачный хэндл для C++
pub struct ParanoiaHandle {
    pub(crate) client: ParanoiaClient,
    pub(crate) rt: Runtime,
}

impl ParanoiaHandle {
    pub(crate) fn client(&self) -> &ParanoiaClient {
        &self.client
    }

    pub(crate) fn runtime(&self) -> &Runtime {
        &self.rt
    }
}

fn handle_ref<'a>(handle: *mut ParanoiaHandle) -> anyhow::Result<&'a ParanoiaHandle> {
    if handle.is_null() {
        anyhow::bail!("null handle");
    }
    Ok(unsafe { &*handle })
}

/// Создать клиента с резервными URL сервера.
/// reserve_server_urls_json — JSON-массив строк, например ["https://cdn.example.com"].
/// Можно передать NULL или пустую строку, если резервов нет.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_client_new(
    server_url: *const c_char,
    reserve_server_urls_json: *const c_char,
    username: *const c_char,
    signing_key_b64: *const c_char,
    db_path: *const c_char,
) -> *mut ParanoiaHandle {
    ffi_catch_value("client_init_error", std::ptr::null_mut(), || {
        clear_last_error();
        let server_url = ffi_try!(cstr_arg(server_url), invalid_argument_null());
        let reserve_server_urls = ffi_try!(
            reserve_server_urls_json_arg(reserve_server_urls_json),
            invalid_argument_null()
        );
        let username = ffi_try!(cstr_arg(username), invalid_argument_null());
        let sk_b64 = ffi_try!(cstr_arg(signing_key_b64), invalid_argument_null());
        let db_path = ffi_try!(cstr_arg(db_path), invalid_argument_null());

        client_handle_from_parts(server_url, reserve_server_urls, username, sk_b64, db_path)
    })
}

/// Проверить доступность резервного URL через /notify endpoint.
/// `url` — базовый URL сервера, БЕЗ хвостового `/notify`; путь добавит сам Transport.
/// Возвращает JSON {"ok": true} или {"ok": false, "error": "..."}.
/// NULL только при ошибке инициализации/панике. Освободить через paranoia_free_string.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_check_reserve_url(url: *const c_char) -> *mut c_char {
    ffi_catch_ptr("check_reserve_url_error", || {
        clear_last_error();
        let url_str = ffi_try!(cstr_arg(url), invalid_argument_ptr());
        if url_str.trim().is_empty() {
            set_last_error("invalid_url");
            return std::ptr::null_mut();
        }

        let rt = match Runtime::new() {
            Ok(rt) => rt,
            Err(_) => {
                set_last_error("runtime_error");
                return std::ptr::null_mut();
            }
        };

        let cover = Arc::new(crate::client_cover_food::FoodDeliveryClientCover::new());
        let transport =
            crate::transport::Transport::new(&url_str, std::iter::empty::<&str>(), cover);
        let core = crate::transport::CoreNotify {
            sender: "availability-check".to_string(),
            partner: "availability-check".to_string(),
            seq: 0,
            sig: vec![0u8; 64],
        };

        let json = match rt.block_on(transport.probe(&core)) {
            Ok(_) => serde_json::json!({ "ok": true }),
            Err(e) => serde_json::json!({ "ok": false, "error": anyhow_error_chain(&e) }),
        };
        string_to_c(json.to_string())
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

/// Зарегистрировать пользователя через основной URL с резервными путями доступа.
/// reserve_server_urls_json — JSON-массив строк, NULL/"" означает отсутствие резервов.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_register_user(
    server_url: *const c_char,
    reserve_server_urls_json: *const c_char,
    username: *const c_char,
    user_pubkey_b64: *const c_char,
    secret_b64: *const c_char,
) -> i32 {
    ffi_catch_i32("register_error", || {
        clear_last_error();
        let sk = ffi_try!(cstr_arg(secret_b64), invalid_argument_i32());
        let server_url = ffi_try!(cstr_arg(server_url), invalid_argument_i32());
        let reserve_server_urls = ffi_try!(
            reserve_server_urls_json_arg(reserve_server_urls_json),
            invalid_argument_i32()
        );
        let username = ffi_try!(cstr_arg(username), invalid_argument_i32());
        let pubkey = ffi_try!(cstr_arg(user_pubkey_b64), invalid_argument_i32());
        register_user_request(server_url, reserve_server_urls, username, pubkey, sk)
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

/// Отправить текстовый ответ на сообщение с локальным keyring JSON.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_send_text_reply_json_keyring(
    handle: *mut ParanoiaHandle,
    user_a: *const c_char,
    user_b: *const c_char,
    keyring_json: *const c_char,
    text: *const c_char,
    reply_to_id: *const c_char,
    reply_sender: *const c_char,
    reply_text: *const c_char,
) -> *mut c_char {
    ffi_catch_ptr("send_error", || {
        clear_last_error();
        let text = ffi_try!(cstr_arg(text), invalid_argument_ptr());
        let reply_to_id = ffi_try!(cstr_arg(reply_to_id), invalid_argument_ptr());
        let reply_sender = ffi_try!(cstr_arg(reply_sender), invalid_argument_ptr());
        let reply_text = ffi_try!(cstr_arg(reply_text), invalid_argument_ptr());
        with_keyring_dialogue(
            handle,
            user_a,
            user_b,
            keyring_json,
            std::ptr::null_mut(),
            |h, dialogue| match h.rt.block_on(dialogue.send_text_reply(
                text,
                reply_to_id,
                reply_sender,
                reply_text,
            )) {
                Ok(msg) => message_to_c_string(&msg),
                Err(e) => {
                    set_last_error(&classify_send_error(&anyhow_error_chain(&e)));
                    std::ptr::null_mut()
                }
            },
        )
    })
}

/// Отправить реакцию на сообщение с локальным keyring JSON.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_send_reaction_json_keyring(
    handle: *mut ParanoiaHandle,
    user_a: *const c_char,
    user_b: *const c_char,
    keyring_json: *const c_char,
    target_id: *const c_char,
    emoji: *const c_char,
) -> *mut c_char {
    ffi_catch_ptr("send_error", || {
        clear_last_error();
        let target_id = ffi_try!(cstr_arg(target_id), invalid_argument_ptr());
        let emoji = ffi_try!(cstr_arg(emoji), invalid_argument_ptr());
        with_keyring_dialogue(
            handle,
            user_a,
            user_b,
            keyring_json,
            std::ptr::null_mut(),
            |h, dialogue| match h.rt.block_on(dialogue.send_reaction(&target_id, &emoji)) {
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
    paranoia_send_file_json_keyring_with_progress(
        handle,
        user_a,
        user_b,
        keyring_json,
        file_path,
        mime_type,
        None,
        std::ptr::null_mut(),
    )
}

/// Тип callback'а для прогресса отправки файла. chunk_index — индекс уже
/// отосланного chunk'а (1-based), total — общее число chunk'ов. user_data —
/// opaque-указатель, переданный вызывающей стороной (например, id transfer'а
/// или this-pointer).
pub type ProgressCallback =
    extern "C" fn(chunk_index: u32, total: u32, user_data: *mut std::ffi::c_void);

/// То же, что paranoia_send_file_json_keyring, но дополнительно дёргает
/// `progress` (если задан) после успешной отправки каждого chunk'а. callback
/// гарантированно вызывается из runtime-потока FFI; вызывающая сторона должна
/// маршалить результат обратно в свой UI-thread.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_send_file_json_keyring_with_progress(
    handle: *mut ParanoiaHandle,
    user_a: *const c_char,
    user_b: *const c_char,
    keyring_json: *const c_char,
    file_path: *const c_char,
    mime_type: *const c_char,
    progress: Option<ProgressCallback>,
    user_data: *mut std::ffi::c_void,
) -> *mut c_char {
    // user_data приходит как *mut c_void, но захватывать его в FnMut напрямую
    // не получается (raw-указатели не Send). Пакуем в usize.
    let user_data_addr = user_data as usize;
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

        let on_progress = move |chunk_index: u32, total: u32| {
            if let Some(cb) = progress {
                cb(chunk_index, total, user_data_addr as *mut std::ffi::c_void);
            }
        };

        with_keyring_dialogue(
            handle,
            user_a,
            user_b,
            keyring_json,
            std::ptr::null_mut(),
            |h, dialogue| match h.rt.block_on(dialogue.send_file_path_with_progress(
                filename,
                mime_type,
                std::path::Path::new(&path),
                on_progress,
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

/// Обновить локальные READ-статусы через GET /arrived.
/// Возвращает 0 при успехе и пишет количество изменённых локальных сообщений в out_changed.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_arrived_get_keyring(
    handle: *mut ParanoiaHandle,
    user_a: *const c_char,
    user_b: *const c_char,
    keyring_json: *const c_char,
    out_changed: *mut u64,
) -> i32 {
    ffi_catch_i32("arrived_error", || {
        clear_last_error();
        if out_changed.is_null() {
            return invalid_argument_i32();
        }
        with_keyring_dialogue(
            handle,
            user_a,
            user_b,
            keyring_json,
            -1,
            |h, dialogue| match h.rt.block_on(dialogue.refresh_arrived_status()) {
                Ok(count) => {
                    unsafe { *out_changed = count as u64 };
                    0
                }
                Err(e) => {
                    set_last_error(&classify_network_error(
                        &anyhow_error_chain(&e),
                        "arrived_error",
                    ));
                    -1
                }
            },
        )
    })
}

/// Включить/выключить read receipts для диалога через PUT /arrived.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_arrived_put_keyring(
    handle: *mut ParanoiaHandle,
    user_a: *const c_char,
    user_b: *const c_char,
    keyring_json: *const c_char,
    receipts_enabled: i32,
) -> i32 {
    ffi_catch_i32("arrived_error", || {
        clear_last_error();
        with_keyring_dialogue(
            handle,
            user_a,
            user_b,
            keyring_json,
            -1,
            |h, dialogue| match h
                .rt
                .block_on(dialogue.set_receipts_enabled(receipts_enabled != 0))
            {
                Ok(()) => 0,
                Err(e) => {
                    set_last_error(&classify_network_error(
                        &anyhow_error_chain(&e),
                        "arrived_error",
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
pub extern "C" fn paranoia_cache_attachment_bytes_keyring(
    handle: *mut ParanoiaHandle,
    user_a: *const c_char,
    user_b: *const c_char,
    keyring_json: *const c_char,
    message_id: *const c_char,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    ffi_catch_i32("attachment_error", || {
        clear_last_error();
        if out_ptr.is_null() || out_len.is_null() {
            return invalid_argument_i32();
        }
        unsafe {
            *out_ptr = std::ptr::null_mut();
            *out_len = 0;
        }
        let message_id = ffi_try!(cstr_arg(message_id), invalid_argument_i32());
        with_keyring_dialogue(
            handle,
            user_a,
            user_b,
            keyring_json,
            -1,
            |h, dialogue| match h.rt.block_on(dialogue.cache_attachment_bytes(&message_id)) {
                Ok(bytes) => {
                    // Vec<u8> → Box<[u8]>: into_boxed_slice гарантирует cap == len.
                    // Освобождать через paranoia_free_buffer (Box::from_raw).
                    let boxed: Box<[u8]> = bytes.into_boxed_slice();
                    let len = boxed.len();
                    let raw: *mut [u8] = Box::into_raw(boxed);
                    let ptr = raw as *mut u8;
                    unsafe {
                        *out_ptr = ptr;
                        *out_len = len;
                    }
                    0
                }
                Err(e) => {
                    set_last_error(&anyhow_error_chain(&e));
                    -1
                }
            },
        )
    })
}

/// Освободить буфер, возвращённый из FFI (например, через
/// paranoia_cache_attachment_bytes_keyring). Безопасно при ptr == NULL.
/// len ОБЯЗАН совпадать с тем, что было возвращено в out_len.
/// Реконструируем Box<[u8]> — cap == len гарантирован (в отличие от Vec).
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_free_buffer(ptr: *mut u8, len: usize) {
    if ptr.is_null() || len == 0 {
        return;
    }
    unsafe {
        let slice: *mut [u8] = std::slice::from_raw_parts_mut(ptr, len);
        let _ = Box::from_raw(slice);
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

/// Удалить пакеты на сервере в диапазоне `[from_seq, to_seq]` (включительно).
/// `from_seq == 0` означает «с начала диалога».
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_remove_server_range_keyring(
    handle: *mut ParanoiaHandle,
    user_a: *const c_char,
    user_b: *const c_char,
    keyring_json: *const c_char,
    from_seq: u64,
    to_seq: u64,
) -> i32 {
    ffi_catch_i32("determinate_error", || {
        clear_last_error();
        with_keyring_dialogue(
            handle,
            user_a,
            user_b,
            keyring_json,
            -1,
            |h, dialogue| match h
                .rt
                .block_on(dialogue.remove_server_range(from_seq, to_seq))
            {
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

/// Удалить пакеты диалога в диапазоне `[from_seq, to_seq]` (включительно)
/// одновременно на сервере и в локальной БД. `from_seq == 0` означает «с
/// начала диалога».
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_delete_dialogue_range_keyring(
    handle: *mut ParanoiaHandle,
    user_a: *const c_char,
    user_b: *const c_char,
    keyring_json: *const c_char,
    from_seq: u64,
    to_seq: u64,
) -> i32 {
    ffi_catch_i32("determinate_error", || {
        clear_last_error();
        with_keyring_dialogue(
            handle,
            user_a,
            user_b,
            keyring_json,
            -1,
            |h, dialogue| {
                if let Err(e) = h
                    .rt
                    .block_on(dialogue.remove_server_range(from_seq, to_seq))
                {
                    set_last_error(&classify_network_error(
                        &anyhow_error_chain(&e),
                        "determinate_error",
                    ));
                    return -1;
                }
                if let Err(e) = dialogue.delete_local_range(from_seq, to_seq) {
                    set_last_error(&anyhow_error_chain(&e));
                    return -1;
                }
                0
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

fn reserve_server_urls_json_arg(ptr: *const c_char) -> anyhow::Result<Vec<String>> {
    if ptr.is_null() {
        return Ok(Vec::new());
    }
    let value = cstr_arg(ptr)?;
    if value.trim().is_empty() {
        return Ok(Vec::new());
    }
    serde_json::from_str(&value).map_err(Into::into)
}

fn client_handle_from_parts(
    server_url: String,
    reserve_server_urls: Vec<String>,
    username: String,
    sk_b64: String,
    db_path: String,
) -> *mut ParanoiaHandle {
    let signing_key = match decode_b64_32(&sk_b64) {
        Ok(sk) => ed25519_dalek::SigningKey::from_bytes(&sk),
        _ => {
            set_last_error("invalid_signing_key: expected 32 bytes base64");
            return std::ptr::null_mut();
        }
    };

    let cfg = ClientConfig {
        server_url,
        reserve_server_urls,
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
}

fn register_user_request(
    server_url: String,
    reserve_server_urls: Vec<String>,
    username: String,
    pubkey: String,
    sk: String,
) -> i32 {
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
    let transport = crate::transport::Transport::new(
        &server_url,
        reserve_server_urls.iter().map(String::as_str),
        cover,
    );
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
}

pub(crate) fn string_to_c(value: String) -> *mut c_char {
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
        "status".into(),
        serde_json::json!(message_status_label(&m.status)),
    );
    obj.insert(
        "ts".into(),
        serde_json::json!(m.timestamp.timestamp_millis()),
    );
    obj.insert("seq".into(), serde_json::json!(m.server_seq));

    match &m.content {
        MessageContent::Text(text) => {
            obj.insert("kind".into(), serde_json::json!("text"));
            obj.insert("text".into(), serde_json::json!(text));
        }
        MessageContent::TextReply {
            text,
            reply_to_id,
            reply_sender,
            reply_text,
        } => {
            obj.insert("kind".into(), serde_json::json!("text"));
            obj.insert("text".into(), serde_json::json!(text));
            obj.insert("reply_to_id".into(), serde_json::json!(reply_to_id));
            obj.insert("reply_sender".into(), serde_json::json!(reply_sender));
            obj.insert("reply_text".into(), serde_json::json!(reply_text));
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
        }
        MessageContent::FileHeader {
            filename,
            total_size,
            ..
        } => {
            obj.insert("kind".into(), serde_json::json!("file_header"));
            obj.insert("filename".into(), serde_json::json!(filename));
            obj.insert("size".into(), serde_json::json!(total_size));
        }
        MessageContent::FileChunk {
            filename,
            total_size,
            ..
        } => {
            obj.insert("kind".into(), serde_json::json!("file_chunk"));
            obj.insert("filename".into(), serde_json::json!(filename));
            obj.insert("size".into(), serde_json::json!(total_size));
        }
        MessageContent::ReadReceipt { .. } => {
            obj.insert("kind".into(), serde_json::json!("read_receipt"));
        }
        MessageContent::Delete { .. } => {
            obj.insert("kind".into(), serde_json::json!("delete"));
        }
        MessageContent::Reaction { target_id, emoji } => {
            obj.insert("kind".into(), serde_json::json!("reaction"));
            obj.insert("target_id".into(), serde_json::json!(target_id));
            obj.insert("emoji".into(), serde_json::json!(emoji));
        }
    }

    serde_json::Value::Object(obj)
}

fn message_status_label(status: &MessageStatus) -> &'static str {
    match status {
        MessageStatus::Sending | MessageStatus::Sent => "pending",
        MessageStatus::Delivered => "delivered",
        MessageStatus::Read => "read",
        MessageStatus::Failed => "failed",
    }
}

// ── Local Vault (LocalStorageEncryptionPolicy.md) ────────────────────────────

/// Установить корень app data, в котором хранится `vault.json` и весь профильный
/// контент. Вызывать на старте приложения ДО любых других vault-функций.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_vault_init(app_data_root: *const c_char) -> i32 {
    ffi_catch_i32("vault_init_error", || {
        clear_last_error();
        let root = ffi_try!(cstr_arg(app_data_root), invalid_argument_i32());
        crate::local_vault::vault::set_app_data_root(std::path::PathBuf::from(root));
        // Прерванный rekey оставляет .rekey-staging/ — восстанавливаем
        // ДО любых попыток разблокировать vault. Если recovery упадёт —
        // ловим, но не разваливаем init (UI всё равно покажет SetPin / Unlock,
        // а сама ошибка попадёт в last_error для логов).
        if let Err(e) = crate::local_vault::recover_pending_rekey() {
            set_last_error(&format!("vault_recover_pending_rekey: {e}"));
        }
        0
    })
}

/// Узнать состояние vault: 0=not_initialized, 1=locked, 2=unlocked, -1=ошибка.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_vault_status() -> i32 {
    ffi_catch_i32("vault_status_error", || {
        clear_last_error();
        match crate::local_vault::status() {
            Ok(s) => s as i32,
            Err(e) => {
                set_last_error(&anyhow_error_chain(&e));
                -1
            }
        }
    })
}

/// Установить PIN впервые. 0=ok, 1=already_initialized, -1=internal.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_vault_set_pin(pin: *const c_char) -> i32 {
    ffi_catch_i32("vault_set_pin_error", || {
        clear_last_error();
        let pin = ffi_try!(cstr_arg(pin), invalid_argument_i32());
        match crate::local_vault::set_pin(&pin) {
            Ok(()) => 0,
            Err(e) => {
                let msg = anyhow_error_chain(&e);
                set_last_error(&msg);
                if msg.contains("already initialized") {
                    1
                } else {
                    -1
                }
            }
        }
    })
}

/// Разблокировать. Коды: 0=ok, 1=wrong_pin, 2=locked_out, 3=not_initialized, -1=internal.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_vault_unlock(pin: *const c_char) -> i32 {
    ffi_catch_i32("vault_unlock_error", || {
        clear_last_error();
        let pin = ffi_try!(cstr_arg(pin), invalid_argument_i32());
        match crate::local_vault::unlock(&pin) {
            Ok(()) => 0,
            Err(e) => {
                let msg = anyhow_error_chain(&e);
                set_last_error(&msg);
                if msg.contains("wrong_pin") {
                    1
                } else if msg.contains("locked_out") {
                    2
                } else if msg.contains("not_initialized") {
                    3
                } else {
                    -1
                }
            }
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn paranoia_vault_lock() -> i32 {
    ffi_catch_i32("vault_lock_error", || {
        clear_last_error();
        crate::local_vault::lock();
        0
    })
}

/// Проверить PIN без замены активных ключей. 0=ok, 1=wrong_pin, 3=not_init, -1=internal.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_vault_verify_pin(pin: *const c_char) -> i32 {
    ffi_catch_i32("vault_verify_pin_error", || {
        clear_last_error();
        let pin = ffi_try!(cstr_arg(pin), invalid_argument_i32());
        match crate::local_vault::verify_pin(&pin) {
            Ok(()) => 0,
            Err(e) => {
                let msg = anyhow_error_chain(&e);
                set_last_error(&msg);
                if msg.contains("wrong_pin") {
                    1
                } else if msg.contains("not_initialized") {
                    3
                } else {
                    -1
                }
            }
        }
    })
}

/// Шаг 1 rekey: подготовить новые ключи. Vault остаётся unlocked со старыми.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_vault_rekey_begin(new_pin: *const c_char) -> i32 {
    ffi_catch_i32("vault_rekey_begin_error", || {
        clear_last_error();
        let pin = ffi_try!(cstr_arg(new_pin), invalid_argument_i32());
        match crate::local_vault::rekey_begin(&pin) {
            Ok(()) => 0,
            Err(e) => {
                set_last_error(&anyhow_error_chain(&e));
                -1
            }
        }
    })
}

/// Шаг 2 rekey: перешифровать один JSON-файл (decrypt активным, encrypt pending).
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_vault_rekey_file(path: *const c_char) -> i32 {
    ffi_catch_i32("vault_rekey_file_error", || {
        clear_last_error();
        let path = ffi_try!(cstr_arg(path), invalid_argument_i32());
        match crate::local_vault::rekey_file(std::path::Path::new(&path)) {
            Ok(()) => 0,
            Err(e) => {
                set_last_error(&anyhow_error_chain(&e));
                -1
            }
        }
    })
}

/// Шаг 2 rekey (attachment): decrypt активным per-file key, encrypt pending.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_vault_rekey_attachment(
    salt_str: *const c_char,
    path: *const c_char,
) -> i32 {
    ffi_catch_i32("vault_rekey_attachment_error", || {
        clear_last_error();
        let salt = ffi_try!(cstr_arg(salt_str), invalid_argument_i32());
        let path = ffi_try!(cstr_arg(path), invalid_argument_i32());
        match crate::local_vault::rekey_attachment(salt.as_bytes(), std::path::Path::new(&path)) {
            Ok(()) => 0,
            Err(e) => {
                set_last_error(&anyhow_error_chain(&e));
                -1
            }
        }
    })
}

/// Шаг 2 rekey (БД): SQLCipher PRAGMA rekey со старого db_key на pending.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_vault_rekey_db(db_path: *const c_char) -> i32 {
    ffi_catch_i32("vault_rekey_db_error", || {
        clear_last_error();
        let path = ffi_try!(cstr_arg(db_path), invalid_argument_i32());
        match crate::local_vault::rekey_db(std::path::Path::new(&path)) {
            Ok(()) => 0,
            Err(e) => {
                set_last_error(&anyhow_error_chain(&e));
                -1
            }
        }
    })
}

/// Шаг 3 rekey: записать новый VaultState и свапнуть активные ключи на pending.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_vault_rekey_commit() -> i32 {
    ffi_catch_i32("vault_rekey_commit_error", || {
        clear_last_error();
        match crate::local_vault::rekey_commit() {
            Ok(()) => 0,
            Err(e) => {
                set_last_error(&anyhow_error_chain(&e));
                -1
            }
        }
    })
}

/// Откатить незавершённый rekey: освободить pending-ключи. Уже
/// перешифрованные файлы/БД не откатываются.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_vault_rekey_abort() -> i32 {
    ffi_catch_i32("vault_rekey_abort_error", || {
        clear_last_error();
        crate::local_vault::rekey_abort();
        0
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn paranoia_vault_lockout_seconds(out_secs: *mut u64) -> i32 {
    ffi_catch_i32("vault_lockout_error", || {
        clear_last_error();
        if out_secs.is_null() {
            return invalid_argument_i32();
        }
        match crate::local_vault::lockout_remaining_secs() {
            Ok(secs) => {
                unsafe { *out_secs = secs };
                0
            }
            Err(e) => {
                set_last_error(&anyhow_error_chain(&e));
                -1
            }
        }
    })
}

/// Зашифровать `data` (len байт) json_key'ом и атомарно записать в `path`.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_vault_encrypt_json(
    path: *const c_char,
    data: *const u8,
    len: usize,
) -> i32 {
    ffi_catch_i32("vault_encrypt_json_error", || {
        clear_last_error();
        let path = ffi_try!(cstr_arg(path), invalid_argument_i32());
        if data.is_null() && len != 0 {
            return invalid_argument_i32();
        }
        let slice = if len == 0 {
            &[][..]
        } else {
            unsafe { std::slice::from_raw_parts(data, len) }
        };
        match crate::local_vault::encrypt_json_to_disk(std::path::Path::new(&path), slice) {
            Ok(()) => 0,
            Err(e) => {
                set_last_error(&anyhow_error_chain(&e));
                -1
            }
        }
    })
}

/// Прочитать зашифрованный файл и вернуть расшифрованный JSON как C-string
/// (UTF-8, без \0 в payload'е). Освободить через `paranoia_free_string`.
/// NULL при ошибке.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_vault_decrypt_json(path: *const c_char) -> *mut c_char {
    ffi_catch_ptr("vault_decrypt_json_error", || {
        clear_last_error();
        let path = ffi_try!(cstr_arg(path), invalid_argument_ptr());
        match crate::local_vault::decrypt_json_from_disk(std::path::Path::new(&path)) {
            Ok(bytes) => match CString::new(bytes) {
                Ok(c) => c.into_raw(),
                Err(_) => {
                    set_last_error("vault_decrypt_json: nul byte in payload");
                    std::ptr::null_mut()
                }
            },
            Err(e) => {
                set_last_error(&anyhow_error_chain(&e));
                std::ptr::null_mut()
            }
        }
    })
}

/// Зашифровать файл-attachment на per-file ключе HKDF(files_key, salt_str, "attachment-v1").
/// Читает `src_path`, пишет результат атомарно в `dst_path`.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_vault_encrypt_attachment(
    salt_str: *const c_char,
    src_path: *const c_char,
    dst_path: *const c_char,
) -> i32 {
    ffi_catch_i32("vault_attach_encrypt_error", || {
        clear_last_error();
        let salt = ffi_try!(cstr_arg(salt_str), invalid_argument_i32());
        let src = ffi_try!(cstr_arg(src_path), invalid_argument_i32());
        let dst = ffi_try!(cstr_arg(dst_path), invalid_argument_i32());
        let plaintext = match std::fs::read(&src) {
            Ok(b) => b,
            Err(e) => {
                set_last_error(&format!("read {src}: {e}"));
                return -1;
            }
        };
        match crate::local_vault::encrypt_attachment(salt.as_bytes(), &plaintext) {
            Ok(sealed) => {
                if let Err(e) = atomic_write_bytes(&dst, &sealed) {
                    set_last_error(&anyhow_error_chain(&e));
                    return -1;
                }
                0
            }
            Err(e) => {
                set_last_error(&anyhow_error_chain(&e));
                -1
            }
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn paranoia_vault_decrypt_attachment(
    salt_str: *const c_char,
    src_path: *const c_char,
    dst_path: *const c_char,
) -> i32 {
    ffi_catch_i32("vault_attach_decrypt_error", || {
        clear_last_error();
        let salt = ffi_try!(cstr_arg(salt_str), invalid_argument_i32());
        let src = ffi_try!(cstr_arg(src_path), invalid_argument_i32());
        let dst = ffi_try!(cstr_arg(dst_path), invalid_argument_i32());
        let sealed = match std::fs::read(&src) {
            Ok(b) => b,
            Err(e) => {
                set_last_error(&format!("read {src}: {e}"));
                return -1;
            }
        };
        match crate::local_vault::decrypt_attachment(salt.as_bytes(), &sealed) {
            Ok(plaintext) => {
                if let Err(e) = atomic_write_bytes(&dst, &plaintext) {
                    set_last_error(&anyhow_error_chain(&e));
                    return -1;
                }
                0
            }
            Err(e) => {
                set_last_error(&anyhow_error_chain(&e));
                -1
            }
        }
    })
}

fn atomic_write_bytes(path: &str, bytes: &[u8]) -> anyhow::Result<()> {
    let p = std::path::Path::new(path);
    if let Some(parent) = p.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let tmp = match p.file_name() {
        Some(name) => p.with_file_name(format!("{}.tmp", name.to_string_lossy())),
        None => anyhow::bail!("invalid path: {path}"),
    };
    std::fs::write(&tmp, bytes)?;
    std::fs::rename(&tmp, p)?;
    Ok(())
}
