//! Состояние Vault на диске: vault.json (salt + verifier + lockout) + fresh-start wipe.

use anyhow::{anyhow, bail, Result};
use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use chrono::{DateTime, Utc};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use std::{fs, path::Path};

use super::crypto::{self, KEY_LEN, SALT_LEN};

pub const VAULT_STATE_FILE: &str = "vault.json";
const VERIFIER_PLAINTEXT: &[u8] = b"{\"v\":1,\"verifier\":\"paranoia-vault-v1\"}";

#[derive(Debug, Serialize, Deserialize)]
pub struct VaultState {
    pub v: u32,
    pub salt_b64: String,
    pub verifier_b64: String,
    #[serde(default)]
    pub failed_count: u32,
    #[serde(default)]
    pub lockout_until: Option<DateTime<Utc>>,
}

impl VaultState {
    pub fn new_fresh(salt: &[u8; SALT_LEN], verifier: &[u8]) -> Self {
        Self {
            v: 1,
            salt_b64: B64.encode(salt),
            verifier_b64: B64.encode(verifier),
            failed_count: 0,
            lockout_until: None,
        }
    }

    pub fn salt(&self) -> Result<[u8; SALT_LEN]> {
        let raw = B64
            .decode(self.salt_b64.as_bytes())
            .map_err(|e| anyhow!("vault: bad salt b64: {e}"))?;
        if raw.len() != SALT_LEN {
            bail!("vault: salt length {} != {}", raw.len(), SALT_LEN);
        }
        let mut out = [0u8; SALT_LEN];
        out.copy_from_slice(&raw);
        Ok(out)
    }

    pub fn verifier(&self) -> Result<Vec<u8>> {
        B64.decode(self.verifier_b64.as_bytes())
            .map_err(|e| anyhow!("vault: bad verifier b64: {e}"))
    }

    pub fn load(app_data_root: &Path) -> Result<Option<Self>> {
        let path = app_data_root.join(VAULT_STATE_FILE);
        match fs::read(&path) {
            Ok(bytes) => {
                let state: Self = serde_json::from_slice(&bytes)
                    .map_err(|e| anyhow!("vault.json parse: {e}"))?;
                if state.v != 1 {
                    bail!("vault.json: unsupported version {}", state.v);
                }
                Ok(Some(state))
            }
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(err) => Err(err.into()),
        }
    }

    pub fn save_atomic(&self, app_data_root: &Path) -> Result<()> {
        fs::create_dir_all(app_data_root)?;
        let path = app_data_root.join(VAULT_STATE_FILE);
        let tmp = app_data_root.join(format!("{}.tmp", VAULT_STATE_FILE));
        let bytes = serde_json::to_vec(self)?;
        fs::write(&tmp, &bytes)?;
        fs::rename(&tmp, &path)?;
        Ok(())
    }
}

/// Создать новый VaultState: сгенерировать соль, посчитать verifier через json_key.
/// Возвращает VaultState (для сохранения) и master_key (для немедленного перехода в unlocked).
pub fn fresh_state(pin: &str) -> Result<(VaultState, zeroize::Zeroizing<[u8; KEY_LEN]>)> {
    let mut salt = [0u8; SALT_LEN];
    rand::rngs::OsRng.fill_bytes(&mut salt);
    let master = crypto::derive_master(pin, &salt)?;
    let json_key = crypto::derive_subkey(&master, crypto::HKDF_INFO_JSON);
    let verifier = crypto::seal(&json_key, VERIFIER_PLAINTEXT)?;
    let state = VaultState::new_fresh(&salt, &verifier);
    Ok((state, master))
}

/// Проверить PIN: вывести master по соли, json_key, расшифровать verifier.
/// Возвращает master_key при успехе.
pub fn verify_pin(
    state: &VaultState,
    pin: &str,
) -> Result<zeroize::Zeroizing<[u8; KEY_LEN]>> {
    let salt = state.salt()?;
    let verifier = state.verifier()?;
    let master = crypto::derive_master(pin, &salt)?;
    let json_key = crypto::derive_subkey(&master, crypto::HKDF_INFO_JSON);
    let plaintext = crypto::open(&json_key, &verifier)
        .map_err(|_| anyhow!("vault: wrong pin"))?;
    if plaintext != VERIFIER_PLAINTEXT {
        bail!("vault: verifier mismatch");
    }
    Ok(master)
}

/// Расчёт текущего lockout-таймаута в секундах. 0 если можно вводить.
pub fn lockout_remaining(state: &VaultState) -> u64 {
    let Some(until) = state.lockout_until else {
        return 0;
    };
    let now = Utc::now();
    if until <= now {
        0
    } else {
        (until - now).num_seconds().max(0) as u64
    }
}

/// Действие при N-й неудачной попытке (политика §7.2).
pub enum LockoutAction {
    None,
    For(u64),                // секунды задержки, персистится в vault.json
    ExhaustedUntilRestart,   // полный lockout до перезапуска процесса; in-memory
}

pub fn lockout_for_failures(failed_count: u32) -> LockoutAction {
    match failed_count {
        0..=5 => LockoutAction::None,
        6..=10 => LockoutAction::For(30),
        11..=15 => LockoutAction::For(5 * 60),
        16..=20 => LockoutAction::For(30 * 60),
        _ => LockoutAction::ExhaustedUntilRestart,
    }
}

