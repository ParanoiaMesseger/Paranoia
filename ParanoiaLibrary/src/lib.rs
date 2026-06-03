pub mod admin;
pub mod admin_api;
pub mod client_cover;
pub mod client_cover_food;
pub mod client_cover_schema;
pub mod corp;
pub mod corp_api;
pub mod crypto;
pub mod dialogue;
mod error_classify;
pub mod export;
pub mod ffi;
pub mod local_vault;
pub mod masking;
pub mod packet;
pub mod qr_exchange;
pub mod store;
pub mod transport;
pub mod types;
pub mod voip;
pub mod voip_ffi;

use anyhow::Result;
use std::sync::Arc;

pub use admin::AdminKeyPair;
pub use dialogue::Dialogue;
pub use types::{
    AttachmentKind, ClientConfig, DialogueConfig, DialogueKey, DialogueKeyEntry, FileAttachment,
    Message, MessageContent, MessageStatus,
};

use client_cover::ClientCover;
use client_cover_food::FoodDeliveryClientCover;
use client_cover_schema::SchemaClientCover;
use store::LocalStore;
use transport::Transport;

pub struct ParanoiaClient {
    config: Arc<ClientConfig>,
    transport: Arc<Transport>,
    store: Arc<LocalStore>,
}

/// Декодировать base64 в ровно 32 байта (Ed25519 pubkey или seed).
fn decode_32b(b64: &str) -> Result<[u8; 32]> {
    let v = crate::crypto::decode_b64(b64.trim())?;
    v.try_into()
        .map_err(|_| anyhow::anyhow!("expected 32 bytes (base64)"))
}

/// Алиас для читаемости в местах, где это публичный ключ.
fn decode_pubkey32(b64: &str) -> Result<[u8; 32]> {
    decode_32b(b64)
}

/// Подписать masking-профиль extended-секретом (base64 Ed25519 seed). Возвращает
/// JSON подписанного конверта для раздачи (архив/API). Используется панелью.
pub fn sign_masking_profile(profile_json: &str, extended_secret_b64: &str) -> Result<String> {
    let seed = decode_32b(extended_secret_b64)?;
    Ok(paranoia_cover::sign_profile(profile_json, &seed)?.to_json())
}

/// Случайная правдоподобная схема маскировки (SchemaVariant) для панели —
/// «бросить кости». Только при фиче `schema-gen`. Возвращает pretty-JSON.
#[cfg(feature = "schema-gen")]
pub fn generate_masking_schema() -> String {
    let v = paranoia_cover::generate_random_schema();
    serde_json::to_string_pretty(&v).unwrap_or_else(|_| v.to_string())
}

/// Случайный путь фейкового эндпоинта (таргет вида трафика). Только при фиче
/// `schema-gen`.
#[cfg(feature = "schema-gen")]
pub fn generate_masking_path() -> String {
    paranoia_cover::generate_random_path()
}

impl ParanoiaClient {
    pub fn new(config: ClientConfig) -> Result<Self> {
        let cover = Arc::new(FoodDeliveryClientCover::new());
        let transport = Arc::new(Transport::new(
            &config.server_url,
            config.reserve_server_urls.iter().map(String::as_str),
            cover,
        ));
        // SQLCipher: ключ берём из активного vault. Если vault locked —
        // ошибка пробрасывается наверх (UI обязан unlock'нуть до создания клиента).
        let db_path = config.db_path.clone();
        let store = Arc::new(local_vault::with_db_key(|k| LocalStore::open(&db_path, k))??);
        Ok(Self {
            config: Arc::new(config),
            transport,
            store,
        })
    }

    pub fn open_dialogue(&self, dialogue_cfg: DialogueConfig) -> Dialogue {
        Dialogue::new(
            dialogue_cfg,
            Arc::clone(&self.config),
            Arc::clone(&self.transport),
            Arc::clone(&self.store),
        )
    }

    pub fn transport(&self) -> Arc<Transport> {
        Arc::clone(&self.transport)
    }

    /// Сменить активную маскировку в рантайме. `Some(json)` — schema-cover по
    /// профилю; `None`/пусто — вернуть встроенную food-маску. Применяется
    /// мгновенно ко всем последующим запросам (мгновенная смена профиля).
    pub fn set_masking_profile(&self, profile_json: Option<&str>) -> Result<()> {
        let cover: Arc<dyn ClientCover> = match profile_json {
            Some(json) if !json.trim().is_empty() => {
                let profile = paranoia_cover::MaskingProfile::from_json(json)?;
                Arc::new(SchemaClientCover::new(Arc::new(profile)))
            }
            _ => Arc::new(FoodDeliveryClientCover::new()),
        };
        self.transport.set_cover(cover);
        Ok(())
    }

    /// Применить ПОДПИСАННЫЙ профиль (раздача): проверить подпись доверенным
    /// ключом `trusted_pubkey_b64` и только при успехе сменить маскировку.
    /// Профиль без валидной подписи доверенного ключа отвергается.
    pub fn set_signed_masking_profile(
        &self,
        signed_json: &str,
        trusted_pubkey_b64: &str,
    ) -> Result<()> {
        let trusted = decode_pubkey32(trusted_pubkey_b64)?;
        let signed = paranoia_cover::SignedProfile::from_json(signed_json)?;
        let profile = paranoia_cover::verify_profile(&signed, &trusted)?;
        self.transport
            .set_cover(Arc::new(SchemaClientCover::new(Arc::new(profile))));
        Ok(())
    }

    /// Скачать подписанный профиль с ноды (`GET url`, опц. Bearer), проверить
    /// подпись доверенным ключом и применить. Замыкает канал «подписанный API»:
    /// клиент периодически вызывает это и мгновенно меняет маскировку.
    pub async fn fetch_and_apply_signed_profile(
        &self,
        url: &str,
        trusted_pubkey_b64: &str,
        bearer_token: Option<&str>,
    ) -> Result<()> {
        let client = reqwest::Client::new();
        let mut req = client.get(url);
        if let Some(token) = bearer_token.filter(|t| !t.is_empty()) {
            req = req.header(reqwest::header::AUTHORIZATION, format!("Bearer {token}"));
        }
        let resp = req.send().await?;
        if !resp.status().is_success() {
            anyhow::bail!("fetch profile: HTTP {}", resp.status());
        }
        let signed_json = resp.text().await?;
        self.set_signed_masking_profile(&signed_json, trusted_pubkey_b64)
    }

    pub fn config(&self) -> &ClientConfig {
        &self.config
    }

    pub fn delete_local_dialogue(&self, key: &DialogueKey) -> anyhow::Result<()> {
        self.store.delete_dialogue(key)
    }

    pub fn last_pulled_seq(&self, key: &DialogueKey) -> anyhow::Result<u64> {
        self.store.get_last_pulled_seq(key)
    }
}
