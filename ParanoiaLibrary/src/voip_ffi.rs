//! C-FFI для VoIP: сигналинг и UDP-сессия.
//!
//! Стиль API совместим с уже существующим `ffi.rs` (см. `paranoia_lib.h`):
//! - функции `extern "C"`, опасные операции в `unsafe`;
//! - возвращаемые строки нужно освобождать через `paranoia_free_string`;
//! - детали ошибок доступны через `paranoia_last_error()`;
//! - сессия — opaque-указатель `*mut ParanoiaCallSession`, владелец освобождает
//!   через `paranoia_call_session_stop`.

use std::ffi::{CStr, CString};
use std::net::{IpAddr, SocketAddr, ToSocketAddrs};
use std::os::raw::c_char;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

use base64::{Engine, engine::general_purpose::STANDARD as B64};
use serde::Deserialize;
use tokio::net::UdpSocket;
use tokio::runtime::Runtime;

use crate::ParanoiaClient;
use crate::transport::{CallEnvelopeIn, CoreCallPoll, CoreCallSignal};
use crate::voip::crypto::{Role, StreamKeys};
use crate::voip::signaling::{CallSignalKind, open as signaling_open, seal as signaling_seal};
use crate::voip::stun::discover_reflexive;
use crate::voip::transport::{SessionParams, VideoOutboundPacket, spawn_session};

/// Создать UdpSocket для VoIP сессии. Если `bind_addr` это IPv4-wildcard
/// (`0.0.0.0:port`), биндим вместо него IPv6 dual-stack (`[::]:port` с
/// `IPV6_V6ONLY=false`). Тогда сокет:
///   • слушает на обоих стэках одновременно;
///   • может слать `send_to` и на IPv4-адреса, и на IPv6 (в т. ч. NAT64-
///     синтезированные `64:ff9b::/96` маппинги, которые отдаёт DNS64 у мобильных
///     операторов с IPv6-only сетью).
/// Без этого LTE-устройства, где `getaddrinfo("paranoia.example.com")` возвращает
/// только AAAA → `[64:ff9b::5d64:cf97]`, фейлятся с EAFNOSUPPORT на любой
/// `send_to` через IPv4-сокет — STUN/TURN не запускаются вообще.
fn bind_call_socket(bind_addr: SocketAddr) -> std::io::Result<UdpSocket> {
    let need_dualstack = matches!(bind_addr.ip(), IpAddr::V4(v4) if v4.is_unspecified());
    if !need_dualstack {
        return std::net::UdpSocket::bind(bind_addr)
            .and_then(|s| {
                s.set_nonblocking(true)?;
                Ok(s)
            })
            .and_then(UdpSocket::from_std);
    }
    let v6_bind = SocketAddr::new(IpAddr::V6(std::net::Ipv6Addr::UNSPECIFIED), bind_addr.port());
    let sock = socket2::Socket::new(
        socket2::Domain::IPV6,
        socket2::Type::DGRAM,
        Some(socket2::Protocol::UDP),
    )?;
    // Главное: разрешить v4-mapped адреса через тот же сокет.
    sock.set_only_v6(false)?;
    sock.set_nonblocking(true)?;
    sock.bind(&v6_bind.into())?;
    let std_sock: std::net::UdpSocket = sock.into();
    UdpSocket::from_std(std_sock)
}

// Эти символы определены в `ffi.rs`. Чтобы не дублировать их thread_local
// хранилище ошибки, дёргаем уже имеющийся `paranoia_last_error`-инфраструктура
// через приватные helper'ы в `ffi.rs` нам недоступна — поэтому продублируем
// тонкий слой error-state локально. На практике это не страшно: пользователь
// FFI всё равно зовёт `paranoia_last_error()` ровно сразу после операции, и
// эта функция читает `LAST_ERROR` именно из `ffi.rs`. Чтобы видеть ошибки
// из voip-вызовов через тот же интерфейс, *настоящая* запись делается через
// функцию `set_last_error` из `ffi.rs` — но она не публичная.
//
// Решение: импортируем приватный helper через супер-модуль. Это валидно,
// потому что `voip_ffi` лежит в том же крейте.

use crate::ffi::{set_last_error, string_to_c};

/// Единый Tokio-runtime для всех VoIP-сессий процесса. Раньше каждая сессия
/// поднимала свой `Runtime::new()`, что давало 4..N worker-потоков на каждый
/// звонок — расточительно на мобильных. Теперь сессии переиспользуют один
/// общий runtime, инициализируемый лениво при первом старте сессии и живущий
/// до выхода процесса. На завершение звонка runtime НЕ дропается, только
/// останавливается соответствующий task — это убирает блокирующий
/// `Runtime::drop` (synchronous join всех threads) из `paranoia_call_session_stop`.
static VOIP_RUNTIME: OnceLock<Arc<tokio::runtime::Runtime>> = OnceLock::new();

fn voip_runtime() -> Option<Arc<tokio::runtime::Runtime>> {
    // get_or_try_init не стабилизирован в OnceLock; делаем вручную.
    if let Some(rt) = VOIP_RUNTIME.get() {
        return Some(Arc::clone(rt));
    }
    let rt = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .thread_name("paranoia-voip")
        .build()
    {
        Ok(r) => Arc::new(r),
        Err(_) => return None,
    };
    // race-friendly: если кто-то параллельно инициализировал, set() вернёт Err,
    // и мы используем уже сохранённый. Дополнительный `rt` будет дропнут.
    match VOIP_RUNTIME.set(rt) {
        Ok(()) => VOIP_RUNTIME.get().cloned(),
        Err(_) => VOIP_RUNTIME.get().cloned(),
    }
}

// ── Хелперы ────────────────────────────────────────────────────────────

fn ffi_catch_i32<F: FnOnce() -> i32>(fallback: &str, f: F) -> i32 {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(v) => v,
        Err(_) => {
            set_last_error(fallback);
            -1
        }
    }
}

