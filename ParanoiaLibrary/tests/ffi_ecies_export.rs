// Интеграционные тесты ECIES-экспорта через FFI.
// Проверяет полный цикл: генерация keypair → шифрование → расшифровка.
use base64::Engine;
use paranoia_lib::ffi::{
    paranoia_ecies_decrypt, paranoia_ecies_encrypt, paranoia_ecies_generate_keypair,
    paranoia_ecies_pubkey, paranoia_free_string, paranoia_last_error,
};
use std::ffi::{CStr, CString};

fn cs(s: &str) -> CString {
    CString::new(s).expect("CString::new")
}

fn take_string(ptr: *mut std::os::raw::c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    let s = unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .map(|s| s.to_string())
        .ok();
    paranoia_free_string(ptr);
    s
}

fn last_error() -> String {
    let ptr = paranoia_last_error();
    if ptr.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .unwrap_or("")
        .to_string()
}

fn generate_keypair() -> (String, String) {
    let mut priv_ptr: *mut std::os::raw::c_char = std::ptr::null_mut();
    let mut pub_ptr: *mut std::os::raw::c_char = std::ptr::null_mut();
    paranoia_ecies_generate_keypair(&mut priv_ptr, &mut pub_ptr);
    let priv_b64 = take_string(priv_ptr).expect("privkey");
    let pub_b64 = take_string(pub_ptr).expect("pubkey");
    (priv_b64, pub_b64)
}

#[test]
fn ecies_generate_keypair_returns_valid_32_byte_keys() {
    let (priv_b64, pub_b64) = generate_keypair();

    let priv_bytes = base64::engine::general_purpose::STANDARD
        .decode(&priv_b64)
        .expect("valid base64 privkey");
    let pub_bytes = base64::engine::general_purpose::STANDARD
        .decode(&pub_b64)
        .expect("valid base64 pubkey");

    assert_eq!(priv_bytes.len(), 32, "privkey must be 32 bytes");
    assert_eq!(pub_bytes.len(), 32, "pubkey must be 32 bytes");
    assert_ne!(priv_b64, pub_b64, "priv and pub must differ");
}

#[test]
fn ecies_pubkey_derives_from_privkey() {
    let (priv_b64, pub_b64) = generate_keypair();

    let derived = take_string(paranoia_ecies_pubkey(cs(&priv_b64).as_ptr()))
        .expect("derived pubkey");

    assert_eq!(pub_b64, derived, "derived pubkey must match generated");
}

#[test]
fn ecies_encrypt_decrypt_roundtrip() {
    let (priv_b64, pub_b64) = generate_keypair();
    let plaintext =
        r#"{"format_version":1,"profile_type":"client","servers":[],"admin_servers":[]}"#;

    let envelope = take_string(paranoia_ecies_encrypt(
        cs(&pub_b64).as_ptr(),
        cs(plaintext).as_ptr(),
    ))
    .expect("encrypt must succeed");

    // Конверт — валидный JSON с полями v, eph_pub, nonce, ct
    assert!(envelope.contains("\"v\":1"), "envelope must have version field");
    assert!(envelope.contains("eph_pub"), "envelope must have eph_pub");
    assert!(envelope.contains("nonce"), "envelope must have nonce");
    assert!(envelope.contains("\"ct\""), "envelope must have ciphertext");

    let decrypted = take_string(paranoia_ecies_decrypt(
        cs(&priv_b64).as_ptr(),
        cs(&envelope).as_ptr(),
    ))
    .expect("decrypt must succeed");

    assert_eq!(decrypted, plaintext, "decrypted must match original");
}

#[test]
fn ecies_wrong_key_returns_null_with_error() {
    let (_priv1, pub1_b64) = generate_keypair();
    let (priv2_b64, _pub2) = generate_keypair();

    let envelope = take_string(paranoia_ecies_encrypt(
        cs(&pub1_b64).as_ptr(),
        cs("secret").as_ptr(),
    ))
    .expect("encrypt must succeed");

    // Расшифровываем неверным ключом
    let result = paranoia_ecies_decrypt(cs(&priv2_b64).as_ptr(), cs(&envelope).as_ptr());
    assert!(result.is_null(), "decrypt with wrong key must return null");
    assert_eq!(last_error(), "ecies_decrypt_error");
}

#[test]
fn ecies_invalid_key_returns_error() {
    let result = paranoia_ecies_pubkey(cs("not-a-valid-base64-key!!!").as_ptr());
    assert!(result.is_null(), "invalid key must return null");
    assert_eq!(last_error(), "invalid_device_key");
}
