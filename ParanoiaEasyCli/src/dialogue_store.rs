use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, fs, path::PathBuf};

#[derive(Serialize, Deserialize, Default)]
pub struct DialogueKeyStore {
    pub entries: HashMap<String, String>, // peer -> session_key_hex
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
    let data =
        serde_json::to_vec_pretty(store).context("failed to serialize dialogue store")?;
    fs::write(dialogue_store_path(), data).context("failed to write dialogue store file")?;
    Ok(())
}

pub fn set_dialogue_key(peer: &str, session_key_hex: &str) -> Result<()> {
    let bytes =
        hex::decode(session_key_hex.trim()).context("invalid hex for session_key")?;
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
