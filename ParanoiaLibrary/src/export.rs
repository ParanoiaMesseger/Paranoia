// Шифрованный экспорт/импорт keyring
//
// Схема: эфемерный X25519 ECDH + HKDF-SHA256 + ChaCha20-Poly1305 (ECIES).
// Отправитель шифрует на публичном ключе принимающего устройства.
// Принимающее устройство расшифровывает своим приватным ключом.
//
// Формат файла: JSON-конверт, описанный EciesEnvelope.
// Полезная нагрузка: UTF-8 JSON (ExportPayload), структура описана ниже.
use anyhow::{Context, Result, anyhow, bail};
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use chacha20poly1305::aead::Aead;
use chacha20poly1305::{ChaCha20Poly1305, KeyInit, Nonce};
use hkdf::Hkdf;
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use std::collections::HashSet;
use x25519_dalek::{PublicKey, StaticSecret};

const ECIES_VERSION: u8 = 1;
const HKDF_INFO: &[u8] = b"Paranoia ECIES v1";
pub const EXPORT_PAYLOAD_VERSION: u8 = 1;
pub const MAX_EXPORT_SERVERS: usize = 16;
pub const MAX_EXPORT_ADMIN_SERVERS: usize = 16;
pub const MAX_EXPORT_DIALOGUES: usize = 1024;
pub const MAX_EXPORT_KEY_ENTRIES: usize = 8192;

// ── Структуры файла-конверта ─────────────────────────────────────────────────

#[derive(Serialize, Deserialize)]
struct EciesEnvelope {
    v: u8,
    eph_pub: String,
    nonce: String,
    ct: String,
}

// ── Структуры полезной нагрузки экспорта ────────────────────────────────────