fn ffi_catch_ptr<F: FnOnce() -> *mut c_char>(fallback: &str, f: F) -> *mut c_char {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(v) => v,
        Err(_) => {
            set_last_error(fallback);
            ptr::null_mut()
        }
    }
}

unsafe fn cstr(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    let s = unsafe { CStr::from_ptr(ptr) };
    s.to_str().ok().map(str::to_owned)
}

fn decode_b64_32(s: &str) -> Option<[u8; 32]> {
    let v = B64.decode(s).ok()?;
    v.try_into().ok()
}

fn decode_b64_16(s: &str) -> Option<[u8; 16]> {
    let v = B64.decode(s).ok()?;
    v.try_into().ok()
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

unsafe fn client_ref<'a>(handle: *mut crate::ffi::ParanoiaHandle) -> Option<&'a ParanoiaClient> {
    if handle.is_null() {
        return None;
    }
    let h = unsafe { &*handle };
    Some(h.client())
}

unsafe fn runtime_ref<'a>(handle: *mut crate::ffi::ParanoiaHandle) -> Option<&'a Runtime> {
    if handle.is_null() {
        return None;
    }
    let h = unsafe { &*handle };
    Some(h.runtime())
}

// ── /call/signal ───────────────────────────────────────────────────────

/// Отправить один сигнальный конверт.
///
/// - `from_user`, `to_user`: отправитель/получатель (зарегистрированные на сервере)
/// - `master_key_b64`: dialog master key (32 байта base64) — им шифруется payload
/// - `kind`: `0=Offer, 1=Answer, 2=Hangup, 3=Ice`
/// - `payload_json`: JSON-тело соответствующей структуры (см. voip::signaling)
///
/// Возвращает 0 при успехе, -1 при ошибке (см. `paranoia_last_error`).
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_call_signal_send(
    handle: *mut crate::ffi::ParanoiaHandle,
    from_user: *const c_char,
    to_user: *const c_char,
    master_key_b64: *const c_char,
    kind: u8,
    payload_json: *const c_char,
) -> i32 {
    ffi_catch_i32("call_signal_panic", || {
        let from = match unsafe { cstr(from_user) } {
            Some(s) if !s.is_empty() => s,
            _ => {
                set_last_error("invalid_from_user");
                return -1;
            }
        };
        let to = match unsafe { cstr(to_user) } {
            Some(s) if !s.is_empty() => s,
            _ => {
                set_last_error("invalid_to_user");
                return -1;
            }
        };
        let key = match unsafe { cstr(master_key_b64) }
            .as_deref()
            .and_then(decode_b64_32)
        {
            Some(k) => k,
            None => {
                set_last_error("invalid_master_key");
                return -1;
            }
        };
        if CallSignalKind::from_byte(kind).is_none() {
            set_last_error("invalid_signal_kind");
            return -1;
        }
        let payload = match unsafe { cstr(payload_json) } {
            Some(s) => s,
            None => {
                set_last_error("invalid_payload");
                return -1;
            }
        };
        let client = match unsafe { client_ref(handle) } {
            Some(c) => c,
            None => {
                set_last_error("invalid_handle");
                return -1;
            }
        };
        let rt = match unsafe { runtime_ref(handle) } {
            Some(r) => r,
            None => {
                set_last_error("invalid_handle");
                return -1;
            }
        };

        // Запечатать payload dialog master key'ом.
        let sealed = match signaling_seal(&key, payload.as_bytes()) {
            Ok(v) => v,
            Err(_) => {
                set_last_error("signaling_seal_failed");
                return -1;
            }
        };
        let payload_b64 = B64.encode(&sealed);
        let ts_ms = now_ms();

        // Подпись соответствует серверной проверке: sender+recver+kind+ts_ms+payload_b64.
        let signed = format!("{from}{to}{kind}{ts_ms}{payload_b64}");
        let sig = crate::crypto::sign(&client.config().signing_key, signed.as_bytes());

        let core = CoreCallSignal {
            sender: from,
            recver: to,
            kind,
            payload: sealed,
            ts_ms,
            sig,
        };

        match rt.block_on(client.transport().call_signal(&core)) {
            Ok(()) => 0,
            Err(e) => {
                set_last_error(&format!("call_signal_failed: {e}"));
                -1
            }
        }
    })
}

/// Тип callback'а для async-варианта `paranoia_call_signal_send`.
/// `status == 0` — успех, `status != 0` — ошибка; `error_message` валиден
/// только во время вызова, после возврата указатель использовать нельзя
/// (caller обязан скопировать строку при необходимости). Callback вызывается
/// из фонового tokio-потока — caller обязан переключиться на свой поток сам.
pub type ParanoiaCallSignalCb =
    extern "C" fn(userdata: *mut std::ffi::c_void, status: i32, error_message: *const c_char);

/// Асинхронный вариант [`paranoia_call_signal_send`]: сразу возвращает
/// управление, фактическая HTTP-отправка выполняется в tokio-runtime, по
/// завершении вызывается `cb(userdata, status, err_msg)`.
///
/// Параметры идентичны синхронному варианту, добавлены только `cb` и `userdata`.
/// `cb` может быть NULL — тогда результат отправки никому не сообщается
/// (fire-and-forget).
///
/// Возвращает 0 если задача поставлена в очередь, -1 если входы невалидны
/// (например, handle null) или произошёл panic при подготовке.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_call_signal_send_async(
    handle: *mut crate::ffi::ParanoiaHandle,
    from_user: *const c_char,
    to_user: *const c_char,
    master_key_b64: *const c_char,
    kind: u8,
    payload_json: *const c_char,
    cb: Option<ParanoiaCallSignalCb>,
    userdata: *mut std::ffi::c_void,
) -> i32 {
    // Захват входов в данные, которые можно безопасно перенести в задачу.
    // ParanoiaHandle, к сожалению, нельзя просто переместить — handle живёт у
    // вызывающего. Поэтому работаем по сырому указателю, но только пока он
    // валиден; вызывающий обязан не освобождать handle до завершения cb.
    let userdata_addr = userdata as usize; // *mut c_void — не Send, оборачиваем как usize.
    ffi_catch_i32("call_signal_async_panic", || {
        let from = match unsafe { cstr(from_user) } {
            Some(s) if !s.is_empty() => s,
            _ => {
                set_last_error("invalid_from_user");
                return -1;
            }
        };
        let to = match unsafe { cstr(to_user) } {
            Some(s) if !s.is_empty() => s,
            _ => {
                set_last_error("invalid_to_user");
                return -1;
            }
        };
        let key = match unsafe { cstr(master_key_b64) }
            .as_deref()
            .and_then(decode_b64_32)
        {
            Some(k) => k,
            None => {
                set_last_error("invalid_master_key");
                return -1;
            }
        };
        if CallSignalKind::from_byte(kind).is_none() {
            set_last_error("invalid_signal_kind");
            return -1;
        }
        let payload = match unsafe { cstr(payload_json) } {
            Some(s) => s,
            None => {
                set_last_error("invalid_payload");
                return -1;
            }
        };
        let client = match unsafe { client_ref(handle) } {
            Some(c) => c,
            None => {
                set_last_error("invalid_handle");
                return -1;
            }
        };
        let rt = match unsafe { runtime_ref(handle) } {
            Some(r) => r,
            None => {
                set_last_error("invalid_handle");
                return -1;
            }
        };

        // Запечатываем и подписываем СИНХРОННО (это быстро), сетевой вызов идёт async.
        let sealed = match signaling_seal(&key, payload.as_bytes()) {
            Ok(v) => v,
            Err(_) => {
                set_last_error("signaling_seal_failed");
                return -1;
            }
        };
        let payload_b64 = B64.encode(&sealed);
        let ts_ms = now_ms();
        let signed = format!("{from}{to}{kind}{ts_ms}{payload_b64}");
        let sig = crate::crypto::sign(&client.config().signing_key, signed.as_bytes());

        let core = CoreCallSignal {
            sender: from,
            recver: to,
            kind,
            payload: sealed,
            ts_ms,
            sig,
        };

        // Берём Arc'и на transport — он переживёт async задачу даже если
        // вызывающий освободит handle (handle хранит client, client держит
        // транспорт). Но handle сам по себе освобождать раньше callback'а
        // нельзя — это договорённость API.
        let transport = client.transport().clone();
        let future = async move {
            let result = transport.call_signal(&core).await;
            if let Some(callback) = cb {
                let ud = userdata_addr as *mut std::ffi::c_void;
                match result {
                    Ok(()) => callback(ud, 0, ptr::null()),
                    Err(e) => {
                        let msg = format!("call_signal_failed: {e}");
                        // CString для гарантии 0-терминатора.
                        if let Ok(cmsg) = CString::new(msg) {
                            callback(ud, -1, cmsg.as_ptr());
                            // cmsg дропается тут — после возврата из callback.
                            // Если callback скопировал строку, всё ок.
                        } else {
                            callback(ud, -1, ptr::null());
                        }
                    }
                }
            }
        };

        rt.spawn(future);
        0
    })
}

