use anyhow::Result;
use chrono::Utc;
use std::sync::Arc;
use tracing::{debug, warn};
use uuid::Uuid;

use crate::{
    crypto,
    packet::PacketInner,
    store::LocalStore,
    transport::{Transport, CorePush, CorePull, CoreDeterminate, RawPacket},
    types::{
        ClientConfig, DialogueConfig, DialogueKey, FileAttachment, Message, MessageContent,
        MessageStatus, CHUNK_SIZE_MAX, CHUNK_SIZE_MIN,
    },
};

pub struct Dialogue {
    pub key: DialogueKey,
    config: DialogueConfig,
    client_cfg: Arc<ClientConfig>,
    transport: Arc<Transport>,
    store: Arc<LocalStore>,
}

impl Dialogue {
    pub fn new(
        config: DialogueConfig,
        client_cfg: Arc<ClientConfig>,
        transport: Arc<Transport>,
        store: Arc<LocalStore>,
    ) -> Self {
        let key = config.key.clone();
        Self {
            key,
            config,
            client_cfg,
            transport,
            store,
        }
    }

    // ── публичный API ─────────────────────────────────────────────────────

    pub async fn send_text(&self, text: impl Into<String>) -> Result<Message> {
        self.send(MessageContent::Text(text.into())).await
    }

    pub async fn send_file(
        &self,
        filename: impl Into<String>,
        mime_type: impl Into<String>,
        data: Vec<u8>,
    ) -> Result<Vec<Message>> {
        self.send_chunked(filename.into(), mime_type.into(), data).await
    }

    pub async fn send_image(
        &self,
        filename: impl Into<String>,
        data: Vec<u8>,
    ) -> Result<Vec<Message>> {
        self.send_chunked(filename.into(), "image/jpeg".into(), data).await
    }

    pub async fn send_voice(&self, data: Vec<u8>) -> Result<Vec<Message>> {
        self.send_chunked("voice.ogg".into(), "audio/ogg".into(), data).await
    }

    pub async fn send_read_receipt(&self, up_to_seq: u64) -> Result<()> {
        self.send(MessageContent::ReadReceipt { up_to_seq }).await?;
        Ok(())
    }

    pub async fn delete_message(&self, target_id: &str) -> Result<()> {
        self.send(MessageContent::Delete {
            target_id: target_id.to_string(),
        })
        .await?;
        Ok(())
    }

    /// Получить новые сообщения с сервера.
    /// Возвращает только полностью собранные сообщения.
    pub async fn receive(&self) -> Result<Vec<Message>> {
        let username = &self.client_cfg.username;
        let partner = self.partner();
        let after_seq = self.store.get_last_pulled_seq(&self.key)?;

        // Формируем CorePull
        let msg = format!("{username}{partner}{after_seq}");
        let sig = crypto::sign(&self.client_cfg.signing_key, msg.as_bytes());
        let core_pull = CorePull {
            sender: username.clone(),
            recver: partner.to_string(),
            after_seq,
            sig,
        };

        let raw_packets: Vec<RawPacket> = self.transport.pull(&core_pull).await?;

        if raw_packets.is_empty() {
            return Ok(vec![]);
        }

        let mut messages = Vec::new();
        let mut max_seq = after_seq;

        for pkt in raw_packets {
            max_seq = max_seq.max(pkt.seq);

            let inner = match self.decrypt_packet(&pkt.payload) {
                Ok(v) => v,
                Err(e) => {
                    warn!("Cannot decrypt seq={}: {e}", pkt.seq);
                    continue;
                }
            };

            // Собственные пакеты — обновляем статус до Delivered
            if inner.sender == *username {
                if let Some(msg_id) = self.store.get_message_by_seq(&self.key, pkt.seq)? {
                    self.store
                        .update_status(&msg_id, MessageStatus::Delivered)?;
                }
                continue;
            }

            // Обрабатываем входящий пакет
            if let Some(msg) = self.process_incoming(inner, pkt.seq)? {
                messages.push(msg);
            }
        }

        self.store.set_last_pulled_seq(&self.key, max_seq)?;
        Ok(messages)
    }

    pub async fn history(
        &self,
        limit: usize,
        before: Option<chrono::DateTime<Utc>>,
    ) -> Result<Vec<Message>> {
        self.store.get_messages(&self.key, limit, before)
    }

    pub async fn clear_server_history(&self, cut_seq: u64) -> Result<()> {
        let username = &self.client_cfg.username;
        let partner = self.partner();

        let msg = format!("{username}{partner}{cut_seq}");
        let sig = crypto::sign(&self.client_cfg.signing_key, msg.as_bytes());
        let core = CoreDeterminate {
            sender: username.clone(),
            recver: partner.to_string(),
            cut_seq,
            sig,
        };

        self.transport.determinate(&core).await
    }

    // ── внутренняя логика ─────────────────────────────────────────────────

