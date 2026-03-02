pub mod crypto;
pub mod dialogue;
pub mod packet;
pub mod store;
pub mod transport;
pub mod types;

use anyhow::Result;
use std::sync::Arc;

pub use dialogue::Dialogue;
pub use types::{
    ClientConfig, DialogueConfig, DialogueKey, FileAttachment, Message, MessageContent,
    MessageStatus,
};

pub struct ParanoiaClient {
    config: Arc<ClientConfig>,
    transport: Arc<transport::Transport>,
    store: Arc<store::LocalStore>,
}

impl ParanoiaClient {
    pub fn new(config: ClientConfig) -> Result<Self> {
        let transport = Arc::new(transport::Transport::new(&config.server_url));
        let store = Arc::new(store::LocalStore::open(&config.db_path)?);
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
}