// ── /call/poll ─────────────────────────────────────────────────────────

#[derive(Deserialize)]
struct PeerKeyEntry {
    peer: String,
    master_key_b64: String,
}

/// Long-poll входящих сигнальных конвертов.
///
/// - `user`: получатель (мы сами)
/// - `peers_keys_json`: JSON-массив `[{"peer":"name","master_key_b64":"..."}, ...]`
///   — нужен для подбора ключа на расшифровку payload'а по `sender`.
/// - `long_poll_ms`: 0 = короткий ответ; >0 = ждать на сервере до этого
///   таймаута. Сервер сам клампит до 30 c.
///
/// Возвращает JSON-строку — массив объектов
/// `[{ "sender": "...", "kind": N, "payload_json": "{\"call_id\":...}", "ts_ms": N }, ...]`
/// (`payload_json` уже расшифрован и десериализован обратно в строку).
/// Конверты, у которых не нашёлся подходящий ключ или payload не парсится,
/// тихо отбрасываются.
///
/// Возвращает NULL при ошибке (см. `paranoia_last_error`). Освобождать через
/// `paranoia_free_string`.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_call_poll(
    handle: *mut crate::ffi::ParanoiaHandle,
    user: *const c_char,
    peers_keys_json: *const c_char,
    long_poll_ms: u32,
) -> *mut c_char {
    ffi_catch_ptr("call_poll_panic", || {
        let user_s = match unsafe { cstr(user) } {
            Some(s) if !s.is_empty() => s,
            _ => {
                set_last_error("invalid_user");
                return ptr::null_mut();
            }
        };
        let peers_json = match unsafe { cstr(peers_keys_json) } {
            Some(s) => s,
            None => {
                set_last_error("invalid_peers_keys");
                return ptr::null_mut();
            }
        };
        let entries: Vec<PeerKeyEntry> = match serde_json::from_str(&peers_json) {
            Ok(v) => v,
            Err(e) => {
                set_last_error(&format!("invalid_peers_keys_json: {e}"));
                return ptr::null_mut();
            }
        };
        let mut by_peer = std::collections::HashMap::with_capacity(entries.len());
        for e in entries {
            if let Some(k) = decode_b64_32(&e.master_key_b64) {
                by_peer.insert(e.peer, k);
            }
        }
        let client = match unsafe { client_ref(handle) } {
            Some(c) => c,
            None => {
                set_last_error("invalid_handle");
                return ptr::null_mut();
            }
        };
        let rt = match unsafe { runtime_ref(handle) } {
            Some(r) => r,
            None => {
                set_last_error("invalid_handle");
                return ptr::null_mut();
            }
        };

        // nonce = (unix_ms << 16) | monotonic_counter_low16. Время даёт грубый
        // ts для логов сервера, счётчик гарантирует strict-monotonic в пределах
        // процесса даже при двух poll'ах в одну миллисекунду (быстрый retry
        // после ошибки). Сервер сам по содержимому nonce не проверяет — только
        // включает его в проверку подписи (см. routes/call_poll.rs).
        static POLL_NONCE_COUNTER: AtomicU64 = AtomicU64::new(0);
        let ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);
        let ctr = POLL_NONCE_COUNTER.fetch_add(1, Ordering::Relaxed) & 0xFFFF;
        let nonce_full = (ms << 16) | ctr;
        let signed = format!("{user_s}{nonce_full}{long_poll_ms}");
        let sig = crate::crypto::sign(&client.config().signing_key, signed.as_bytes());

        let core = CoreCallPoll {
            user: user_s,
            nonce: nonce_full,
            long_poll_ms,
            sig,
        };

        let items: Vec<CallEnvelopeIn> = match rt.block_on(client.transport().call_poll(&core)) {
            Ok(v) => v,
            Err(e) => {
                set_last_error(&format!("call_poll_failed: {e}"));
                return ptr::null_mut();
            }
        };

        // Расшифровываем каждый payload подобранным master_key'ом.
        let mut out = Vec::with_capacity(items.len());
        for env in items {
            let key = match by_peer.get(&env.sender) {
                Some(k) => k,
                None => {
                    tracing::debug!(
                        "call_poll: no key for sender '{}', dropping envelope",
                        env.sender
                    );
                    continue;
                }
            };
            let plain = match signaling_open(key, &env.payload) {
                Ok(p) => p,
                Err(_) => {
                    tracing::debug!(
                        "call_poll: decrypt failed for sender '{}', dropping",
                        env.sender
                    );
                    continue;
                }
            };
            // payload — JSON-строка; возвращаем её как есть, в виде строки.
            let payload_str = match std::str::from_utf8(&plain) {
                Ok(s) => s.to_string(),
                Err(_) => {
                    tracing::debug!("call_poll: non-utf8 payload from '{}'", env.sender);
                    continue;
                }
            };
            out.push(serde_json::json!({
                "sender": env.sender,
                "kind": env.kind,
                "payload_json": payload_str,
                "ts_ms": env.ts_ms,
            }));
        }
        let result = serde_json::Value::Array(out).to_string();
        string_to_c(result)
    })
}

