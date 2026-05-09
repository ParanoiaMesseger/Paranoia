use anyhow::{Result, bail};
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use chacha20poly1305::{
    ChaCha20Poly1305, Key, Nonce,
    aead::{Aead, KeyInit},
};
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use sha2::{Digest, Sha256};

/// Зашифровать plaintext с помощью ChaCha20-Poly1305.
/// Возвращает: nonce(12 байт) || ciphertext
pub fn encrypt(key: &[u8; 32], plaintext: &[u8]) -> Result<Vec<u8>> {
    let cipher = ChaCha20Poly1305::new(Key::from_slice(key));
    let mut nonce_bytes = [0u8; 12];
    rand::fill(&mut nonce_bytes);
    let nonce = Nonce::from_slice(&nonce_bytes);
    let ciphertext = cipher
        .encrypt(nonce, plaintext)
        .map_err(|e| anyhow::anyhow!("Encryption failed: {e}"))?;
    let mut result = Vec::with_capacity(12 + ciphertext.len());
    result.extend_from_slice(&nonce_bytes);
    result.extend_from_slice(&ciphertext);
    Ok(result)
}

/// Расшифровать данные формата nonce(12) || ciphertext.
pub fn decrypt(key: &[u8; 32], data: &[u8]) -> Result<Vec<u8>> {
    if data.len() < 12 {
        bail!("Ciphertext too short");
    }
    let (nonce_bytes, ciphertext) = data.split_at(12);
    let cipher = ChaCha20Poly1305::new(Key::from_slice(key));
    let nonce = Nonce::from_slice(nonce_bytes);
    cipher
        .decrypt(nonce, ciphertext)
        .map_err(|_| anyhow::anyhow!("Decryption failed — wrong key or corrupted data"))
}

/// Подписать сообщение Ed25519 ключом.
pub fn sign(signing_key: &SigningKey, message: &[u8]) -> Vec<u8> {
    signing_key.sign(message).to_bytes().to_vec()
}

/// Проверить подпись.
pub fn verify(verifying_key: &VerifyingKey, message: &[u8], sig_bytes: &[u8]) -> Result<()> {
    if sig_bytes.len() != 64 {
        bail!("Signature must be 64 bytes");
    }
    let mut sig_arr = [0u8; 64];
    sig_arr.copy_from_slice(sig_bytes);
    let sig = Signature::from_bytes(&sig_arr);
    verifying_key
        .verify(message, &sig)
        .map_err(|_| anyhow::anyhow!("Invalid signature"))
}

/// Детерминированный симметричный dialogue_id = SHA256(sorted(a:b))
pub fn make_dialogue_id(a: &str, b: &str) -> String {
    let (first, second) = if a < b { (a, b) } else { (b, a) };
    let mut h = Sha256::new();
    h.update(first.as_bytes());
    h.update(b":");
    h.update(second.as_bytes());
    hex::encode(h.finalize())
}

pub fn encode_b64(data: &[u8]) -> String {
    B64.encode(data)
}

pub fn decode_b64(s: &str) -> Result<Vec<u8>> {
    B64.decode(s).map_err(|e| anyhow::anyhow!("Base64: {e}"))
}
