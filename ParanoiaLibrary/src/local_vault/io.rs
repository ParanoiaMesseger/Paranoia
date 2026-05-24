//! Зашифрованное IO для JSON-файлов и attachments.
//! Все ключи берутся из активного `vault`.

use anyhow::{anyhow, bail, Result};
use std::{
    fs,
    path::{Path, PathBuf},
};

use super::{crypto, vault};

pub const ATTACHMENT_HKDF_INFO: &[u8] = b"attachment-v1";

const FILE_MAGIC: &[u8; 4] = b"PVL1"; // Paranoia Vault Local v1

fn write_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let tmp: PathBuf = match path.file_name() {
        Some(name) => path.with_file_name(format!("{}.tmp", name.to_string_lossy())),
        None => bail!("invalid path: {:?}", path),
    };
    fs::write(&tmp, bytes)?;
    fs::rename(&tmp, path)?;
    Ok(())
}

/// Зашифровать байты JSON (или любые plaintext bytes) текущим json_key.
pub fn encrypt_json_bytes(plaintext: &[u8]) -> Result<Vec<u8>> {
    let sealed = vault::with_json_key(|k| crypto::seal(k, plaintext))??;
    let mut out = Vec::with_capacity(4 + sealed.len());
    out.extend_from_slice(FILE_MAGIC);
    out.extend_from_slice(&sealed);
    Ok(out)
}

pub fn decrypt_json_bytes(ciphertext: &[u8]) -> Result<Vec<u8>> {
    if ciphertext.len() < 4 || &ciphertext[..4] != FILE_MAGIC {
        bail!("vault_io: bad magic");
    }
    let payload = &ciphertext[4..];
    vault::with_json_key(|k| crypto::open(k, payload))?
}

pub fn encrypt_json_to_disk(path: &Path, plaintext: &[u8]) -> Result<()> {
    let bytes = encrypt_json_bytes(plaintext)?;
    write_atomic(path, &bytes)?;
    Ok(())
}

pub fn decrypt_json_from_disk(path: &Path) -> Result<Vec<u8>> {
    let bytes = fs::read(path).map_err(|e| anyhow!("vault_io: read {path:?}: {e}"))?;
    decrypt_json_bytes(&bytes)
}

/// Зашифровать содержимое attachment'а через per-file ключ.
/// `salt` — обычно байты UUID сообщения (стабильный идентификатор).
pub fn encrypt_attachment(salt: &[u8], plaintext: &[u8]) -> Result<Vec<u8>> {
    let per_file = vault::with_files_key(|files_key| {
        crypto::derive_attachment_key(files_key, salt)
    })?;
    let sealed = crypto::seal(&per_file, plaintext)?;
    let mut out = Vec::with_capacity(4 + sealed.len());
    out.extend_from_slice(FILE_MAGIC);
    out.extend_from_slice(&sealed);
    Ok(out)
}

pub fn decrypt_attachment(salt: &[u8], ciphertext: &[u8]) -> Result<Vec<u8>> {
    if ciphertext.len() < 4 || &ciphertext[..4] != FILE_MAGIC {
        bail!("vault_io: bad magic");
    }
    let payload = &ciphertext[4..];
    let per_file = vault::with_files_key(|files_key| {
        crypto::derive_attachment_key(files_key, salt)
    })?;
    crypto::open(&per_file, payload)
}