// ── UDP сессия ─────────────────────────────────────────────────────────

/// Callback входящего расшифрованного Opus-фрейма (voice-поток). Вызывается из
/// фоновой Tokio-задачи — callee должен быть thread-safe.
///
/// `userdata` — то же значение, что было передано в `paranoia_call_session_start`.
/// `opus`/`len` валидны только во время вызова; копировать при необходимости.
/// `sequence` — sequence number из VoIP-заголовка пакета (uniquely monotonic
/// per stream), нужен для jitter buffer на стороне Qt.
pub type FrameCallback = Option<
    unsafe extern "C" fn(
        userdata: *mut std::ffi::c_void,
        opus: *const u8,
        len: usize,
        sequence: u64,
    ),
>;

/// Callback входящего расшифрованного видеопакета (один фрагмент NAL'а).
/// Вызывается из фоновой Tokio-задачи — callee должен быть thread-safe.
///
/// `nal_fragment`/`len` валидны только во время вызова; копировать при
/// необходимости. `sequence` — per-video-stream sequence (нужен для
/// детекции потерь). `rtp_timestamp` — общий для всех фрагментов одного
/// кадра. `flags` — биты из заголовка (bit1 = FRAME_START у первого
/// фрагмента кадра). Caller на Qt-стороне собирает кадр через
/// `voip::nal::Reassembler`-аналог.
pub type VideoCallback = Option<
    unsafe extern "C" fn(
        userdata: *mut std::ffi::c_void,
        nal_fragment: *const u8,
        len: usize,
        sequence: u64,
        rtp_timestamp: u32,
        flags: u8,
    ),
>;

/// Callback изменения состояния сессии. `state`: одна из C-строк
/// `"started"`, `"stopped"`, `"error"`.
pub type StateCallback =
    Option<unsafe extern "C" fn(userdata: *mut std::ffi::c_void, state: *const c_char)>;

pub struct ParanoiaCallSession {
    rt: Arc<Runtime>,
    handle: Mutex<Option<crate::voip::transport::SessionHandle>>,
    /// Фоновые task'и, читающие inbound и вызывающие callback'и: один для
    /// voice, один для video — раздельно, чтобы медленный video-callback
    /// (декодер, реассемблер на Qt) не блокировал доставку voice. См.
    /// SessionHandle::take_voice_inbound / take_video_inbound.
    voice_inbound_task: Mutex<Option<tokio::task::JoinHandle<()>>>,
    video_inbound_task: Mutex<Option<tokio::task::JoinHandle<()>>>,
    /// Чтобы userdata можно было свободно отдать в task — обернём в struct.
    /// Хранится для гарантий времени жизни, явно не используется после spawn.
    _cb_anchor: Arc<CallbackAnchor>,
}

struct CallbackAnchor {
    frame_cb: FrameCallback,
    video_cb: VideoCallback,
    state_cb: StateCallback,
    userdata: usize, // на самом деле *mut c_void; usize чтобы быть Send
}

// SAFETY: callback'и и userdata должны быть thread-safe со стороны caller'а.
// Это контракт C-API, мы помечаем Send/Sync явно.
unsafe impl Send for CallbackAnchor {}
unsafe impl Sync for CallbackAnchor {}

fn parse_role(r: i32) -> Option<Role> {
    match r {
        0 => Some(Role::Initiator),
        1 => Some(Role::Responder),
        _ => None,
    }
}

