pub mod admin;
pub mod client_cover;
pub mod client_cover_food;
pub mod crypto;
pub mod dialogue;
pub mod packet;
pub mod qr_exchange;
pub mod store;
pub mod transport;
pub mod types;
pub mod ffi;

use anyhow::Result;
use std::sync::Arc;

pub use admin::AdminKeyPair;
pub use dialogue::Dialogue;
pub use types::{
    ClientConfig, DialogueConfig, DialogueKey, FileAttachment, Message, MessageContent,
    MessageStatus,
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
        let transport = Arc::new(Transport::new(&config.server_url, cover));
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

    pub fn delete_local_dialogue(&self, key: &DialogueKey) -> anyhow::Result<()> {
        self.store.delete_dialogue(key)
    }
}
