use anyhow::Result;
use chrono::Utc;
use std::{
    fs::{self, File},
    io::{BufReader, BufWriter, Read, Write},
    path::{Path, PathBuf},
    sync::Arc,
};
use tracing::{debug, warn};
use uuid::Uuid;

use crate::{
    crypto,
    packet::PacketInner,
    store::LocalStore,
    transport::{CoreDeterminate, CoreNotify, CorePull, CorePush, RawPacket, Transport},
    types::{
        AttachmentKind, CHUNK_SIZE_MAX, CHUNK_SIZE_MIN, ClientConfig, DialogueConfig, DialogueKey,
        FileAttachment, Message, MessageContent, MessageStatus,
    },
};

const FILE_PULL_CHUNKS_PER_REQUEST: u32 = 4;

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
        let mut config = config;
        if let Err(e) = config.normalize() {
            warn!("Invalid dialogue keyring: {e}");
        }
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
        self.send_chunked(
            AttachmentKind::File,
            filename.into(),
            mime_type.into(),
            data,
        )
        .await
    }

    pub async fn send_file_path(
        &self,
        filename: impl Into<String>,
        mime_type: impl Into<String>,
        path: impl AsRef<Path>,
    ) -> Result<Vec<Message>> {
        let mime_type = mime_type.into();
        let kind = if mime_type.starts_with("image/") {
            AttachmentKind::Image
        } else {
            AttachmentKind::File
        };
        self.send_path_chunked(kind, filename.into(), mime_type, path.as_ref())
            .await
    }

    pub async fn send_image(
        &self,
        filename: impl Into<String>,
        data: Vec<u8>,
    ) -> Result<Vec<Message>> {
        self.send_chunked(
            AttachmentKind::Image,
            filename.into(),
            "image/jpeg".into(),
            data,
        )
        .await
    }

    pub async fn send_voice(&self, data: Vec<u8>) -> Result<Vec<Message>> {
        self.send_chunked(
            AttachmentKind::Voice,
            "voice.ogg".into(),
            "audio/ogg".into(),
            data,
        )
        .await
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
    /// Возвращает (сообщения, кол-во ошибок расшифровки).
    /// Ошибки расшифровки означают несовпадение ключа диалога.
    pub async fn receive(&self) -> Result<(Vec<Message>, usize)> {
        let username = &self.client_cfg.username;
        let mut messages = Vec::new();
        let mut decrypt_errors: usize = 0;
        let mut cursor = self.store.get_last_pulled_seq(&self.key)?;

        loop {
            let Some(to_seq) = cursor.checked_add(1) else {
                break;
            };
            let raw_packets = self.pull_packets(cursor, to_seq).await?;
            if raw_packets.is_empty() {
                self.store.set_last_pulled_seq(&self.key, cursor)?;
                break;
            }

            for pkt in raw_packets {
                let mut next_cursor = pkt.seq;
                let inner = match self.decrypt_packet(pkt.seq, &pkt.payload) {
                    Ok(v) => v,
                    Err(e) => {
                        warn!("Cannot decrypt seq={}: {e}", pkt.seq);
                        decrypt_errors += 1;
                        cursor = next_cursor;
                        self.store.set_last_pulled_seq(&self.key, cursor)?;
                        continue;
                    }
                };

                if let MessageContent::FileHeader { chunks, .. } = &inner.content {
                    next_cursor = pkt
                        .seq
                        .checked_add(*chunks as u64)
                        .ok_or_else(|| anyhow::anyhow!("file range overflow"))?;
                }

                // Собственные пакеты из локальной БД — обновляем статус до Delivered.
                // Если seq неизвестен локально, это история другого устройства того же пользователя.
                if inner.sender == *username {
                    if let Some(msg_id) = self.store.get_message_by_seq(&self.key, pkt.seq)? {
                        self.store
                            .update_status(&msg_id, MessageStatus::Delivered)?;
                        cursor = next_cursor;
                        self.store.set_last_pulled_seq(&self.key, cursor)?;
                        continue;
                    }
                }

                // Обрабатываем входящий пакет
                if let Some(msg) = self.process_incoming(inner, pkt.seq)? {
                    messages.push(msg);
                }
                cursor = next_cursor;
                self.store.set_last_pulled_seq(&self.key, cursor)?;
            }
        }

        Ok((messages, decrypt_errors))
    }

    /// Проверить наличие новых серверных пакетов без загрузки payload.
    pub async fn notify_count(&self) -> Result<u64> {
        let username = &self.client_cfg.username;
        let partner = self.partner();
        let seq = self.store.get_last_pulled_seq(&self.key)?;

        let msg = format!("{username}{partner}{seq}");
        let sig = crypto::sign(&self.client_cfg.signing_key, msg.as_bytes());
        let core_notify = CoreNotify {
            sender: username.clone(),
            partner: partner.to_string(),
            seq,
            sig,
        };

        self.transport.notify(&core_notify).await
    }

    pub async fn history(
        &self,
        limit: usize,
        before: Option<chrono::DateTime<Utc>>,
    ) -> Result<Vec<Message>> {
        self.store.get_messages(&self.key, limit, before)
    }

    pub fn save_attachment(&self, message_id: &str, path: &str) -> Result<()> {
        let Some(message) = self.store.get_message_by_id(&self.key, message_id)? else {
            anyhow::bail!("attachment_not_found");
        };
        let file = match message.content {
            MessageContent::File(file)
            | MessageContent::Image(file)
            | MessageContent::Voice(file) => {
                if file.data.is_empty() && readable_path(&file).is_none() && file.size > 0 {
                    anyhow::bail!("attachment_not_downloaded");
                }
                file
            }
            _ => anyhow::bail!("message_has_no_attachment"),
        };
        if let Some(source) = readable_path(&file) {
            copy_file(&source, Path::new(path))?;
        } else {
            write_bytes_atomic(Path::new(path), &file.data)?;
        }
        Ok(())
    }

    pub fn delete_local_until(&self, cut_seq: u64) -> Result<()> {
        self.store.delete_messages_until(&self.key, cut_seq)
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

    pub async fn download_attachment(&self, message_id: &str, path: &str) -> Result<()> {
        self.write_attachment_to_path(message_id, Path::new(path), None)
            .await
    }

    pub async fn cache_attachment(&self, message_id: &str) -> Result<String> {
        let Some(message) = self.store.get_message_by_id(&self.key, message_id)? else {
            anyhow::bail!("attachment_not_found");
        };
        let file = match &message.content {
            MessageContent::File(file)
            | MessageContent::Image(file)
            | MessageContent::Voice(file) => file,
            _ => anyhow::bail!("message_has_no_attachment"),
        };
        if let Some(path) = readable_path(file) {
            return Ok(path.to_string_lossy().into_owned());
        }

        let cache_path = self.attachment_cache_path(message_id, &file.filename)?;
        let cache_path_string = cache_path.to_string_lossy().into_owned();
        self.write_attachment_to_path(message_id, &cache_path, Some(cache_path_string.clone()))
            .await?;
        Ok(cache_path_string)
    }

    // ── внутренняя логика ─────────────────────────────────────────────────

    async fn pull_packets(&self, after_seq: u64, to_seq: u64) -> Result<Vec<RawPacket>> {
        let username = &self.client_cfg.username;
        let partner = self.partner();
        let msg = format!("{username}{partner}{after_seq}{to_seq}");
        let sig = crypto::sign(&self.client_cfg.signing_key, msg.as_bytes());
        let core_pull = CorePull {
            sender: username.clone(),
            recver: partner.to_string(),
            after_seq,
            to_seq,
            sig,
        };

        self.transport.pull(&core_pull).await
    }

    /// Отправить одиночный пакет любого типа.
    async fn send(&self, content: MessageContent) -> Result<Message> {
        self.receive().await?;

        let username = &self.client_cfg.username;
        let id = Uuid::new_v4().to_string();
        let now = Utc::now();

        // Атомарный seq из локального счётчика
        let seq = self.store.next_send_seq(&self.key)?;
        self.push_packet(seq, &id, now, content.clone()).await?;

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

    async fn push_packet(
        &self,
        seq: u64,
        id: &str,
        timestamp: chrono::DateTime<Utc>,
        content: MessageContent,
    ) -> Result<()> {
        let username = &self.client_cfg.username;
        let partner = self.partner();
        let inner = PacketInner {
            id: id.to_string(),
            timestamp: timestamp.timestamp_millis(),
            sender: username.clone(),
            content,
        };
        let session_key = self.config.key_for_seq(seq)?;
        let ciphertext = crypto::encrypt(session_key, &inner.serialize()?)?;

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

        self.transport.push(&core_push).await
    }

    async fn send_chunked(
        &self,
        kind: AttachmentKind,
        filename: String,
        mime_type: String,
        data: Vec<u8>,
    ) -> Result<Vec<Message>> {
        self.receive().await?;

        let transfer_id = Uuid::new_v4().to_string();
        let total_size = data.len();
        let chunks = random_chunks(&data);
        let total = chunks.len() as u32;
        let packet_count = 1u64
            .checked_add(total as u64)
            .ok_or_else(|| anyhow::anyhow!("file range overflow"))?;
        let header_seq = self.store.reserve_send_seq_range(&self.key, packet_count)?;
        let body_from_seq = if total == 0 { 0 } else { header_seq + 1 };
        let body_to_seq = if total == 0 {
            0
        } else {
            header_seq
                .checked_add(total as u64)
                .ok_or_else(|| anyhow::anyhow!("file range overflow"))?
        };
        let now = Utc::now();

        let header = MessageContent::FileHeader {
            transfer_id: transfer_id.clone(),
            kind,
            filename: filename.clone(),
            mime_type: mime_type.clone(),
            total_size,
            chunks: total,
        };
        self.push_packet(header_seq, &transfer_id, now, header)
            .await?;

        for (i, chunk_data) in chunks.iter().enumerate() {
            let seq = body_from_seq + i as u64;
            let content = MessageContent::FileChunk {
                transfer_id: transfer_id.clone(),
                index: i as u32,
                total,
                filename: filename.clone(),
                mime_type: mime_type.clone(),
                total_size,
                data: chunk_data.to_vec(),
            };
            let chunk_id = format!("{transfer_id}:{i}");
            self.push_packet(seq, &chunk_id, now, content).await?;
            debug!(
                "Sent chunk {}/{} ({} bytes) for transfer {}",
                i + 1,
                total,
                chunk_data.len(),
                transfer_id
            );
        }

        let display_msg = Message {
            id: transfer_id.clone(),
            dialogue: self.key.clone(),
            sender: self.client_cfg.username.clone(),
            content: attachment_content(
                kind,
                FileAttachment {
                    filename,
                    mime_type,
                    size: total_size,
                    data,
                    transfer_id: Some(transfer_id),
                    cache_path: None,
                    chunk_count: total,
                    body_from_seq,
                    body_to_seq,
                    downloaded: true,
                },
            ),
            timestamp: now,
            status: MessageStatus::Sent,
            server_seq: Some(header_seq),
        };
        self.store.save_message(&display_msg)?;

        Ok(vec![display_msg])
    }

    async fn send_path_chunked(
        &self,
        kind: AttachmentKind,
        filename: String,
        mime_type: String,
        path: &Path,
    ) -> Result<Vec<Message>> {
        self.receive().await?;

        let metadata = fs::metadata(path).map_err(|_| anyhow::anyhow!("file_read_error"))?;
        if !metadata.is_file() {
            anyhow::bail!("file_read_error");
        }
        let total_size =
            usize::try_from(metadata.len()).map_err(|_| anyhow::anyhow!("file_too_large"))?;
        let chunk_sizes = random_chunk_sizes(total_size);
        let total =
            u32::try_from(chunk_sizes.len()).map_err(|_| anyhow::anyhow!("file_too_large"))?;
        let packet_count = 1u64
            .checked_add(total as u64)
            .ok_or_else(|| anyhow::anyhow!("file range overflow"))?;
        let header_seq = self.store.reserve_send_seq_range(&self.key, packet_count)?;
        let body_from_seq = if total == 0 { 0 } else { header_seq + 1 };
        let body_to_seq = if total == 0 {
            0
        } else {
            header_seq
                .checked_add(total as u64)
                .ok_or_else(|| anyhow::anyhow!("file range overflow"))?
        };

        let transfer_id = Uuid::new_v4().to_string();
        let now = Utc::now();
        let header = MessageContent::FileHeader {
            transfer_id: transfer_id.clone(),
            kind,
            filename: filename.clone(),
            mime_type: mime_type.clone(),
            total_size,
            chunks: total,
        };
        self.push_packet(header_seq, &transfer_id, now, header)
            .await?;

        let mut reader =
            BufReader::new(File::open(path).map_err(|_| anyhow::anyhow!("file_read_error"))?);
        for (i, chunk_size) in chunk_sizes.iter().copied().enumerate() {
            let mut data = vec![0_u8; chunk_size];
            reader
                .read_exact(&mut data)
                .map_err(|_| anyhow::anyhow!("file_read_error"))?;
            let seq = body_from_seq + i as u64;
            let content = MessageContent::FileChunk {
                transfer_id: transfer_id.clone(),
                index: i as u32,
                total,
                filename: filename.clone(),
                mime_type: mime_type.clone(),
                total_size,
                data,
            };
            let chunk_id = format!("{transfer_id}:{i}");
            self.push_packet(seq, &chunk_id, now, content).await?;
            debug!(
                "Sent chunk {}/{} for transfer {}",
                i + 1,
                total,
                transfer_id
            );
        }

        let display_msg = Message {
            id: transfer_id.clone(),
            dialogue: self.key.clone(),
            sender: self.client_cfg.username.clone(),
            content: attachment_content(
                kind,
                FileAttachment {
                    filename,
                    mime_type,
                    size: total_size,
                    data: Vec::new(),
                    transfer_id: Some(transfer_id),
                    cache_path: Some(path.to_string_lossy().into_owned()),
                    chunk_count: total,
                    body_from_seq,
                    body_to_seq,
                    downloaded: true,
                },
            ),
            timestamp: now,
            status: MessageStatus::Sent,
            server_seq: Some(header_seq),
        };
        self.store.save_message(&display_msg)?;

        Ok(vec![display_msg])
    }

    async fn write_attachment_to_path(
        &self,
        message_id: &str,
        path: &Path,
        cache_path: Option<String>,
    ) -> Result<()> {
        let Some(mut message) = self.store.get_message_by_id(&self.key, message_id)? else {
            anyhow::bail!("attachment_not_found");
        };
        let (kind, mut file) = match message.content.clone() {
            MessageContent::File(file) => (AttachmentKind::File, file),
            MessageContent::Image(file) => (AttachmentKind::Image, file),
            MessageContent::Voice(file) => (AttachmentKind::Voice, file),
            _ => anyhow::bail!("message_has_no_attachment"),
        };

        if let Some(source) = readable_path(&file) {
            copy_file(&source, path)?;
            if let Some(cache_path) = cache_path {
                file.cache_path = Some(cache_path);
                file.downloaded = true;
                file.data.clear();
                message.content = attachment_content(kind, file);
                self.store.save_message(&message)?;
            }
            return Ok(());
        }

        if !file.data.is_empty() || file.size == 0 {
            write_bytes_atomic(path, &file.data)?;
            if let Some(cache_path) = cache_path {
                file.cache_path = Some(cache_path);
                file.data.clear();
            }
            file.downloaded = true;
            message.content = attachment_content(kind, file);
            self.store.save_message(&message)?;
            return Ok(());
        }

        let transfer_id = file
            .transfer_id
            .clone()
            .ok_or_else(|| anyhow::anyhow!("attachment_not_downloaded"))?;
        let header_seq = message
            .server_seq
            .ok_or_else(|| anyhow::anyhow!("attachment_not_downloaded"))?;
        if file.chunk_count == 0 || file.body_to_seq < header_seq {
            anyhow::bail!("attachment_not_downloaded");
        }

        self.write_remote_attachment_chunks(
            path,
            header_seq,
            &transfer_id,
            file.chunk_count,
            file.size,
        )
        .await?;
        if let Some(cache_path) = cache_path {
            file.cache_path = Some(cache_path);
        }
        file.data.clear();
        file.downloaded = true;
        message.content = attachment_content(kind, file);
        self.store.save_message(&message)?;
        Ok(())
    }

    async fn write_remote_attachment_chunks(
        &self,
        path: &Path,
        header_seq: u64,
        transfer_id: &str,
        chunk_count: u32,
        total_size: usize,
    ) -> Result<()> {
        ensure_parent_dir(path)?;
        let temp_path = temporary_output_path(path);
        let result = async {
            let mut writer = BufWriter::new(File::create(&temp_path)?);
            let mut expected_index = 0_u32;
            let mut after_seq = header_seq;
            let mut written = 0_usize;

            while expected_index < chunk_count {
                let batch_end = expected_index
                    .saturating_add(FILE_PULL_CHUNKS_PER_REQUEST)
                    .min(chunk_count);
                let to_seq = header_seq
                    .checked_add(batch_end as u64)
                    .ok_or_else(|| anyhow::anyhow!("file range overflow"))?;
                let mut raw_packets = self.pull_packets(after_seq, to_seq).await?;
                raw_packets.sort_by_key(|pkt| pkt.seq);
                if raw_packets.len() != (batch_end - expected_index) as usize {
                    anyhow::bail!("attachment_incomplete");
                }

                for pkt in raw_packets {
                    let inner = self.decrypt_packet(pkt.seq, &pkt.payload)?;
                    match inner.content {
                        MessageContent::FileChunk {
                            transfer_id: chunk_transfer_id,
                            index,
                            total,
                            total_size: chunk_total_size,
                            data,
                            ..
                        } if chunk_transfer_id == transfer_id
                            && total == chunk_count
                            && index == expected_index
                            && chunk_total_size == total_size =>
                        {
                            written = written
                                .checked_add(data.len())
                                .ok_or_else(|| anyhow::anyhow!("attachment_bad_size"))?;
                            writer.write_all(&data)?;
                            after_seq = pkt.seq;
                            expected_index += 1;
                        }
                        _ => anyhow::bail!("attachment_bad_chunk"),
                    }
                }
            }

            writer.flush()?;
            if written != total_size {
                anyhow::bail!("attachment_bad_size");
            }
            replace_file(&temp_path, path)?;
            Ok(())
        }
        .await;

        if result.is_err() {
            let _ = fs::remove_file(&temp_path);
        }
        result
    }

    fn attachment_cache_path(&self, message_id: &str, filename: &str) -> Result<PathBuf> {
        let profile_dir = Path::new(&self.client_cfg.db_path)
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| PathBuf::from("."));
        let cache_dir = profile_dir.join("attachment-cache");
        fs::create_dir_all(&cache_dir)?;
        Ok(cache_dir.join(format!("{}-{}", message_id, safe_filename(filename))))
    }

    fn decrypt_packet(&self, seq: u64, data: &[u8]) -> Result<PacketInner> {
        let session_key = self.config.key_for_seq(seq)?;
        let plaintext = crypto::decrypt(session_key, data)?;
        PacketInner::deserialize(&plaintext)
    }

    /// Обработать входящий расшифрованный пакет.
    fn process_incoming(&self, inner: PacketInner, seq: u64) -> Result<Option<Message>> {
        if self.store.get_message_by_seq(&self.key, seq)?.is_some() {
            return Ok(None);
        }
        match &inner.content {
            MessageContent::ReadReceipt { up_to_seq } => {
                let count = self.store.mark_read_until(&self.key, *up_to_seq)?;
                debug!("Read receipt: {count} messages marked Read up to seq={up_to_seq}");
                Ok(None)
            }
            MessageContent::Delete { target_id } => {
                self.store.update_status(target_id, MessageStatus::Failed)?;
                debug!("Delete receipt for message id={target_id}");
                Ok(None)
            }
            MessageContent::FileHeader {
                transfer_id,
                kind,
                filename,
                mime_type,
                total_size,
                chunks,
            } => {
                let body_to_seq = seq
                    .checked_add(*chunks as u64)
                    .ok_or_else(|| anyhow::anyhow!("file range overflow"))?;
                let ts = chrono::DateTime::from_timestamp_millis(inner.timestamp)
                    .unwrap_or_else(Utc::now);
                let msg = Message {
                    id: transfer_id.clone(),
                    dialogue: self.key.clone(),
                    sender: inner.sender,
                    content: attachment_content(
                        *kind,
                        FileAttachment {
                            filename: filename.clone(),
                            mime_type: mime_type.clone(),
                            size: *total_size,
                            data: Vec::new(),
                            transfer_id: Some(transfer_id.clone()),
                            cache_path: None,
                            chunk_count: *chunks,
                            body_from_seq: if *chunks == 0 { 0 } else { seq + 1 },
                            body_to_seq: if *chunks == 0 { 0 } else { body_to_seq },
                            downloaded: *chunks == 0,
                        },
                    ),
                    timestamp: ts,
                    status: MessageStatus::Delivered,
                    server_seq: Some(seq),
                };
                self.store.save_message(&msg)?;
                debug!("Received file header for transfer {transfer_id}");
                Ok(Some(msg))
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
                if self
                    .store
                    .get_message_by_id(&self.key, transfer_id)?
                    .is_some()
                {
                    return Ok(None);
                }
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

                if let Some(assembled) = self.store.try_assemble_chunks(transfer_id, &self.key)? {
                    let msg = Message {
                        id: transfer_id.clone(),
                        dialogue: self.key.clone(),
                        sender: assembled.sender,
                        content: MessageContent::File(FileAttachment {
                            filename: assembled.filename,
                            mime_type: assembled.mime_type,
                            size: assembled.data.len(),
                            data: assembled.data,
                            transfer_id: Some(transfer_id.clone()),
                            cache_path: None,
                            chunk_count: *total,
                            body_from_seq: 0,
                            body_to_seq: 0,
                            downloaded: true,
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
                let mut content = inner.content;
                strip_remote_local_attachment_state(&mut content);
                let msg = Message {
                    id: inner.id.clone(),
                    dialogue: self.key.clone(),
                    sender: inner.sender,
                    content,
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
    for size in random_chunk_sizes(data.len()) {
        chunks.push(&data[offset..offset + size]);
        offset += size;
    }
    chunks
}

fn random_chunk_sizes(total_size: usize) -> Vec<usize> {
    let mut sizes = Vec::new();
    let mut remaining = total_size;
    while remaining > 0 {
        let size = if remaining <= CHUNK_SIZE_MIN {
            remaining
        } else {
            rand::random_range(CHUNK_SIZE_MIN..=CHUNK_SIZE_MAX.min(remaining))
        };
        sizes.push(size);
        remaining -= size;
    }
    sizes
}

fn readable_path(file: &FileAttachment) -> Option<PathBuf> {
    file.cache_path.as_ref().and_then(|value| {
        let path = PathBuf::from(value);
        path.is_file().then_some(path)
    })
}

fn strip_remote_local_attachment_state(content: &mut MessageContent) {
    match content {
        MessageContent::File(file) | MessageContent::Image(file) | MessageContent::Voice(file) => {
            file.cache_path = None;
            if file.data.is_empty() && file.size > 0 {
                file.downloaded = false;
            }
        }
        _ => {}
    }
}

fn ensure_parent_dir(path: &Path) -> Result<()> {
    if let Some(parent) = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
    {
        fs::create_dir_all(parent)?;
    }
    Ok(())
}

fn write_bytes_atomic(path: &Path, data: &[u8]) -> Result<()> {
    ensure_parent_dir(path)?;
    let temp_path = temporary_output_path(path);
    let result = (|| {
        fs::write(&temp_path, data)?;
        replace_file(&temp_path, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp_path);
    }
    result
}

fn copy_file(source: &Path, target: &Path) -> Result<()> {
    if source == target {
        return Ok(());
    }
    ensure_parent_dir(target)?;
    let temp_path = temporary_output_path(target);
    let result = (|| {
        fs::copy(source, &temp_path)?;
        replace_file(&temp_path, target)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp_path);
    }
    result
}

fn temporary_output_path(path: &Path) -> PathBuf {
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("attachment.bin");
    path.with_file_name(format!(".{file_name}.{}.part", Uuid::new_v4()))
}

fn replace_file(temp_path: &Path, target: &Path) -> Result<()> {
    if target.exists() {
        fs::remove_file(target)?;
    }
    fs::rename(temp_path, target)?;
    Ok(())
}

fn safe_filename(filename: &str) -> String {
    let mut value = filename.trim().to_string();
    if value.is_empty() {
        value = "attachment.bin".to_string();
    }
    value = value
        .chars()
        .map(|ch| match ch {
            '\\' | '/' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '_',
            ch if ch.is_control() => '_',
            ch => ch,
        })
        .collect::<String>();
    while value.ends_with('.') || value.ends_with(' ') {
        value.pop();
    }
    if value.is_empty() {
        "attachment.bin".to_string()
    } else {
        value
    }
}

fn attachment_content(kind: AttachmentKind, file: FileAttachment) -> MessageContent {
    match kind {
        AttachmentKind::File => MessageContent::File(file),
        AttachmentKind::Image => MessageContent::Image(file),
        AttachmentKind::Voice => MessageContent::Voice(file),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_remote_cache_path_from_attachment_content() {
        let mut content = MessageContent::Image(FileAttachment {
            filename: "photo.jpg".to_string(),
            mime_type: "image/jpeg".to_string(),
            size: 123,
            data: Vec::new(),
            transfer_id: Some("remote-transfer".to_string()),
            cache_path: Some("/etc/passwd".to_string()),
            chunk_count: 1,
            body_from_seq: 2,
            body_to_seq: 2,
            downloaded: true,
        });

        strip_remote_local_attachment_state(&mut content);

        match content {
            MessageContent::Image(file) => {
                assert!(file.cache_path.is_none());
                assert!(!file.downloaded);
            }
            _ => panic!("expected image attachment"),
        }
    }
}
