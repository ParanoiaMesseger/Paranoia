//! Integration-тест C-FFI VoIP-сессии.
//!
//! Запускает две сессии (инициатор и ответчик) через `paranoia_call_session_start`
//! на localhost, передаёт несколько Opus-фреймов в обе стороны, проверяет, что
//! callback'и были вызваны с правильным содержимым и сессии корректно
//! останавливаются.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use base64::{Engine, engine::general_purpose::STANDARD as B64};
use paranoia_lib::voip_ffi::{paranoia_call_session_push_opus, paranoia_call_session_start,
    paranoia_call_session_stop};

/// Состояние, которое userdata указывает.
struct CapturedFrames(Mutex<Vec<Vec<u8>>>);

unsafe extern "C" fn capture_frame(
    userdata: *mut std::ffi::c_void,
    opus: *const u8,
    len: usize,
    _sequence: u64,
) {
    if userdata.is_null() || opus.is_null() {
        return;
    }
    let bytes = unsafe { std::slice::from_raw_parts(opus, len) }.to_vec();
    let captured = unsafe { &*(userdata as *const CapturedFrames) };
    captured.0.lock().unwrap().push(bytes);
}

unsafe extern "C" fn ignore_video(
    _userdata: *mut std::ffi::c_void,
    _nal: *const u8,
    _len: usize,
    _sequence: u64,
    _rtp_timestamp: u32,
    _flags: u8,
) {
}

unsafe extern "C" fn capture_state(_userdata: *mut std::ffi::c_void, _state: *const c_char) {
    // Игнорируем: достаточно того, что callback не падает.
}

fn cstr(s: &str) -> CString {
    CString::new(s).unwrap()
}

/// Найти свободный UDP-порт на localhost через std::net (затем закроем).
fn pick_port() -> u16 {
    let s = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
    let port = s.local_addr().unwrap().port();
    drop(s);
    port
}

#[test]
fn ffi_voip_loopback_two_sessions_exchange_frames() {
    let port_init = pick_port();
    let port_resp = pick_port();
    // Маленький race-window: между drop сокета и bind. На loopback почти никогда
    // не воспроизводится — для unit-теста достаточно.

    let master_key = [0x42u8; 32];
    let session_id = [0x07u8; 16];
    let mk_b64 = B64.encode(master_key);
    let sid_b64 = B64.encode(session_id);

    let bind_init = cstr(&format!("127.0.0.1:{port_init}"));
    let bind_resp = cstr(&format!("127.0.0.1:{port_resp}"));
    let peer_init = cstr(&format!("127.0.0.1:{port_resp}"));
    let peer_resp = cstr(&format!("127.0.0.1:{port_init}"));
    let mk = cstr(&mk_b64);
    let sid = cstr(&sid_b64);

    let frames_init = Arc::new(CapturedFrames(Mutex::new(Vec::new())));
    let frames_resp = Arc::new(CapturedFrames(Mutex::new(Vec::new())));

    let s_init = paranoia_call_session_start(
        bind_init.as_ptr(),
        peer_init.as_ptr(),
        mk.as_ptr(),
        sid.as_ptr(),
        0, // initiator
        Some(capture_frame),
        Some(ignore_video),
        Some(capture_state),
        Arc::as_ptr(&frames_init) as *mut std::ffi::c_void,
    );
    assert!(!s_init.is_null(), "initiator session must start");

    let s_resp = paranoia_call_session_start(
        bind_resp.as_ptr(),
        peer_resp.as_ptr(),
        mk.as_ptr(),
        sid.as_ptr(),
        1, // responder
        Some(capture_frame),
        Some(ignore_video),
        Some(capture_state),
        Arc::as_ptr(&frames_resp) as *mut std::ffi::c_void,
    );
    assert!(!s_resp.is_null(), "responder session must start");

    // Отправляем три фрейма от инициатора, один в обратную сторону.
    let payloads_init: Vec<Vec<u8>> = (0u8..3).map(|i| vec![i, i + 10, i + 20]).collect();
    for p in &payloads_init {
        let rc = paranoia_call_session_push_opus(s_init, p.as_ptr(), p.len());
        assert_eq!(rc, 0);
    }
    let back = vec![0xAA, 0xBB];
    let rc = paranoia_call_session_push_opus(s_resp, back.as_ptr(), back.len());
    assert_eq!(rc, 0);

    // Опрашиваем callback с таймаутом — нам должны прийти 3 фрейма на responder
    // и 1 на initiator. Keep-alive comfort-noise (пустой payload) тоже может
    // прилететь, фильтруем по непустому payload'у.
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        let got_resp = frames_resp
            .0
            .lock()
            .unwrap()
            .iter()
            .filter(|f| !f.is_empty())
            .count();
        let got_init = frames_init
            .0
            .lock()
            .unwrap()
            .iter()
            .filter(|f| !f.is_empty())
            .count();
        if got_resp >= payloads_init.len() && got_init >= 1 {
            break;
        }
        if Instant::now() > deadline {
            panic!(
                "timed out waiting for frames: responder got {got_resp}, initiator got {got_init}"
            );
        }
        std::thread::sleep(Duration::from_millis(20));
    }

    let resp_payloads: Vec<Vec<u8>> = frames_resp
        .0
        .lock()
        .unwrap()
        .iter()
        .filter(|f| !f.is_empty())
        .cloned()
        .collect();
    assert_eq!(resp_payloads, payloads_init);

    let init_payloads: Vec<Vec<u8>> = frames_init
        .0
        .lock()
        .unwrap()
        .iter()
        .filter(|f| !f.is_empty())
        .cloned()
        .collect();
    assert_eq!(init_payloads, vec![back]);

    paranoia_call_session_stop(s_init);
    paranoia_call_session_stop(s_resp);
}

#[test]
fn ffi_voip_invalid_inputs_return_null_or_minus_one() {
    let mk_b64 = B64.encode([0u8; 32]);
    let sid_b64 = B64.encode([0u8; 16]);
    let bind = cstr("127.0.0.1:0");
    let peer = cstr("127.0.0.1:1");
    let mk = cstr(&mk_b64);
    let sid = cstr(&sid_b64);

    // Невалидный role.
    let s = paranoia_call_session_start(
        bind.as_ptr(),
        peer.as_ptr(),
        mk.as_ptr(),
        sid.as_ptr(),
        9,
        None,
        None,
        None,
        std::ptr::null_mut(),
    );
    assert!(s.is_null());

    // Невалидный peer.
    let bad_peer = cstr("not-a-valid-addr");
    let s = paranoia_call_session_start(
        bind.as_ptr(),
        bad_peer.as_ptr(),
        mk.as_ptr(),
        sid.as_ptr(),
        0,
        None,
        None,
        None,
        std::ptr::null_mut(),
    );
    assert!(s.is_null());

    // push_opus с NULL-сессией.
    let rc = paranoia_call_session_push_opus(std::ptr::null_mut(), std::ptr::null(), 0);
    assert_eq!(rc, -1);

    // stop с NULL — без падения.
    paranoia_call_session_stop(std::ptr::null_mut());

    // Проверим, что last_error не пустой после неудачи.
    let err_ptr = paranoia_lib::ffi::paranoia_last_error();
    if !err_ptr.is_null() {
        let s = unsafe { CStr::from_ptr(err_ptr) }.to_string_lossy();
        assert!(
            !s.is_empty(),
            "paranoia_last_error must be set after failure"
        );
    }
}
