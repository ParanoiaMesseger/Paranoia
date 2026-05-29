//! Крипто корпоративной distribution-ноды (zero-knowledge раздача связок).
//!
//! Панель шифрует связку каждого сотрудника на ключ, выведенный из его PSK, и
//! пушит шифртекст на всегда-онлайн distribution-сервис. Сервис хранит только
//! шифртекст — PSK ему не известен, расшифровать он не может. Клиент сотрудника
//! забирает блоб (доказав владение signing-ключом) и расшифровывает его своим
//! PSK.
//!
//! Формат блоба: `PCB1`(4) ‖ version_le(8) ‖ nonce(12) ‖ ciphertext+tag(16).
//! AEAD = ChaCha20-Poly1305, AAD = `PCB1` ‖ server_id_ascii ‖ version_le —
//! привязывает шифртекст к конкретному сотруднику и версии (сервер не может
//! подменить блоб между сотрудниками или незаметно склеить версии).

use anyhow::{Result, bail};
use chacha20poly1305::{
    ChaCha20Poly1305, Key, Nonce,
    aead::{Aead, KeyInit, Payload},
};
use hkdf::Hkdf;
use rand::RngCore;
use sha2::Sha256;

const MAGIC: &[u8; 4] = b"PCB1";
const ENC_INFO: &[u8] = b"paranoia:corp:enc:v1";

/// Вывести 32-байтный AEAD-ключ из PSK сотрудника.
fn enc_key(psk: &[u8], server_id: &str) -> [u8; 32] {
    // salt = server_id — привязывает производный ключ к идентичности сотрудника.
    let hk = Hkdf::<Sha256>::new(Some(server_id.as_bytes()), psk);
    let mut key = [0u8; 32];
    // expand не падает для 32 байт.
    hk.expand(ENC_INFO, &mut key)
        .expect("HKDF expand 32 bytes");
    key
}

fn aad(server_id: &str, version: u64) -> Vec<u8> {
    let mut a = Vec::with_capacity(4 + server_id.len() + 8);
    a.extend_from_slice(MAGIC);
    a.extend_from_slice(server_id.as_bytes());
    a.extend_from_slice(&version.to_le_bytes());
    a
}

/// Зашифровать связку сотрудника. Возвращает полный блоб (см. формат выше).
pub fn seal(psk: &[u8], server_id: &str, version: u64, plaintext: &[u8]) -> Result<Vec<u8>> {
    if psk.is_empty() {
        bail!("empty psk");
    }
    let key = enc_key(psk, server_id);
    let cipher = ChaCha20Poly1305::new(Key::from_slice(&key));
    let mut nonce_bytes = [0u8; 12];
    rand::rngs::OsRng.fill_bytes(&mut nonce_bytes);
    let nonce = Nonce::from_slice(&nonce_bytes);
    let ad = aad(server_id, version);
    let ct = cipher
        .encrypt(nonce, Payload { msg: plaintext, aad: &ad })
        .map_err(|e| anyhow::anyhow!("corp seal: {e}"))?;

    let mut out = Vec::with_capacity(4 + 8 + 12 + ct.len());
    out.extend_from_slice(MAGIC);
    out.extend_from_slice(&version.to_le_bytes());
    out.extend_from_slice(&nonce_bytes);
    out.extend_from_slice(&ct);
    Ok(out)
}

/// Расшифровать блоб. Возвращает (version, plaintext). Версия читается из
/// заголовка и связывается через AAD — подмена версии/идентичности ломает AEAD.
pub fn open(psk: &[u8], server_id: &str, blob: &[u8]) -> Result<(u64, Vec<u8>)> {
    if blob.len() < 4 + 8 + 12 + 16 {
        bail!("corp blob too short");
    }
    if &blob[0..4] != MAGIC {
        bail!("corp blob bad magic");
    }
    let mut vbytes = [0u8; 8];
    vbytes.copy_from_slice(&blob[4..12]);
    let version = u64::from_le_bytes(vbytes);
    let nonce_bytes = &blob[12..24];
    let ct = &blob[24..];

    let key = enc_key(psk, server_id);
    let cipher = ChaCha20Poly1305::new(Key::from_slice(&key));
    let nonce = Nonce::from_slice(nonce_bytes);
    let ad = aad(server_id, version);
    let pt = cipher
        .decrypt(nonce, Payload { msg: ct, aad: &ad })
        .map_err(|_| anyhow::anyhow!("corp open: wrong psk or tampered blob"))?;
    Ok((version, pt))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip() {
        let psk = b"0123456789abcdef0123456789abcdef";
        let sid = "a".repeat(64);
        let msg = br#"{"keyring":[{"partner":"x","key":"k"}]}"#;
        let blob = seal(psk, &sid, 7, msg).unwrap();
        let (v, pt) = open(psk, &sid, &blob).unwrap();
        assert_eq!(v, 7);
        assert_eq!(pt, msg);
    }

    #[test]
    fn wrong_psk_fails() {
        let sid = "b".repeat(64);
        let blob = seal(b"key-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", &sid, 1, b"hi").unwrap();
        assert!(open(b"key-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", &sid, &blob).is_err());
    }

    #[test]
    fn wrong_server_id_fails() {
        let psk = b"same-psk-same-psk-same-psk-same-p";
        let blob = seal(psk, &"c".repeat(64), 1, b"hi").unwrap();
        // Тот же PSK, но другой server_id → и ключ другой, и AAD другой.
        assert!(open(psk, &"d".repeat(64), &blob).is_err());
    }

    #[test]
    fn tampered_blob_fails() {
        let psk = b"tamper-psk-tamper-psk-tamper-pskk";
        let sid = "e".repeat(64);
        let mut blob = seal(psk, &sid, 3, b"payload").unwrap();
        let last = blob.len() - 1;
        blob[last] ^= 0x01;
        assert!(open(psk, &sid, &blob).is_err());
    }

    #[test]
    fn version_in_header() {
        let psk = b"verpsk-verpsk-verpsk-verpsk-verps";
        let sid = "f".repeat(64);
        let blob = seal(psk, &sid, 42, b"x").unwrap();
        let (v, _) = open(psk, &sid, &blob).unwrap();
        assert_eq!(v, 42);
    }
}
