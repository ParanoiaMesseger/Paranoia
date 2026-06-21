use anyhow::{Context, Result, anyhow, bail};
use base64::Engine;
use base64::engine::general_purpose::STANDARD as B64;
use serde::{Deserialize, Serialize};
use sha2::Digest;
use std::{collections::HashMap, fs, path::PathBuf};

#[derive(Serialize, Deserialize, Default)]
pub struct DialogueKeyStore {
    #[serde(default)]
    pub entries: HashMap<String, String>, // peer -> session_key_hex
    #[serde(default)]
    pub profiles: HashMap<String, ProfileDialogueStore>,
}

#[derive(Clone, Serialize, Deserialize, Default)]
pub struct ProfileDialogueStore {
    pub server_url: String,
    pub username: String,
    #[serde(default)]
    pub signing_key_b64: String,
    #[serde(default)]
    pub signing_key_ct_b64: String,
    #[serde(default)]
    pub dialogues: HashMap<String, Vec<StoredKeyEntry>>,
    /// server_id (= ключ dialogues) → отображаемое имя собеседника. Позволяет
    /// указывать `--peer` по имени, а не по hex-server_id. Формат совпадает с
    /// рантайм-стором (его пишет импорт профиля). Пусто — резолв по имени недоступен.
    #[serde(default)]
    pub names: HashMap<String, String>,
    /// Локальный ник самого профиля (для выбора профиля в TUI по имени, а не
    /// по hex-server_id). Задаётся `profile-name`. Пусто — показываем server_id.
    #[serde(default)]
    pub local_name: String,
}

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct StoredKeyEntry {
    pub start_seq: u64,
    pub key: String, // base64(32 bytes)
}

fn dialogue_store_path() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| ".".into())
        .join(".paranoia_dialogues.json")
}

pub fn load_dialogue_store() -> Result<DialogueKeyStore> {
    let path = dialogue_store_path();
    if !path.exists() {
        return Ok(DialogueKeyStore::default());
    }
    let data = fs::read(&path).context("failed to read dialogue store file")?;
    Ok(serde_json::from_slice(&data).context("failed to parse dialogue store")?)
}

pub fn save_dialogue_store(store: &DialogueKeyStore) -> Result<()> {
    let data = serde_json::to_vec_pretty(store).context("failed to serialize dialogue store")?;
    let path = dialogue_store_path();
    fs::write(&path, data).context("failed to write dialogue store file")?;
    set_owner_only_permissions(&path)?;
    Ok(())
}

#[cfg(unix)]
fn set_owner_only_permissions(path: &std::path::Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))
        .context("failed to set dialogue store permissions")
}

#[cfg(not(unix))]
fn set_owner_only_permissions(_path: &std::path::Path) -> Result<()> {
    Ok(())
}

pub fn profile_id(server_url: &str, username: &str) -> String {
    let mut hasher = sha2::Sha256::new();
    hasher.update(server_url.as_bytes());
    hasher.update(b"\n");
    hasher.update(username.as_bytes());
    hex::encode(hasher.finalize())
}

/// Задать локальный ник профиля (для выбора в TUI). Ищем по username (server_id) —
/// он уникален; профиль должен уже существовать в сторе.
pub fn set_profile_local_name(username: &str, name: &str) -> Result<()> {
    let mut store = load_dialogue_store()?;
    let p = store
        .profiles
        .values_mut()
        .find(|p| p.username == username)
        .with_context(|| format!("профиль с username={username} не найден в сторе"))?;
    p.local_name = name.trim().to_string();
    save_dialogue_store(&store)
}

/// Разрешить `peer` (имя ИЛИ hex-server_id) в server_id через профильный
/// `names`-словарь. Если peer уже ключ dialogues/names — вернуть как есть; если
/// это отображаемое имя — найти соответствующий server_id; иначе вернуть peer без
/// изменений (трактуем как прямой server_id). Регистр имени учитывается как есть.
pub fn resolve_peer_id(
    store: &DialogueKeyStore,
    server_url: &str,
    username: &str,
    peer: &str,
) -> String {
    let id = profile_id(server_url, username);
    if let Some(profile) = store.profiles.get(&id) {
        if profile.dialogues.contains_key(peer) || profile.names.contains_key(peer) {
            return peer.to_string();
        }
        for (sid, name) in &profile.names {
            if name == peer {
                return sid.clone();
            }
        }
    }
    peer.to_string()
}

pub fn profile_keyring_entries(
    store: &DialogueKeyStore,
    server_url: &str,
    username: &str,
    peer: &str,
) -> Option<Vec<StoredKeyEntry>> {
    let id = profile_id(server_url, username);
    store
        .profiles
        .get(&id)
        .and_then(|profile| profile.dialogues.get(peer))
        .filter(|entries| !entries.is_empty())
        .cloned()
}

pub fn merge_profile_keyring_entry(
    profile: &mut ProfileDialogueStore,
    peer: &str,
    entry: StoredKeyEntry,
) -> MergeOutcome {
    let entries = profile.dialogues.entry(peer.to_string()).or_default();
    for existing in entries.iter() {
        if existing.start_seq == entry.start_seq {
            if existing.key == entry.key {
                return MergeOutcome::Skipped;
            }
            return MergeOutcome::Conflict;
        }
    }
    entries.push(entry);
    entries.sort_by_key(|entry| entry.start_seq);
    MergeOutcome::Imported
}

pub fn key_entry_from_base64(start_seq: u64, key_b64: &str) -> Result<StoredKeyEntry> {
    if start_seq == 0 {
        bail!("start_seq must be positive");
    }
    let decoded = B64
        .decode(key_b64.trim())
        .context("invalid base64 dialogue key")?;
    if decoded.len() != 32 {
        bail!("dialogue key must be 32 bytes, got {}", decoded.len());
    }
    Ok(StoredKeyEntry {
        start_seq,
        key: key_b64.trim().to_string(),
    })
}

pub fn key_entry_from_hex(start_seq: u64, key_hex: &str) -> Result<StoredKeyEntry> {
    if start_seq == 0 {
        bail!("start_seq must be positive");
    }
    let bytes = hex::decode(key_hex.trim()).context("invalid hex for session_key")?;
    if bytes.len() != 32 {
        bail!("session_key must be 32 bytes, got {}", bytes.len());
    }
    Ok(StoredKeyEntry {
        start_seq,
        key: B64.encode(bytes),
    })
}

pub fn base64_entry_to_key(entry: &StoredKeyEntry) -> Result<[u8; 32]> {
    let bytes = B64
        .decode(entry.key.trim())
        .context("invalid base64 dialogue key")?;
    bytes
        .try_into()
        .map_err(|b: Vec<u8>| anyhow!("dialogue key must be 32 bytes, got {}", b.len()))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MergeOutcome {
    Imported,
    Skipped,
    Conflict,
}

pub fn set_dialogue_key(peer: &str, session_key_hex: &str) -> Result<()> {
    let bytes = hex::decode(session_key_hex.trim()).context("invalid hex for session_key")?;
    if bytes.len() != 32 {
        anyhow::bail!("session_key must be 32 bytes, got {}", bytes.len());
    }
    let mut store = load_dialogue_store()?;
    store
        .entries
        .insert(peer.to_string(), session_key_hex.trim().to_string());
    save_dialogue_store(&store)?;
    Ok(())
}