#[derive(Debug, Serialize, Deserialize)]
pub struct ExportKeyEntry {
    pub start_seq: u64,
    pub key: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ExportDialogue {
    pub peer: String,
    pub keyring: Vec<ExportKeyEntry>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ExportServer {
    pub url: String,
    pub username: String,
    pub signing_key_b64: String,
    pub dialogues: Vec<ExportDialogue>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ExportAdminServer {
    pub url: String,
    pub admin_private_key_b64: String,
}

/// Тип профиля экспорта (X1c).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ExportProfileType {
    Client,
    Admin,
    Full,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ExportPayload {
    pub format_version: u8,
    pub profile_type: ExportProfileType,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub servers: Vec<ExportServer>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub admin_servers: Vec<ExportAdminServer>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ExportPayloadStats {
    pub servers: usize,
    pub admin_servers: usize,
    pub dialogues: usize,
    pub key_entries: usize,
}

/// Проверить payload экспорта перед импортом.
///
/// Валидация ограничивает размер вложенных списков и проверяет формат ключей, но
/// не меняет криптографическую модель или формат экспортного контейнера.
pub fn validate_export_payload(payload: &ExportPayload) -> Result<ExportPayloadStats> {
    if payload.format_version != EXPORT_PAYLOAD_VERSION {
        bail!("unsupported export payload version");
    }
    if payload.servers.len() > MAX_EXPORT_SERVERS {
        bail!("too many export servers");
    }
    if payload.admin_servers.len() > MAX_EXPORT_ADMIN_SERVERS {
        bail!("too many export admin servers");
    }

    let mut stats = ExportPayloadStats {
        servers: payload.servers.len(),
        admin_servers: payload.admin_servers.len(),
        dialogues: 0,
        key_entries: 0,
    };

    for server in &payload.servers {
        if server.url.trim().is_empty() || server.username.trim().is_empty() {
            bail!("empty export server identity");
        }
        decode_fixed_b64(&server.signing_key_b64, 32).context("invalid client signing key")?;
        if stats.dialogues + server.dialogues.len() > MAX_EXPORT_DIALOGUES {
            bail!("too many export dialogues");
        }
        stats.dialogues += server.dialogues.len();

        let mut peers = HashSet::new();
        for dialogue in &server.dialogues {
            if dialogue.peer.trim().is_empty() {
                bail!("empty export dialogue peer");
            }
            if !peers.insert(dialogue.peer.as_str()) {
                bail!("duplicate export dialogue peer");
            }
            if dialogue.keyring.is_empty() {
                bail!("empty export dialogue keyring");
            }
            if stats.key_entries + dialogue.keyring.len() > MAX_EXPORT_KEY_ENTRIES {
                bail!("too many export keyring entries");
            }
            stats.key_entries += dialogue.keyring.len();

            let mut start_seqs = HashSet::new();
            for entry in &dialogue.keyring {
                if entry.start_seq == 0 {
                    bail!("invalid export keyring start_seq");
                }
                if !start_seqs.insert(entry.start_seq) {
                    bail!("duplicate export keyring start_seq");
                }
                decode_fixed_b64(&entry.key, 32).context("invalid export dialogue key")?;
            }
        }
    }

    for admin in &payload.admin_servers {
        if admin.url.trim().is_empty() {
            bail!("empty export admin server url");
        }
        decode_fixed_b64(&admin.admin_private_key_b64, 32)
            .context("invalid export admin private key")?;
    }

    Ok(stats)
}

// ── Генерация device keypair ─────────────────────────────────────────────────

/// Сгенерировать X25519 device keypair для шифрования экспорта.
/// Возвращает (private_key_bytes, pubkey_bytes).
pub fn generate_device_keypair() -> ([u8; 32], [u8; 32]) {
    let mut priv_bytes = [0u8; 32];
    rand::fill(&mut priv_bytes);
    let secret = StaticSecret::from(priv_bytes);
    let pubkey = *PublicKey::from(&secret).as_bytes();
    (priv_bytes, pubkey)
}

/// Вывести публичный ключ из приватного.
pub fn pubkey_from_private_key(priv_bytes: &[u8; 32]) -> [u8; 32] {
    *PublicKey::from(&StaticSecret::from(*priv_bytes)).as_bytes()
}

// ── ECIES encrypt / decrypt ──────────────────────────────────────────────────

/// Зашифровать произвольные байты на публичном ключе принимающего устройства.
/// Возвращает JSON-строку EciesEnvelope.
pub fn ecies_encrypt(receiver_pub: &[u8; 32], plaintext: &[u8]) -> Result<String> {
    let mut eph_priv_bytes = [0u8; 32];
    rand::fill(&mut eph_priv_bytes);
    let eph_secret = StaticSecret::from(eph_priv_bytes);
    let eph_pub_bytes = *PublicKey::from(&eph_secret).as_bytes();

    let receiver_pub_key = PublicKey::from(*receiver_pub);
    let shared = eph_secret.diffie_hellman(&receiver_pub_key);
    if shared.as_bytes().iter().all(|b| *b == 0) {
        bail!("non-contributory ECDH shared secret");
    }

    let enc_key = derive_enc_key(shared.as_bytes(), &eph_pub_bytes, receiver_pub)?;
    let cipher =
        ChaCha20Poly1305::new_from_slice(&enc_key).map_err(|_| anyhow!("invalid key length"))?;

    let mut nonce_bytes = [0u8; 12];
    rand::fill(&mut nonce_bytes);
    let nonce = Nonce::from_slice(&nonce_bytes);

    let ct = cipher
        .encrypt(nonce, plaintext)
        .map_err(|_| anyhow!("ECIES encryption failed"))?;

    let envelope = EciesEnvelope {
        v: ECIES_VERSION,
        eph_pub: B64.encode(eph_pub_bytes),
        nonce: B64.encode(nonce_bytes),
        ct: B64.encode(&ct),
    };
    serde_json::to_string(&envelope).context("serialize ECIES envelope")
}

/// Расшифровать JSON-конверт EciesEnvelope приватным ключом устройства.
pub fn ecies_decrypt(device_priv: &[u8; 32], json_envelope: &str) -> Result<Vec<u8>> {
    let envelope: EciesEnvelope =
        serde_json::from_str(json_envelope).context("invalid ECIES envelope JSON")?;
    if envelope.v != ECIES_VERSION {
        bail!("unsupported ECIES version {}", envelope.v);
    }

    let eph_pub_bytes: [u8; 32] = B64
        .decode(&envelope.eph_pub)
        .context("invalid eph_pub base64")?
        .try_into()
        .map_err(|_| anyhow!("invalid eph_pub length"))?;
    let nonce_bytes: [u8; 12] = B64
        .decode(&envelope.nonce)
        .context("invalid nonce base64")?
        .try_into()
        .map_err(|_| anyhow!("invalid nonce length"))?;
    let ct = B64
        .decode(&envelope.ct)
        .context("invalid ciphertext base64")?;

    let device_secret = StaticSecret::from(*device_priv);
    let device_pub_bytes = *PublicKey::from(&device_secret).as_bytes();
    let eph_pub = PublicKey::from(eph_pub_bytes);
    let shared = device_secret.diffie_hellman(&eph_pub);
    if shared.as_bytes().iter().all(|b| *b == 0) {
        bail!("non-contributory ECDH shared secret");
    }

    let enc_key = derive_enc_key(shared.as_bytes(), &eph_pub_bytes, &device_pub_bytes)?;
    let cipher =
        ChaCha20Poly1305::new_from_slice(&enc_key).map_err(|_| anyhow!("invalid key length"))?;
    let nonce = Nonce::from_slice(&nonce_bytes);

    cipher
        .decrypt(nonce, ct.as_ref())
        .map_err(|_| anyhow!("ECIES decryption failed"))
}

// ── Вспомогательные функции ──────────────────────────────────────────────────

fn derive_enc_key(
    shared: &[u8; 32],
    eph_pub: &[u8; 32],
    receiver_pub: &[u8; 32],
) -> Result<[u8; 32]> {
    let salt: Vec<u8> = eph_pub.iter().chain(receiver_pub.iter()).copied().collect();
    let hk = Hkdf::<Sha256>::new(Some(&salt), shared);
    let mut key = [0u8; 32];
    hk.expand(HKDF_INFO, &mut key)
        .map_err(|_| anyhow!("hkdf expand"))?;
    Ok(key)
}

fn decode_fixed_b64(value: &str, expected_len: usize) -> Result<Vec<u8>> {
    let decoded = B64.decode(value.trim()).context("invalid base64")?;
    if decoded.len() != expected_len {
        bail!("invalid decoded length");
    }
    Ok(decoded)
}

// ── Тесты ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ecies_roundtrip() {
        let (priv_bytes, pub_bytes) = generate_device_keypair();
        let plaintext = b"hello ecies";

        let envelope_json = ecies_encrypt(&pub_bytes, plaintext).expect("encrypt");
        let decrypted = ecies_decrypt(&priv_bytes, &envelope_json).expect("decrypt");

        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn wrong_key_fails_decryption() {
        let (_priv1, pub1) = generate_device_keypair();
        let (priv2, _pub2) = generate_device_keypair();

        let envelope_json = ecies_encrypt(&pub1, b"secret data").expect("encrypt");
        let err = ecies_decrypt(&priv2, &envelope_json).unwrap_err();
        assert!(err.to_string().contains("decryption failed"));
    }

    #[test]
    fn pubkey_derived_from_private_key() {
        let (priv_bytes, pub_bytes) = generate_device_keypair();
        assert_eq!(pubkey_from_private_key(&priv_bytes), pub_bytes);
    }

    #[test]
    fn ecies_envelope_is_valid_json() {
        let (_priv, pub_bytes) = generate_device_keypair();
        let json = ecies_encrypt(&pub_bytes, b"test").expect("encrypt");
        let envelope: EciesEnvelope = serde_json::from_str(&json).expect("parse");
        assert_eq!(envelope.v, 1);
        assert!(!envelope.eph_pub.is_empty());
        assert!(!envelope.nonce.is_empty());
        assert!(!envelope.ct.is_empty());
    }

    #[test]
    fn export_payload_roundtrip() {
        let payload = ExportPayload {
            format_version: EXPORT_PAYLOAD_VERSION,
            profile_type: ExportProfileType::Client,
            servers: vec![ExportServer {
                url: "https://server.example.com".into(),
                username: "alice".into(),
                signing_key_b64: B64.encode([1u8; 32]),
                dialogues: vec![ExportDialogue {
                    peer: "bob".into(),
                    keyring: vec![ExportKeyEntry {
                        start_seq: 1,
                        key: B64.encode([0u8; 32]),
                    }],
                }],
            }],
            admin_servers: vec![],
        };

        let json = serde_json::to_string(&payload).expect("serialize");
        let decoded: ExportPayload = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(decoded.servers[0].username, "alice");
        assert_eq!(decoded.servers[0].dialogues[0].keyring[0].start_seq, 1);
    }

    #[test]
    fn export_payload_validation_accepts_full_profile() {
        let payload = ExportPayload {
            format_version: EXPORT_PAYLOAD_VERSION,
            profile_type: ExportProfileType::Full,
            servers: vec![ExportServer {
                url: "https://server.example.com".into(),
                username: "alice".into(),
                signing_key_b64: B64.encode([1u8; 32]),
                dialogues: vec![ExportDialogue {
                    peer: "bob".into(),
                    keyring: vec![
                        ExportKeyEntry {
                            start_seq: 1,
                            key: B64.encode([2u8; 32]),
                        },
                        ExportKeyEntry {
                            start_seq: 42,
                            key: B64.encode([3u8; 32]),
                        },
                    ],
                }],
            }],
            admin_servers: vec![ExportAdminServer {
                url: "https://server.example.com".into(),
                admin_private_key_b64: B64.encode([4u8; 32]),
            }],
        };

        let stats = validate_export_payload(&payload).expect("valid payload");
        assert_eq!(stats.servers, 1);
        assert_eq!(stats.admin_servers, 1);
        assert_eq!(stats.dialogues, 1);
        assert_eq!(stats.key_entries, 2);
    }

    #[test]
    fn export_payload_validation_rejects_duplicate_start_seq() {
        let payload = ExportPayload {
            format_version: EXPORT_PAYLOAD_VERSION,
            profile_type: ExportProfileType::Client,
            servers: vec![ExportServer {
                url: "https://server.example.com".into(),
                username: "alice".into(),
                signing_key_b64: B64.encode([1u8; 32]),
                dialogues: vec![ExportDialogue {
                    peer: "bob".into(),
                    keyring: vec![
                        ExportKeyEntry {
                            start_seq: 1,
                            key: B64.encode([2u8; 32]),
                        },
                        ExportKeyEntry {
                            start_seq: 1,
                            key: B64.encode([3u8; 32]),
                        },
                    ],
                }],
            }],
            admin_servers: vec![],
        };

        let err = validate_export_payload(&payload).unwrap_err();
        assert!(err.to_string().contains("duplicate"));
    }

    #[test]
    fn export_payload_validation_rejects_bad_private_keys() {
        let payload = ExportPayload {
            format_version: EXPORT_PAYLOAD_VERSION,
            profile_type: ExportProfileType::Admin,
            servers: vec![],
            admin_servers: vec![ExportAdminServer {
                url: "https://server.example.com".into(),
                admin_private_key_b64: B64.encode([1u8; 31]),
            }],
        };

        let err = validate_export_payload(&payload).unwrap_err();
        assert!(err.to_string().contains("admin private key"));
    }
}