fn parse_peer(peer_addr: *const c_char) -> Option<SocketAddr> {
    let s = unsafe { cstr(peer_addr) }?;
    if s.is_empty() {
        return None;
    }
    s.to_socket_addrs().ok().and_then(|mut a| a.next())
}

/// Общий хелпер: bind + spawn + inbound task. `peer` может быть None — тогда
/// сессия слушает, но не шлёт ничего до явного `set_peer` или auto-discovery.
/// Сессия мультиплексирует voice + video по одному сокету; `frame_cb` дёргается
/// на voice-пакеты, `video_cb` — на video-пакеты.
#[allow(clippy::too_many_arguments)]
fn start_session_impl(
    local_bind: *const c_char,
    peer: Option<SocketAddr>,
    master_key_b64: *const c_char,
    session_id_b64: *const c_char,
    role: i32,
    frame_cb: FrameCallback,
    video_cb: VideoCallback,
    state_cb: StateCallback,
    userdata: *mut std::ffi::c_void,
) -> *mut ParanoiaCallSession {
    let bind = match unsafe { cstr(local_bind) } {
        Some(s) if !s.is_empty() => s,
        _ => {
            set_last_error("invalid_local_bind");
            return ptr::null_mut();
        }
    };
    let mk = match unsafe { cstr(master_key_b64) }
        .as_deref()
        .and_then(decode_b64_32)
    {
        Some(k) => k,
        None => {
            set_last_error("invalid_master_key");
            return ptr::null_mut();
        }
    };
    let sid = match unsafe { cstr(session_id_b64) }
        .as_deref()
        .and_then(decode_b64_16)
    {
        Some(s) => s,
        None => {
            set_last_error("invalid_session_id");
            return ptr::null_mut();
        }
    };
    let role = match parse_role(role) {
        Some(r) => r,
        None => {
            set_last_error("invalid_role");
            return ptr::null_mut();
        }
    };

    let rt = match voip_runtime() {
        Some(r) => r,
        None => {
            set_last_error("runtime_error");
            return ptr::null_mut();
        }
    };

    let bind_addr: SocketAddr = match bind.parse() {
        Ok(a) => a,
        Err(_) => {
            set_last_error("local_bind_parse_failed");
            return ptr::null_mut();
        }
    };
    let socket = match rt.block_on(async { bind_call_socket(bind_addr) }) {
        Ok(s) => s,
        Err(e) => {
            set_last_error(&format!("udp_bind_failed: {e}"));
            return ptr::null_mut();
        }
    };

    let keys = StreamKeys::derive(&mk, &sid, role);
    let mut session = {
        let _g = rt.enter();
        spawn_session(socket, SessionParams { role, peer }, keys, 128, 128)
    };

    let anchor = Arc::new(CallbackAnchor {
        frame_cb,
        video_cb,
        state_cb,
        userdata: userdata as usize,
    });
    let mut voice_inbound = match session.take_voice_inbound() {
        Some(rx) => rx,
        None => {
            set_last_error("internal_no_inbound");
            return ptr::null_mut();
        }
    };
    let mut video_inbound = match session.take_video_inbound() {
        Some(rx) => rx,
        None => {
            set_last_error("internal_no_inbound");
            return ptr::null_mut();
        }
    };
    let voice_anchor = Arc::clone(&anchor);
    let voice_inbound_task = rt.spawn(async move {
        while let Some(frame) = voice_inbound.recv().await {
            let userdata = voice_anchor.userdata as *mut std::ffi::c_void;
            if let Some(cb) = voice_anchor.frame_cb {
                let opus = frame.opus;
                // SAFETY: cb signed as unsafe extern "C"; pointers valid for call duration.
                unsafe {
                    cb(userdata, opus.as_ptr(), opus.len(), frame.sequence);
                }
            }
        }
    });
    let video_anchor = Arc::clone(&anchor);
    let video_inbound_task = rt.spawn(async move {
        while let Some(frame) = video_inbound.recv().await {
            let userdata = video_anchor.userdata as *mut std::ffi::c_void;
            if let Some(cb) = video_anchor.video_cb {
                let nal = frame.opus; // поле имени из voice — историческое, переименование шум
                unsafe {
                    cb(
                        userdata,
                        nal.as_ptr(),
                        nal.len(),
                        frame.sequence,
                        frame.rtp_timestamp,
                        frame.flags,
                    );
                }
            }
        }
    });

    if let Some(cb) = anchor.state_cb {
        if let Ok(s) = CString::new("started") {
            unsafe { cb(anchor.userdata as *mut std::ffi::c_void, s.as_ptr()) };
        }
    }

    let session = ParanoiaCallSession {
        rt,
        handle: Mutex::new(Some(session)),
        voice_inbound_task: Mutex::new(Some(voice_inbound_task)),
        video_inbound_task: Mutex::new(Some(video_inbound_task)),
        _cb_anchor: anchor,
    };
    Box::into_raw(Box::new(session))
}

/// Запустить UDP-сессию звонка с заранее известным peer-адресом.
/// Сессия мультиплексирует voice + video; `frame_cb` для voice, `video_cb`
/// для video. Любой callback может быть NULL — соответствующий поток будет
/// тихо игнорироваться.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_call_session_start(
    local_bind: *const c_char,
    peer_addr: *const c_char,
    master_key_b64: *const c_char,
    session_id_b64: *const c_char,
    role: i32,
    frame_cb: FrameCallback,
    video_cb: VideoCallback,
    state_cb: StateCallback,
    userdata: *mut std::ffi::c_void,
) -> *mut ParanoiaCallSession {
    match catch_unwind(AssertUnwindSafe(|| {
        let peer = match parse_peer(peer_addr) {
            Some(p) => p,
            None => {
                set_last_error("peer_addr_parse_failed");
                return ptr::null_mut();
            }
        };
        start_session_impl(
            local_bind,
            Some(peer),
            master_key_b64,
            session_id_b64,
            role,
            frame_cb,
            video_cb,
            state_cb,
            userdata,
        )
    })) {
        Ok(p) => p,
        Err(_) => {
            set_last_error("call_session_start_panic");
            ptr::null_mut()
        }
    }
}

