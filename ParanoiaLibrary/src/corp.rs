//! Крипто корпоративной distribution-ноды (zero-knowledge раздача связок).
//!
//! Панель шифрует связку каждого сотрудника на ключ, выведенный из его PSK, и
//! пушит шифртекст на всегда-онлайн distribution-сервис. Сервис хранит только
//! шифртекст — PSK ему не известен, расшифровать он не может. Клиент сотрудника
//! забирает блоб (доказав владение signing-ключом) и расшифровывает его своим
//! PSK.
//!
//! Формат блоба: `PCB1`(4) ‖ version_le(8) ‖ nonce(12) ‖ ciphertext+tag(16).
//! AEAD = ChaCha20-Poly1305, AAD = `PCB1` ‖ server_id_ascii ‖ version_le ‖
//! `context` — привязывает шифртекст к конкретному сотруднику, версии И «контексту»
//! (сервер не может подменить блоб между сотрудниками, незаметно склеить версии,
//! а с непустым `context` — ещё и подсунуть блоб одного диалога вместо другого).
//!
//! `context` (ленивая раздача ключей, 2026-06-25): для цельной связки он пуст
//! (`b""`) — формат байт-в-байт прежний. Для пер-диалоговой раздачи в `context`
//! идёт server_id партнёра → ключ одного диалога нельзя выдать под другим диалогом.
//! Ростер (список доступных диалогов без ключей) запечатывается с `context=b"roster"`.

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

/// Контекст цельной связки (или одиночного блоба совместимости): пуст → AAD
/// байт-в-байт как в прежнем формате. Используется на legacy-пути «вся связка».
pub const CTX_KEYRING: &[u8] = b"";
/// Контекст ростера — список доступных диалогов БЕЗ ключей (ленивая раздача).
pub const CTX_ROSTER: &[u8] = b"roster";
/// Префикс контекста пер-диалогового блоба: к нему добавляется server_id партнёра
/// (`ctx_dialogue`). Делает блоб одного диалога неподменяемым на другой.
const CTX_DIALOGUE_PREFIX: &[u8] = b"dlg:";

/// Контекст пер-диалогового ключевого блоба = `dlg:<partner_server_id>`.
pub fn ctx_dialogue(partner_server_id: &str) -> Vec<u8> {
    let mut c = Vec::with_capacity(CTX_DIALOGUE_PREFIX.len() + partner_server_id.len());
    c.extend_from_slice(CTX_DIALOGUE_PREFIX);
    c.extend_from_slice(partner_server_id.as_bytes());
    c
}

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

fn aad(server_id: &str, version: u64, context: &[u8]) -> Vec<u8> {
    let mut a = Vec::with_capacity(4 + server_id.len() + 8 + context.len());
    a.extend_from_slice(MAGIC);
    a.extend_from_slice(server_id.as_bytes());
    a.extend_from_slice(&version.to_le_bytes());
    a.extend_from_slice(context);
    a
}

