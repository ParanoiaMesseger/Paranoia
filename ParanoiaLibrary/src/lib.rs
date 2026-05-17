pub mod admin;
pub mod client_cover;
pub mod client_cover_food;
pub mod crypto;
pub mod dialogue;
mod error_classify;
pub mod export;
pub mod ffi;
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

use client_cover_food::FoodDeliveryClientCover;
use store::LocalStore;
use transport::Transport;

pub struct ParanoiaClient {
    config: Arc<ClientConfig>,
    transport: Arc<Transport>,
    store: Arc<LocalStore>,
}

impl ParanoiaClient {
    pub fn new(config: ClientConfig) -> Result<Self> {
        let cover = Arc::new(FoodDeliveryClientCover::new());
        let transport = Arc::new(Transport::new(
            &config.server_url,
            config.reserve_server_urls.iter().map(String::as_str),
            cover,
        ));
        let store = Arc::new(LocalStore::open(&config.db_path)?);
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
