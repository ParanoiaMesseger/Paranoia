//! Smoke-тест distribution-ноды (ParanoiaAdminApi).
//!
//!   cargo run --example corp_smoke -- gen
//!     → печатает admin SECRET/PUBKEY (b64) для конфига ноды.
//!   cargo run --example corp_smoke -- e2e <dist_url> <admin_secret_b64>
//!     → публикует блоб сотрудника, забирает его обратно, проверяет owner-proof
//!       и anti-rollback.

use base64::{Engine, engine::general_purpose::STANDARD as B64};
use ed25519_dalek::SigningKey;
use paranoia_lib::{AdminKeyPair, corp, corp_api};
use sha2::{Digest, Sha256};

fn server_id_from_seed(seed: &[u8; 32]) -> String {
    let sk = SigningKey::from_bytes(seed);
    let pk = sk.verifying_key().to_bytes();
    let mut h = Sha256::new();
    h.update(b"paranoia:server-id:v1\n");
    h.update(pk);
    hex::encode(h.finalize())
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("gen") => {
            let kp = AdminKeyPair::generate();
            println!("SECRET={}", kp.secret_b64());
            println!("PUBKEY={}", kp.pubkey_b64());
        }
        Some("e2e") => {
            let dist = &args[2];
            let admin_secret = &args[3];

            // Сотрудник: фиксированный seed → server_id + signing_key_b64.
            let seed = [42u8; 32];
            let server_id = server_id_from_seed(&seed);
            let signing_key_b64 = B64.encode(seed);
            // PSK сотрудника.
            let psk = [7u8; 32];
            let psk_b64 = B64.encode(psk);

            let plaintext = r#"{"username":"emp","keyring":[{"partner":"x","key":"k"}]}"#;
            let version: u64 = 1000;

            // publish v1000
            let blob = corp::seal(&psk, &server_id, version, plaintext.as_bytes()).unwrap();
            let blob_b64 = B64.encode(&blob);
            match corp_api::corp_push(dist, admin_secret, &server_id, version, &blob_b64) {
                Ok(r) => println!("[push v{version}] {r}"),
                Err(e) => {
                    println!("[push] FAIL {e}");
                    std::process::exit(1);
                }
            }

            // sync → должно совпасть с plaintext
            match corp_api::corp_sync(dist, &server_id, &signing_key_b64, &psk_b64) {
                Ok(pt) if pt == plaintext => println!("[sync] OK round-trip совпал"),
                Ok(pt) => {
                    println!("[sync] MISMATCH: {pt}");
                    std::process::exit(1);
                }
                Err(e) => {
                    println!("[sync] FAIL {e}");
                    std::process::exit(1);
                }
            }

            // anti-rollback: повторный push той же версии → stale_version
            match corp_api::corp_push(dist, admin_secret, &server_id, version, &blob_b64) {
                Err(e) if e.to_string().contains("stale_version") => println!("[rollback] OK отклонён: {e}"),
                Ok(r) => {
                    println!("[rollback] ДОЛЖЕН был отклониться, но прошёл: {r}");
                    std::process::exit(1);
                }
                Err(e) => {
                    println!("[rollback] отклонён (иной код): {e}");
                }
            }

            // owner-proof: чужой ключ читает чужой server_id → ошибка
            let other_seed = [99u8; 32];
            let other_sk_b64 = B64.encode(other_seed);
            match corp_api::corp_sync(dist, &server_id, &other_sk_b64, &psk_b64) {
                Err(e) => println!("[owner-proof] OK чужой ключ отклонён: {e}"),
                Ok(_) => {
                    println!("[owner-proof] ПРОВАЛ: чужой ключ прочитал блоб");
                    std::process::exit(1);
                }
            }

            println!("ALL OK");
        }
        Some("commercial") => {
            let dist = &args[2];
            let admin_secret = &args[3];
            let data = r#"{"clients":[{"username":"c1","status":"active"}],"stats":{"clients":1,"active":1}}"#;
            match corp_api::commercial_push(dist, admin_secret, data) {
                Ok(r) => println!("[commercial push] {r}"),
                Err(e) => {
                    println!("[commercial push] FAIL {e}");
                    std::process::exit(1);
                }
            }
            println!("COMMERCIAL OK");
        }
        _ => {
            eprintln!("usage: corp_smoke gen | e2e <dist_url> <admin_secret_b64>");
            std::process::exit(2);
        }
    }
}
