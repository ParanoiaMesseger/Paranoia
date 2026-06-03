//! Локальное хранилище: PIN → Argon2id → master_key (RAM) → HKDF подключи.
//! Спецификация: LocalStorageEncryptionPolicy.md в корне репо.

pub mod crypto;
pub mod io;
#[cfg(feature = "pkcs11")]
pub mod pkcs11;
pub mod state;
pub mod vault;

pub use io::{
    decrypt_attachment, decrypt_json_bytes, decrypt_json_from_disk, encrypt_attachment,
    encrypt_json_bytes, encrypt_json_to_disk, ATTACHMENT_HKDF_INFO,
};
pub use state::VaultState;
pub use vault::{
    lock, lockout_remaining_secs, recover_pending_rekey, rekey_abort, rekey_attachment,
    rekey_begin, rekey_commit, rekey_db, rekey_file, set_pin, status, unlock, verify_pin,
    with_db_key, with_files_key, with_json_key, VaultStatus,
};
#[cfg(feature = "pkcs11")]
pub use vault::{init_token, unlock_token};
