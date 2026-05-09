/// Тесты проверяют, что paranoia_last_error() никогда не раскрывает
/// чувствительные данные: URL сервера, приватные ключи, payload, сырые ответы.
///
/// Свойство: коды ошибок FFI — это непрозрачные классификаторы, не содержащие
/// исходных строк ошибок.
use paranoia_lib::ffi::{
    paranoia_client_free, paranoia_client_new, paranoia_free_string, paranoia_last_error,
};
use std::ffi::{CStr, CString};
use tempfile::TempDir;

// ── helpers ───────────────────────────────────────────────────────────────────

fn read_last_error() -> String {
    let ptr = paranoia_last_error();
    if ptr.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .unwrap_or("")
        .to_string()
}

fn cs(s: &str) -> CString {
    CString::new(s).expect("CString::new")
}

/// base64 для 32 нулевых байт — минимально валидный signing key Ed25519.
const ZERO_KEY_B64: &str = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

// ── Test 1: невалидный ключ → понятный код ошибки, без байтов ключа ──────────

#[test]
fn invalid_key_returns_opaque_error_code() {
    let temp = TempDir::new().expect("tempdir");
    let db = temp.path().join("test.sqlite");

    let bad_key = "not-valid-base64!!!this_is_secret_material";
    let handle = paranoia_client_new(
        cs("http://127.0.0.1:1").as_ptr(),
        cs("alice").as_ptr(),
        cs(bad_key).as_ptr(),
        cs(db.to_str().unwrap()).as_ptr(),
    );

    assert!(handle.is_null(), "must fail for invalid key");

    let err = read_last_error();
    assert_eq!(
        err, "invalid_signing_key: expected 32 bytes base64",
        "unexpected error: {err}"
    );
    // Ни один фрагмент исходной строки ключа не должен утечь
    assert!(
        !err.contains("not-valid-base64"),
        "key material must not appear in error: {err}"
    );
    assert!(
        !err.contains("secret_material"),
        "key material must not appear in error: {err}"
    );
}

// ── Test 2: paranoia_client_new с корректными данными → handle не NULL ────────

#[test]
fn valid_client_creation_succeeds() {
    let temp = TempDir::new().expect("tempdir");
    let db = temp.path().join("test.sqlite");

    let handle = paranoia_client_new(
        cs("http://127.0.0.1:9999").as_ptr(),
        cs("alice").as_ptr(),
        cs(ZERO_KEY_B64).as_ptr(),
        cs(db.to_str().unwrap()).as_ptr(),
    );

    assert!(!handle.is_null(), "valid client must succeed");
    paranoia_client_free(handle);
}

// ── Test 3: paranoia_free_string корректно работает с NULL ────────────────────

#[test]
fn free_null_string_is_safe() {
    // Не должно паниковать или упасть
    paranoia_free_string(std::ptr::null_mut());
}