    /// Отправить одиночный пакет любого типа.
    async fn send(&self, content: MessageContent) -> Result<Message> {
        let username = &self.client_cfg.username;
        let partner = self.partner();
        let id = Uuid::new_v4().to_string();
        let now = Utc::now();

        let inner = PacketInner {
            id: id.clone(),
            timestamp: now.timestamp_millis(),
            sender: username.clone(),
            content: content.clone(),
        };

        let ciphertext = crypto::encrypt(&self.config.session_key, &inner.serialize()?)?;

        // Атомарный seq из локального счётчика
        let seq = self.store.next_send_seq(&self.key)?;

        // Подпись: sender + recver + seq + payload(base64)
        let payload_b64 = crypto::encode_b64(&ciphertext);
        let msg = format!("{username}{partner}{seq}{payload_b64}");
        let sig = crypto::sign(&self.client_cfg.signing_key, msg.as_bytes());

        let core_push = CorePush {
            sender: username.clone(),
            recver: partner.to_string(),
            seq,
            payload: ciphertext,
            sig,
        };

        self.transport.push(&core_push).await?;

        let msg = Message {
            id: id.clone(),
            dialogue: self.key.clone(),
            sender: username.clone(),
            content,
            timestamp: now,
            status: MessageStatus::Sent,
            server_seq: Some(seq),
        };
        self.store.save_message(&msg)?;
        debug!("Sent seq={seq} id={id}");
        Ok(msg)
    }

    async fn send_chunked(
        &self,
        filename: String,
        mime_type: String,
        data: Vec<u8>,
    ) -> Result<Vec<Message>> {
        let transfer_id = Uuid::new_v4().to_string();
        let total_size = data.len();
        let chunks = random_chunks(&data);
        let total = chunks.len() as u32;

        let mut sent = Vec::with_capacity(chunks.len());
        for (i, chunk_data) in chunks.into_iter().enumerate() {
            let content = MessageContent::FileChunk {
                transfer_id: transfer_id.clone(),
                index: i as u32,
                total,
                filename: filename.clone(),
                mime_type: mime_type.clone(),
                total_size,
                data: chunk_data.to_vec(),
            };
            let msg = self.send(content).await?;
            sent.push(msg);
            debug!(
                "Sent chunk {}/{} ({} bytes) for transfer {}",
                i + 1,
                total,
                chunk_data.len(),
                transfer_id
            );
        }

        Ok(sent)
    }

    fn decrypt_packet(&self, data: &[u8]) -> Result<PacketInner> {
        let plaintext = crypto::decrypt(&self.config.session_key, data)?;
        PacketInner::deserialize(&plaintext)
    }

    /// Обработать входящий расшифрованный пакет.
    fn process_incoming(&self, inner: PacketInner, seq: u64) -> Result<Option<Message>> {
        match &inner.content {
            MessageContent::ReadReceipt { up_to_seq } => {
                let count = self.store.mark_read_until(&self.key, *up_to_seq)?;
                debug!("Read receipt: {count} messages marked Read up to seq={up_to_seq}");
                Ok(None)
            }
            MessageContent::Delete { target_id } => {
                self.store
                    .update_status(target_id, MessageStatus::Failed)?;
                debug!("Delete receipt for message id={target_id}");
                Ok(None)
            }
            MessageContent::FileChunk {
                transfer_id,
                index,
                total,
                filename,
                mime_type,
                total_size,
                data,
            } => {
                let ts = chrono::DateTime::from_timestamp_millis(inner.timestamp)
                    .unwrap_or_else(Utc::now);

                self.store.save_chunk(
                    transfer_id,
                    &self.key,
                    &inner.sender,
                    *index,
                    *total,
                    filename,
                    mime_type,
                    *total_size,
                    data,
                    ts,
                )?;
                debug!(
                    "Received chunk {}/{} for transfer {}",
                    index + 1,
                    total,
                    transfer_id
                );

                if let Some(assembled) =
                    self.store.try_assemble_chunks(transfer_id, &self.key)?
                {
                    let msg = Message {
                        id: Uuid::new_v4().to_string(),
                        dialogue: self.key.clone(),
                        sender: assembled.sender,
                        content: MessageContent::File(FileAttachment {
                            filename: assembled.filename,
                            mime_type: assembled.mime_type,
                            size: assembled.data.len(),
                            data: assembled.data,
                        }),
                        timestamp: assembled.timestamp,
                        status: MessageStatus::Delivered,
                        server_seq: Some(seq),
                    };
                    self.store.save_message(&msg)?;
                    debug!("Assembled file from transfer {transfer_id}");
                    return Ok(Some(msg));
                }

                Ok(None)
            }
            _ => {
                let msg = Message {
                    id: inner.id.clone(),
                    dialogue: self.key.clone(),
                    sender: inner.sender,
                    content: inner.content,
                    timestamp: chrono::DateTime::from_timestamp_millis(inner.timestamp)
                        .unwrap_or_else(Utc::now),
                    status: MessageStatus::Delivered,
                    server_seq: Some(seq),
                };
                self.store.save_message(&msg)?;
                Ok(Some(msg))
            }
        }
    }

    fn partner(&self) -> &str {
        if self.key.a == self.client_cfg.username {
            &self.key.b
        } else {
            &self.key.a
        }
    }
}

fn random_chunks(data: &[u8]) -> Vec<&[u8]> {
    let mut chunks = Vec::new();
    let mut offset = 0;
    while offset < data.len() {
        let remaining = data.len() - offset;
        let size = if remaining <= CHUNK_SIZE_MIN {
            remaining
        } else {
            rand::random_range(CHUNK_SIZE_MIN..=CHUNK_SIZE_MAX.min(remaining))
        };
        chunks.push(&data[offset..offset + size]);
        offset += size;
    }
    chunks
}