/// Запустить сессию без заранее известного peer'а: только bind.
/// Peer задаётся позже через `paranoia_call_session_set_peer`, либо сессия
/// сама определит его при первом валидном входящем пакете.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_call_session_start_unbound(
    local_bind: *const c_char,
    master_key_b64: *const c_char,
    session_id_b64: *const c_char,
    role: i32,
    frame_cb: FrameCallback,
    video_cb: VideoCallback,
    state_cb: StateCallback,
    userdata: *mut std::ffi::c_void,
) -> *mut ParanoiaCallSession {
    match catch_unwind(AssertUnwindSafe(|| {
        start_session_impl(
            local_bind,
            None,
            master_key_b64,
            session_id_b64,
            role,
            frame_cb,
            video_cb,
            state_cb,
            userdata,
        )
    })) {
        Ok(p) => p,
        Err(_) => {
            set_last_error("call_session_start_panic");
            ptr::null_mut()
        }
    }
}

/// Задать peer-адрес уже запущенной сессии. `peer_addr` — `"ip:port"`.
/// Возвращает 0/-1.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_call_session_set_peer(
    session: *mut ParanoiaCallSession,
    peer_addr: *const c_char,
) -> i32 {
    ffi_catch_i32("call_session_set_peer_panic", || {
        if session.is_null() {
            set_last_error("invalid_argument");
            return -1;
        }
        let session = unsafe { &*session };
        let peer = match parse_peer(peer_addr) {
            Some(p) => p,
            None => {
                set_last_error("peer_addr_parse_failed");
                return -1;
            }
        };
        let guard = match session.handle.lock() {
            Ok(g) => g,
            Err(_) => {
                set_last_error("session_lock_poisoned");
                return -1;
            }
        };
        match guard.as_ref() {
            Some(h) => {
                h.set_peer(peer);
                0
            }
            None => {
                set_last_error("session_stopped");
                -1
            }
        }
    })
}

/// Послать STUN Binding Request через UDP-сокет уже-запущенной сессии и
/// вернуть reflexive `"ip:port"`. В отличие от `paranoia_stun_discover` (с
/// собственным сокетом), это даёт reflexive *того же* порта, что использует
/// сессия — критично для NAT-traversal'а через ICE-кандидаты.
///
/// Возвращает строку или NULL при ошибке. Освобождать `paranoia_free_string`.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_call_session_stun_discover(
    session: *mut ParanoiaCallSession,
    stun_server: *const c_char,
    timeout_ms: u32,
) -> *mut c_char {
    ffi_catch_ptr("call_session_stun_discover_panic", || {
        if session.is_null() {
            set_last_error("invalid_argument");
            return ptr::null_mut();
        }
        let session_ref = unsafe { &*session };
        let server_s = match unsafe { cstr(stun_server) } {
            Some(s) if !s.is_empty() => s,
            _ => {
                set_last_error("invalid_stun_server");
                return ptr::null_mut();
            }
        };
        let server: SocketAddr = match server_s.to_socket_addrs().ok().and_then(|mut a| a.next()) {
            Some(p) => p,
            None => {
                set_last_error("stun_server_parse_failed");
                return ptr::null_mut();
            }
        };
        // Берём owned future ПОД локом (клонирует stun_tx), сразу
        // отпускаем mutex (он защищает Mutex<Option<SessionHandle>>), и только
        // потом block_on. Если оставить лок захваченным на 2с — все остальные
        // FFI-вызовы (push_opus каждые 20мс, set_peer и пр.) замораживаются,
        // что давало периодические подвисания при periodic re-probe из
        // CallController.
        let future = {
            let guard = match session_ref.handle.lock() {
                Ok(g) => g,
                Err(_) => {
                    set_last_error("session_lock_poisoned");
                    return ptr::null_mut();
                }
            };
            let h = match guard.as_ref() {
                Some(h) => h,
                None => {
                    set_last_error("session_stopped");
                    return ptr::null_mut();
                }
            };
            h.stun_discover_owned(server, std::time::Duration::from_millis(timeout_ms as u64))
            // guard уходит из scope здесь → mutex освобождён
        };
        let result = session_ref.rt.block_on(future);
        match result {
            Ok(addr) => string_to_c(addr.to_string()),
            Err(e) => {
                set_last_error(&format!("session_stun_discover_failed: {e}"));
                ptr::null_mut()
            }
        }
    })
}

/// Выполнить TURN Allocate через UDP-сокет уже-запущенной сессии и вернуть
/// relayed address `"ip:port"`. Этот адрес нужно передать peer'у как TURN ICE
/// candidate; media продолжает шифроваться end-to-end, TURN видит только
/// ciphertext.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_call_session_turn_allocate(
    session: *mut ParanoiaCallSession,
    turn_server: *const c_char,
    timeout_ms: u32,
) -> *mut c_char {
    ffi_catch_ptr("call_session_turn_allocate_panic", || {
        if session.is_null() {
            set_last_error("invalid_argument");
            return ptr::null_mut();
        }
        let session_ref = unsafe { &*session };
        let server_s = match unsafe { cstr(turn_server) } {
            Some(s) if !s.is_empty() => s,
            _ => {
                set_last_error("invalid_turn_server");
                return ptr::null_mut();
            }
        };
        let server: SocketAddr = match server_s.to_socket_addrs().ok().and_then(|mut a| a.next()) {
            Some(p) => p,
            None => {
                set_last_error("turn_server_parse_failed");
                return ptr::null_mut();
            }
        };
        // Так же как и в stun_discover — не держать mutex во время block_on.
        let future = {
            let guard = match session_ref.handle.lock() {
                Ok(g) => g,
                Err(_) => {
                    set_last_error("session_lock_poisoned");
                    return ptr::null_mut();
                }
            };
            let h = match guard.as_ref() {
                Some(h) => h,
                None => {
                    set_last_error("session_stopped");
                    return ptr::null_mut();
                }
            };
            h.turn_allocate_owned(server, std::time::Duration::from_millis(timeout_ms as u64))
        };
        let result = session_ref.rt.block_on(future);
        match result {
            Ok(addr) => string_to_c(addr.to_string()),
            Err(e) => {
                set_last_error(&format!("session_turn_allocate_failed: {e}"));
                ptr::null_mut()
            }
        }
    })
}

