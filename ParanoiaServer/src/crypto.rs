use anyhow::{bail, Result};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use sha2::{Digest, Sha256};

pub fn verify_signature(pubkey_bytes: &[u8; 32], message: &[u8], sig_bytes: &[u8]) -> Result<()> {
    if sig_bytes.len() != 64 {
        bail!("Signature must be 64 bytes, got {}", sig_bytes.len());
    }
    let verifying_key =
        VerifyingKey::from_bytes(pubkey_bytes).map_err(|e| anyhow::anyhow!("Bad public key: {e}"))?;
    let sig_arr: [u8; 64] = sig_bytes.try_into().unwrap();
    let signature = Signature::from_bytes(&sig_arr);
    verifying_key
        .verify(message, &signature)
        .map_err(|_| anyhow::anyhow!("Invalid signature"))
}

pub fn make_dialogue_id(a: &str, b: &str) -> String {
    let (first, second) = if a < b { (a, b) } else { (b, a) };
    let mut hasher = Sha256::new();
    hasher.update(first.as_bytes());
    hasher.update(b":");
    hasher.update(second.as_bytes());
    hex::encode(hasher.finalize())
}

pub fn decode_b64(s: &str) -> Result<Vec<u8>> {
    B64.decode(s).map_err(|e| anyhow::anyhow!("Base64 decode error: {e}"))
}

pub fn encode_b64(data: &[u8]) -> String {
    B64.encode(data)
}