/// Зашифровать блоб сотрудника. `context` привязывает блоб к назначению
/// ([`CTX_KEYRING`] — вся связка, байт-в-байт прежний формат; [`CTX_ROSTER`] —
/// ростер; [`ctx_dialogue`] — ключ одного диалога). Возвращает полный блоб.
pub fn seal(
    psk: &[u8],
    server_id: &str,
    version: u64,
    context: &[u8],
    plaintext: &[u8],
) -> Result<Vec<u8>> {
    if psk.is_empty() {
        bail!("empty psk");
    }
    let key = enc_key(psk, server_id);
    let cipher = ChaCha20Poly1305::new(Key::from_slice(&key));
    let mut nonce_bytes = [0u8; 12];
    rand::rngs::OsRng.fill_bytes(&mut nonce_bytes);
    let nonce = Nonce::from_slice(&nonce_bytes);
    let ad = aad(server_id, version, context);
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
/// заголовка и связывается через AAD — подмена версии/идентичности/контекста
/// ломает AEAD. `context` — ОЖИДАЕМОЕ назначение блоба (вызывающий обязан знать,
/// какого диалога/ростера он просит); несовпадение → ошибка дешифровки, поэтому
/// нода не может выдать блоб одного диалога вместо другого.
pub fn open(psk: &[u8], server_id: &str, context: &[u8], blob: &[u8]) -> Result<(u64, Vec<u8>)> {
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
    let ad = aad(server_id, version, context);
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
        let blob = seal(psk, &sid, 7, CTX_KEYRING, msg).unwrap();
        let (v, pt) = open(psk, &sid, CTX_KEYRING, &blob).unwrap();
        assert_eq!(v, 7);
        assert_eq!(pt, msg);
    }

    #[test]
    fn wrong_psk_fails() {
        let sid = "b".repeat(64);
        let blob = seal(b"key-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", &sid, 1, CTX_KEYRING, b"hi").unwrap();
        assert!(open(b"key-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", &sid, CTX_KEYRING, &blob).is_err());
    }

    #[test]
    fn wrong_server_id_fails() {
        let psk = b"same-psk-same-psk-same-psk-same-p";
        let blob = seal(psk, &"c".repeat(64), 1, CTX_KEYRING, b"hi").unwrap();
        // Тот же PSK, но другой server_id → и ключ другой, и AAD другой.
        assert!(open(psk, &"d".repeat(64), CTX_KEYRING, &blob).is_err());
    }

    #[test]
    fn tampered_blob_fails() {
        let psk = b"tamper-psk-tamper-psk-tamper-pskk";
        let sid = "e".repeat(64);
        let mut blob = seal(psk, &sid, 3, CTX_KEYRING, b"payload").unwrap();
        let last = blob.len() - 1;
        blob[last] ^= 0x01;
        assert!(open(psk, &sid, CTX_KEYRING, &blob).is_err());
    }

    #[test]
    fn version_in_header() {
        let psk = b"verpsk-verpsk-verpsk-verpsk-verps";
        let sid = "f".repeat(64);
        let blob = seal(psk, &sid, 42, CTX_KEYRING, b"x").unwrap();
        let (v, _) = open(psk, &sid, CTX_KEYRING, &blob).unwrap();
        assert_eq!(v, 42);
    }

    #[test]
    fn ctx_keyring_is_byte_compatible_with_empty() {
        // CTX_KEYRING == b"" → AAD не меняется относительно прежнего формата.
        assert_eq!(CTX_KEYRING, b"");
    }

    #[test]
    fn wrong_context_fails() {
        // Блоб, запечатанный для одного диалога, нельзя открыть как другой —
        // нода не может подсунуть ключ диалога с Bob под видом диалога с Carol.
        let psk = b"ctxpsk-ctxpsk-ctxpsk-ctxpsk-ctxps";
        let sid = "1".repeat(64);
        let bob = "b".repeat(64);
        let carol = "c".repeat(64);
        let blob = seal(psk, &sid, 1, &ctx_dialogue(&bob), b"bob-key").unwrap();
        // Правильный контекст — ок.
        assert!(open(psk, &sid, &ctx_dialogue(&bob), &blob).is_ok());
        // Чужой контекст (другой партнёр) — ошибка AEAD.
        assert!(open(psk, &sid, &ctx_dialogue(&carol), &blob).is_err());
        // Контекст ростера вместо диалога — тоже ошибка.
        assert!(open(psk, &sid, CTX_ROSTER, &blob).is_err());
        // И наоборот: цельная связка (CTX_KEYRING) не откроется как диалог.
        let kr = seal(psk, &sid, 1, CTX_KEYRING, b"all-keys").unwrap();
        assert!(open(psk, &sid, &ctx_dialogue(&bob), &kr).is_err());
    }

    #[test]
    fn roster_context_round_trip() {
        let psk = b"rospsk-rospsk-rospsk-rospsk-rosps";
        let sid = "2".repeat(64);
        let roster = br#"{"full_name":"Ivanov","roster":[{"username":"bob","full_name":"Bob"}]}"#;
        let blob = seal(psk, &sid, 5, CTX_ROSTER, roster).unwrap();
        let (v, pt) = open(psk, &sid, CTX_ROSTER, &blob).unwrap();
        assert_eq!(v, 5);
        assert_eq!(pt, roster);
    }
}
