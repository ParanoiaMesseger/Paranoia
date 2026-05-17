use anyhow::{Context, bail};
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, fs, path::Path};

#[derive(Debug, Serialize, Deserialize)]
pub struct Config {
    pub port: u16,
    pub store_path: String,
    pub admin_key: String, // base64 Ed25519 pubkey (32 bytes)
    #[serde(default)]
    pub users: HashMap<String, String>, // username -> base64 pubkey
    /// UDP-адрес для встроенного STUN-сервера (формат `ip:port`). Если
    /// `null`/отсутствует — STUN-листенер не запускается. По умолчанию
    /// `0.0.0.0:3478` (стандартный STUN-порт).
    #[serde(default = "default_stun_bind")]
    pub stun_bind: Option<String>,
    /// Публичный IP, который TURN отдаёт в XOR-RELAYED-ADDRESS. Нужен, если
    /// `stun_bind` слушает `0.0.0.0`; если не задан, сервер отдаёт локальный
    /// адрес relay-сокета, а клиент попробует заменить unspecified IP хостом
    /// TURN-сервера.
    #[serde(default)]
    pub turn_public_ip: Option<String>,
}

fn default_stun_bind() -> Option<String> {
    Some("0.0.0.0:3478".to_string())
}

impl Config {
    pub fn load(path: &str) -> anyhow::Result<Self> {
        if !Path::new(path).exists() {
            let default = Self::default();
            default.save(path)?;
            return Ok(default);
        }
        let data =
            fs::read_to_string(path).with_context(|| format!("Cannot read config: {path}"))?;
        let cfg: Self = serde_json::from_str(&data).with_context(|| "Config JSON parse error")?;
        // Validate admin key
        let admin_bytes = B64
            .decode(&cfg.admin_key)
            .context("admin_key is not valid base64")?;
        if admin_bytes.len() != 32 {
            bail!("admin_key must be 32 bytes, got {}", admin_bytes.len());
        }
        Ok(cfg)
    }

    pub fn save(&self, path: &str) -> anyhow::Result<()> {
        if let Some(parent) = Path::new(path).parent() {
            fs::create_dir_all(parent)?;
        }
        let data = serde_json::to_string_pretty(self)?;
        fs::write(path, data)?;
        Ok(())
    }

    /// Decoded admin pubkey bytes (32 bytes).
    pub fn admin_pubkey_bytes(&self) -> anyhow::Result<[u8; 32]> {
        let v = B64.decode(&self.admin_key)?;
        Ok(v.try_into()
            .map_err(|_| anyhow::anyhow!("Bad admin key len"))?)
    }

    /// Decoded user pubkey bytes (32 bytes), None if not registered.
    pub fn user_pubkey_bytes(&self, username: &str) -> Option<[u8; 32]> {
        let b64 = self.users.get(username)?;
        let v = B64.decode(b64).ok()?;
        v.try_into().ok()
    }
}

impl Default for Config {
    fn default() -> Self {
        Self {
            port: 1455,
            store_path: "store".into(),
            admin_key: String::new(),
            users: HashMap::new(),
            stun_bind: default_stun_bind(),
            turn_public_ip: None,
        }
    }
}