/// Переключить текущего peer'а на TURN relay. Исходящие media будут уходить как
/// TURN Send Indication к `turn_server` с `peer_relay_addr` как XOR-PEER-ADDRESS;
/// входящие TURN Data Indication распаковываются в transport-loop'е.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_call_session_set_turn_peer(
    session: *mut ParanoiaCallSession,
    turn_server: *const c_char,
    peer_relay_addr: *const c_char,
) -> i32 {
    ffi_catch_i32("call_session_set_turn_peer_panic", || {
        if session.is_null() {
            set_last_error("invalid_argument");
            return -1;
        }
        let session_ref = unsafe { &*session };
        let server_s = match unsafe { cstr(turn_server) } {
            Some(s) if !s.is_empty() => s,
            _ => {
                set_last_error("invalid_turn_server");
                return -1;
            }
        };
        let peer_s = match unsafe { cstr(peer_relay_addr) } {
            Some(s) if !s.is_empty() => s,
            _ => {
                set_last_error("invalid_turn_peer");
                return -1;
            }
        };
        let server: SocketAddr = match server_s.to_socket_addrs().ok().and_then(|mut a| a.next()) {
            Some(p) => p,
            None => {
                set_last_error("turn_server_parse_failed");
                return -1;
            }
        };
        let peer: SocketAddr = match peer_s.to_socket_addrs().ok().and_then(|mut a| a.next()) {
            Some(p) => p,
            None => {
                set_last_error("turn_peer_parse_failed");
                return -1;
            }
        };
        // Не держать mutex во время block_on (см. stun_discover).
        let future = {
            let guard = match session_ref.handle.lock() {
                Ok(g) => g,
                Err(_) => {
                    set_last_error("session_lock_poisoned");
                    return -1;
                }
            };
            let h = match guard.as_ref() {
                Some(h) => h,
                None => {
                    set_last_error("session_stopped");
                    return -1;
                }
            };
            h.set_turn_peer_owned(server, peer)
        };
        let result = session_ref.rt.block_on(future);
        match result {
            Ok(()) => 0,
            Err(e) => {
                set_last_error(&format!("session_set_turn_peer_failed: {e}"));
                -1
            }
        }
    })
}

/// Вернуть локальный адрес сессии вида `"ip:port"` (после bind). NULL при
/// ошибке. Освобождать через `paranoia_free_string`.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_call_session_local_addr(
    session: *mut ParanoiaCallSession,
) -> *mut c_char {
    ffi_catch_ptr("call_session_local_addr_panic", || {
        if session.is_null() {
            set_last_error("invalid_argument");
            return ptr::null_mut();
        }
        let session = unsafe { &*session };
        let guard = match session.handle.lock() {
            Ok(g) => g,
            Err(_) => {
                set_last_error("session_lock_poisoned");
                return ptr::null_mut();
            }
        };
        match guard.as_ref() {
            Some(h) => string_to_c(h.local_addr().to_string()),
            None => {
                set_last_error("session_stopped");
                ptr::null_mut()
            }
        }
    })
}

/// Вернуть текущий peer-адрес сессии в формате `"ip:port"`, либо пустую
/// строку если peer ещё не определён. Это эффективный rx-источник: Rust
/// auto-discover в `voip::transport::process_media_datagram` обновляет это
/// поле при каждом валидном AEAD-пакете → значение отражает, **откуда
/// фактически приходит media сейчас** (direct UDP source или TURN relay-адрес,
/// в зависимости от пути). Qt-сторона использует это для определения
/// rx-направления в индикаторе пути (см. CallController). NULL при ошибке.
/// Освобождать через `paranoia_free_string`.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_call_session_get_peer(
    session: *mut ParanoiaCallSession,
) -> *mut c_char {
    ffi_catch_ptr("call_session_get_peer_panic", || {
        if session.is_null() {
            set_last_error("invalid_argument");
            return ptr::null_mut();
        }
        let session = unsafe { &*session };
        let guard = match session.handle.lock() {
            Ok(g) => g,
            Err(_) => {
                set_last_error("session_lock_poisoned");
                return ptr::null_mut();
            }
        };
        match guard.as_ref() {
            Some(h) => match h.peer() {
                Some(addr) => string_to_c(addr.to_string()),
                None => string_to_c(String::new()),
            },
            None => {
                set_last_error("session_stopped");
                ptr::null_mut()
            }
        }
    })
}

/// Передать один Opus-фрейм в исходящий канал сессии. Возвращает 0/-1.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_call_session_push_opus(
    session: *mut ParanoiaCallSession,
    opus: *const u8,
    len: usize,
) -> i32 {
    ffi_catch_i32("call_session_push_panic", || {
        if session.is_null() || opus.is_null() {
            set_last_error("invalid_argument");
            return -1;
        }
        let session = unsafe { &*session };
        let frame: Vec<u8> = if len == 0 {
            Vec::new()
        } else {
            unsafe { std::slice::from_raw_parts(opus, len) }.to_vec()
        };
        let sender = {
            let guard = match session.handle.lock() {
                Ok(g) => g,
                Err(_) => {
                    set_last_error("session_lock_poisoned");
                    return -1;
                }
            };
            match guard.as_ref() {
                Some(h) => h.outbound_sender(),
                None => {
                    set_last_error("session_stopped");
                    return -1;
                }
            }
        };
        match session.rt.block_on(sender.send(frame)) {
            Ok(()) => 0,
            Err(_) => {
                set_last_error("session_send_closed");
                -1
            }
        }
    })
}

