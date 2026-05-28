//! Argon2id-деривация мастер-ключа + HKDF-подключи + AEAD-обёртки.

use anyhow::{anyhow, Result};
use argon2::{Algorithm, Argon2, Params, Version};
use hkdf::Hkdf;
use sha2::Sha256;
use zeroize::Zeroizing;

pub const SALT_LEN: usize = 16;
pub const KEY_LEN: usize = 32;

// Параметры из политики (раздел 4.2).
const ARGON2_M_COST_KIB: u32 = 65536;
const ARGON2_T_COST: u32 = 3;
const ARGON2_P_COST: u32 = 1;

pub const HKDF_INFO_JSON: &[u8] = b"paranoia-json-v1";
pub const HKDF_INFO_DB: &[u8] = b"paranoia-db-v1";
pub const HKDF_INFO_FILES: &[u8] = b"paranoia-files-v1";

pub fn derive_master(pin: &str, salt: &[u8; SALT_LEN]) -> Result<Zeroizing<[u8; KEY_LEN]>> {
    let params = Params::new(ARGON2_M_COST_KIB, ARGON2_T_COST, ARGON2_P_COST, Some(KEY_LEN))
        .map_err(|e| anyhow!("argon2 params: {e}"))?;
    let argon2 = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);
    let mut out = Zeroizing::new([0u8; KEY_LEN]);
    argon2
        .hash_password_into(pin.as_bytes(), salt, out.as_mut())
        .map_err(|e| anyhow!("argon2 derive: {e}"))?;
    Ok(out)
}

pub fn derive_subkey(master: &[u8; KEY_LEN], info: &[u8]) -> Zeroizing<[u8; KEY_LEN]> {
    let hk = Hkdf::<Sha256>::new(None, master);
    let mut out = Zeroizing::new([0u8; KEY_LEN]);
    hk.expand(info, out.as_mut())
        .expect("HKDF-SHA256 with 32-byte output is always valid");
    out
}

/// HKDF от files_key c солью=uuid и info=attachment-v1 → per-file ключ.
pub fn derive_attachment_key(
    files_key: &[u8; KEY_LEN],
    salt: &[u8],
) -> Zeroizing<[u8; KEY_LEN]> {
    let hk = Hkdf::<Sha256>::new(Some(salt), files_key);
    let mut out = Zeroizing::new([0u8; KEY_LEN]);
    hk.expand(b"attachment-v1", out.as_mut())
        .expect("HKDF-SHA256 with 32-byte output is always valid");
    out
}

/// Тонкая обёртка над `crate::crypto::encrypt` / `decrypt` —
/// формат совпадает с политикой: nonce(12) || ciphertext+tag(16).
pub fn seal(key: &[u8; KEY_LEN], plaintext: &[u8]) -> Result<Vec<u8>> {
    crate::crypto::encrypt(key, plaintext)
}

pub fn open(key: &[u8; KEY_LEN], ciphertext: &[u8]) -> Result<Vec<u8>> {
    crate::crypto::decrypt(key, ciphertext)
}