/// Передать один уже-фрагментированный H.264 NAL-пакет в исходящий
/// видео-канал сессии. Caller отвечает за фрагментацию NAL'ов (на Qt-стороне
/// это делает обёртка вокруг `voip::nal::Fragmenter` через свой код, либо мы
/// фрагментируем здесь — на текущем этапе FFI принимает уже готовые
/// фрагменты).
///
/// `flags`: bit1 (FRAME_START) обязан быть выставлен у первого фрагмента
/// каждого кадра, у остальных — 0. Остальные биты должны быть 0 (RESERVED).
/// `rtp_timestamp`: один и тот же у всех фрагментов одного кадра; обычно
/// миллисекундный/90-килогерцовый тикер. Возвращает 0/-1.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_call_session_push_h264(
    session: *mut ParanoiaCallSession,
    payload: *const u8,
    len: usize,
    flags: u8,
    rtp_timestamp: u32,
) -> i32 {
    ffi_catch_i32("call_session_push_h264_panic", || {
        if session.is_null() || payload.is_null() || len == 0 {
            set_last_error("invalid_argument");
            return -1;
        }
        let session = unsafe { &*session };
        let buf = unsafe { std::slice::from_raw_parts(payload, len) }.to_vec();
        let sender = {
            let guard = match session.handle.lock() {
                Ok(g) => g,
                Err(_) => {
                    set_last_error("session_lock_poisoned");
                    return -1;
                }
            };
            match guard.as_ref() {
                Some(h) => h.video_outbound_sender(),
                None => {
                    set_last_error("session_stopped");
                    return -1;
                }
            }
        };
        let pkt = VideoOutboundPacket {
            flags,
            rtp_timestamp,
            payload: buf,
        };
        match session.rt.block_on(sender.send(pkt)) {
            Ok(()) => 0,
            Err(_) => {
                set_last_error("session_video_send_closed");
                -1
            }
        }
    })
}

/// Остановить сессию: shutdown loop'а, join task'ов, освободить ресурсы.
/// После этого вызова указатель невалиден.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_call_session_stop(session: *mut ParanoiaCallSession) {
    if session.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: caller гарантирует, что больше никто не использует этот указатель.
        let boxed = unsafe { Box::from_raw(session) };
        let ParanoiaCallSession {
            rt,
            handle,
            voice_inbound_task,
            video_inbound_task,
            _cb_anchor,
        } = *boxed;

        if let Ok(mut g) = handle.lock() {
            if let Some(h) = g.take() {
                rt.block_on(async {
                    let _ = h.join().await;
                });
            }
        }
        // Дожидаемся обоих inbound task'ов. После join'а run_session, оба
        // senders (voice_inbound_tx, video_inbound_tx) дропнуты → recv() в task'ах
        // вернёт None → task'и завершатся почти сразу.
        if let Ok(mut t) = voice_inbound_task.lock() {
            if let Some(jh) = t.take() {
                rt.block_on(async {
                    let _ = jh.await;
                });
            }
        }
        if let Ok(mut t) = video_inbound_task.lock() {
            if let Some(jh) = t.take() {
                rt.block_on(async {
                    let _ = jh.await;
                });
            }
        }
        // state_cb "stopped"
        if let Some(cb) = _cb_anchor.state_cb {
            if let Ok(s) = CString::new("stopped") {
                unsafe { cb(_cb_anchor.userdata as *mut std::ffi::c_void, s.as_ptr()) };
            }
        }
        // rt дропается здесь.
    }));
}

// ── STUN ───────────────────────────────────────────────────────────────

/// Определить публичный (reflexive) IP:port через один Binding Request к
/// STUN-серверу. Шлёт запрос с локального `local_bind` (например
/// `"0.0.0.0:0"`), ждёт ответ до `timeout_ms`.
///
/// Возвращает строку `"ip:port"` или NULL при ошибке (см. `paranoia_last_error`).
/// Освобождать через `paranoia_free_string`.
#[unsafe(no_mangle)]
pub extern "C" fn paranoia_stun_discover(
    local_bind: *const c_char,
    stun_server: *const c_char,
    timeout_ms: u32,
) -> *mut c_char {
    ffi_catch_ptr("stun_discover_panic", || {
        let bind = match unsafe { cstr(local_bind) } {
            Some(s) if !s.is_empty() => s,
            _ => {
                set_last_error("invalid_local_bind");
                return ptr::null_mut();
            }
        };
        let server_s = match unsafe { cstr(stun_server) } {
            Some(s) if !s.is_empty() => s,
            _ => {
                set_last_error("invalid_stun_server");
                return ptr::null_mut();
            }
        };
        let server: SocketAddr = match server_s.to_socket_addrs().ok().and_then(|mut a| a.next()) {
            Some(p) => p,
            None => {
                set_last_error("stun_server_parse_failed");
                return ptr::null_mut();
            }
        };
        let bind_addr: SocketAddr = match bind.parse() {
            Ok(a) => a,
            Err(_) => {
                set_last_error("local_bind_parse_failed");
                return ptr::null_mut();
            }
        };

        let rt = match voip_runtime() {
            Some(r) => r,
            None => {
                set_last_error("runtime_error");
                return ptr::null_mut();
            }
        };
        let result = rt.block_on(async move {
            let sock = bind_call_socket(bind_addr)?;
            let reflexive = discover_reflexive(
                &sock,
                server,
                std::time::Duration::from_millis(timeout_ms as u64),
            )
            .await?;
            anyhow::Ok(reflexive.to_string())
        });
        match result {
            Ok(s) => string_to_c(s),
            Err(e) => {
                set_last_error(&format!("stun_discover_failed: {e}"));
                ptr::null_mut()
            }
        }
    })
}
