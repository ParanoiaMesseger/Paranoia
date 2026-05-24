use anyhow::Result;
use chrono::Utc;
use rand::Rng;
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
    transport::{
        CoreArrivedGet, CoreArrivedSet, CoreDeterminate, CoreMap, CoreNotify, CorePull, CorePush,
        MapResponse, RawPacket, Transport,
    },
    types::{
        AttachmentKind, CHUNK_SIZE_MAX, CHUNK_SIZE_MIN, ClientConfig, DialogueConfig, DialogueKey,
        FileAttachment, Message, MessageContent, MessageStatus,
    },
};

const FILE_PULL_CHUNKS_PER_REQUEST: u32 = 4;

/// Сколько подряд идущих живых seq тянуть одним bounded /pull в receive().
/// Худший случай — 16 чанков по 192 KB ≈ 3 MB на один HTTPS-ответ.
const RECEIVE_PULL_BATCH: u64 = 16;

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

    pub async fn send_text_reply(
        &self,
        text: impl Into<String>,
        reply_to_id: impl Into<String>,
        reply_sender: impl Into<String>,
        reply_text: impl Into<String>,
    ) -> Result<Message> {
        self.send(MessageContent::TextReply {
            text: text.into(),
            reply_to_id: reply_to_id.into(),
            reply_sender: reply_sender.into(),
            reply_text: reply_text.into(),
        })
        .await
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
        self.send_file_path_with_progress(filename, mime_type, path, |_, _| {})
            .await
    }

    pub async fn send_file_path_with_progress<F>(
        &self,
        filename: impl Into<String>,
        mime_type: impl Into<String>,
        path: impl AsRef<Path>,
        on_progress: F,
    ) -> Result<Vec<Message>>
    where
        F: FnMut(u32, u32),
    {
        let mime_type = mime_type.into();
        let kind = if mime_type.starts_with("image/") {
            AttachmentKind::Image
        } else {
            AttachmentKind::File
        };
        self.send_path_chunked(kind, filename.into(), mime_type, path.as_ref(), on_progress)
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

    pub async fn send_reaction(&self, target_id: &str, emoji: &str) -> Result<Message> {
        self.send(MessageContent::Reaction {
            target_id: target_id.to_string(),
            emoji: emoji.to_string(),
        })
        .await
    }

    /// Получить новые сообщения с сервера.
    /// Возвращает (сообщения, кол-во ошибок расшифровки).
    ///
    /// Алгоритм:
    /// 1. `/map(0, 0)` с пагинацией → полная карта живых seq.
    /// 2. Forward-pull: тянем seq'ы > cursor небольшими bounded-батчами,
    ///    перепрыгивая чанки за `FileHeader` (тела файлов качаются лениво).
    /// 3. Tombstone sweep: локальные сообщения, чьих server_seq нет в карте,
    ///    удаляются — это синхронизация ranged-delete'ов с других устройств
    ///    и от пира.
    pub async fn receive(&self) -> Result<(Vec<Message>, usize)> {
        let username = &self.client_cfg.username;
        let mut messages = Vec::new();
        let mut decrypt_errors: usize = 0;

        // 1. Полная карта живых seq.
        let mut all_runs: Vec<(u64, u64)> = Vec::new();
        let mut last_seq_total = 0u64;
        let mut after = 0u64;
        loop {
            let m = self.fetch_map(after, 0).await?;
            last_seq_total = last_seq_total.max(m.last_seq);
            let Some(last_end) = m.runs.last().map(|(_, e)| *e) else {
                break;
            };
            all_runs.extend(m.runs.into_iter());
            if !m.truncated {
                break;
            }
            after = last_end;
        }
        all_runs.sort_by_key(|r| r.0);

        // 2. Forward-pull новых пакетов.
        let mut cursor = self.store.get_last_pulled_seq(&self.key)?;
        for (begin, end) in &all_runs {
            if *end <= cursor {
                continue;
            }
            let run_start = (*begin).max(cursor.saturating_add(1));
            let mut seq = run_start;
            while seq <= *end {
                let batch_end = seq.saturating_add(RECEIVE_PULL_BATCH - 1).min(*end);
                let after = seq.saturating_sub(1);
                let raw_packets = self.pull_packets(after, batch_end).await?;
                if raw_packets.is_empty() {
                    cursor = batch_end;
                    self.store.set_last_pulled_seq(&self.key, cursor)?;
                    seq = batch_end.saturating_add(1);
                    continue;
                }
                let mut sorted = raw_packets;
                sorted.sort_by_key(|p| p.seq);

                let mut skip_until: Option<u64> = None;
                for pkt in sorted {
                    if matches!(skip_until, Some(until) if pkt.seq <= until) {
                        continue;
                    }
                    skip_until = None;

                    let inner = match self.decrypt_packet(pkt.seq, &pkt.payload) {
                        Ok(v) => v,
                        Err(e) => {
                            warn!("Cannot decrypt seq={}: {e}", pkt.seq);
                            decrypt_errors += 1;
                            cursor = pkt.seq;
                            self.store.set_last_pulled_seq(&self.key, cursor)?;
                            continue;
                        }
                    };

                    let advance_to =
                        if let MessageContent::FileHeader { chunks, .. } = &inner.content {
                            let body_end = pkt
                                .seq
                                .checked_add(*chunks as u64)
                                .ok_or_else(|| anyhow::anyhow!("file range overflow"))?;
                            if *chunks > 0 {
                                skip_until = Some(body_end);
                            }
                            body_end
                        } else {
                            pkt.seq
                        };

                    if inner.sender == *username {
                        if let Some(msg_id) =
                            self.store.get_message_by_seq(&self.key, pkt.seq)?
                        {
                            self.store
                                .update_status(&msg_id, MessageStatus::Delivered)?;
                            cursor = advance_to;
                            self.store.set_last_pulled_seq(&self.key, cursor)?;
                            if let Some(updated) =
                                self.store.get_message_by_id(&self.key, &msg_id)?
                            {
                                messages.push(updated);
                            }
                            continue;
                        }
                    }
                    if let Some(msg) = self.process_incoming(inner, pkt.seq)? {
                        messages.push(msg);
                    }
                    cursor = advance_to;
                    self.store.set_last_pulled_seq(&self.key, cursor)?;
                }

                seq = cursor.saturating_add(1).max(batch_end.saturating_add(1));
            }
        }

        // Подтянуть cursor к last_seq, если хвостовые seq были удалены.
        if last_seq_total > cursor {
            cursor = last_seq_total;
            self.store.set_last_pulled_seq(&self.key, cursor)?;
        }

        // 3. Tombstone sweep.
        let local_seqs = self.store.get_delivered_server_seqs(&self.key)?;
        let tombstones: Vec<u64> = local_seqs
            .into_iter()
            .filter(|s| !seq_in_runs(&all_runs, *s))
            .collect();
        if !tombstones.is_empty() {
            debug!("Tombstone sweep: removing {} local messages", tombstones.len());
            self.store
                .delete_messages_by_seqs(&self.key, &tombstones)?;
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

    pub async fn refresh_arrived_status(&self) -> Result<usize> {
        let username = &self.client_cfg.username;
        if matches!(
            self.store.latest_outgoing_status(&self.key, username)?,
            None | Some((_, MessageStatus::Read))
        ) {
            return Ok(0);
        }

        let partner = self.partner();
        let dialogue_id = crypto::make_dialogue_id(username, partner);

        let msg = format!("arrived:get:{username}:{partner}:{dialogue_id}");
        let sig = crypto::sign(&self.client_cfg.signing_key, msg.as_bytes());
        let core = CoreArrivedGet {
            sender: username.clone(),
            partner: partner.to_string(),
            dialogue_id,
            sig,
        };

        let response = self.transport.arrived_get(&core).await?;
        if let Some(partner_last_seq) = response.partner_last_seq {
            let count =
                self.store
                    .mark_outgoing_read_until(&self.key, username, partner_last_seq)?;
            debug!("Arrived: {count} outgoing messages marked Read up to seq={partner_last_seq}");
            Ok(count)
        } else {
            Ok(0)
        }
    }

    pub async fn set_receipts_enabled(&self, receipts_enabled: bool) -> Result<()> {
        let username = &self.client_cfg.username;
        let partner = self.partner();
        let dialogue_id = crypto::make_dialogue_id(username, partner);

        let msg = format!("arrived:put:{username}:{dialogue_id}:{receipts_enabled}");
        let sig = crypto::sign(&self.client_cfg.signing_key, msg.as_bytes());
        let core = CoreArrivedSet {
            sender: username.clone(),
            dialogue_id,
            receipts_enabled,
            sig,
        };

        self.transport.arrived_set(&core).await
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
            MessageContent::File(f) | MessageContent::Image(f) | MessageContent::Voice(f) => f,
            _ => anyhow::bail!("message_has_no_attachment"),
        };
        // 1) Зашифрованный persistent кеш → расшифровать в указанный target.
        let enc_path = self.attachment_enc_path(message_id)?;
        if enc_path.exists() {
            let sealed = fs::read(&enc_path)?;
            let plaintext =
                crate::local_vault::decrypt_attachment(message_id.as_bytes(), &sealed)?;
            write_bytes_atomic(Path::new(path), &plaintext)?;
            return Ok(());
        }
        // 2) Inline data в самом сообщении (мелкие вложения, не ушедшие в кэш).
        if !file.data.is_empty() {
            write_bytes_atomic(Path::new(path), &file.data)?;
            return Ok(());
        }
        anyhow::bail!("attachment_not_downloaded")
    }

    pub fn delete_local_until(&self, cut_seq: u64) -> Result<()> {
        self.store.delete_messages_until(&self.key, cut_seq)?;
        self.store.set_last_pulled_seq(&self.key, cut_seq)
    }

    /// Удалить локальные сообщения с server_seq в `[from_seq, to_seq]`
    /// (включительно). `from_seq == 0` интерпретируется как «с начала».
    pub fn delete_local_range(&self, from_seq: u64, to_seq: u64) -> Result<()> {
        if to_seq == 0 || (from_seq != 0 && from_seq > to_seq) {
            return Ok(());
        }
        let start = from_seq.max(1);
        let seqs: Vec<u64> = self
            .store
            .get_delivered_server_seqs(&self.key)?
            .into_iter()
            .filter(|s| *s >= start && *s <= to_seq)
            .collect();
        self.store.delete_messages_by_seqs(&self.key, &seqs)
    }

    /// Удалить пакеты на сервере в диапазоне `[from_seq, to_seq]` (включительно).
    /// `from_seq == 0` означает «с начала диалога».
    pub async fn remove_server_range(&self, from_seq: u64, to_seq: u64) -> Result<()> {
        if to_seq == 0 {
            anyhow::bail!("to_seq must be > 0");
        }
        let username = &self.client_cfg.username;
        let partner = self.partner();

        let msg = format!("{username}{partner}{from_seq}{to_seq}");
        let sig = crypto::sign(&self.client_cfg.signing_key, msg.as_bytes());
        let core = CoreDeterminate {
            sender: username.clone(),
            recver: partner.to_string(),
            from_seq,
            to_seq,
            sig,
        };

        self.transport.determinate(&core).await
    }

    /// Удалить всё с начала диалога до `cut_seq` включительно (обёртка над
    /// [`remove_server_range`] для совместимости с существующим вызовом
    /// «очистить серверную историю»).
    pub async fn clear_server_history(&self, cut_seq: u64) -> Result<()> {
        self.remove_server_range(0, cut_seq).await
    }

    pub async fn download_attachment(&self, message_id: &str, path: &str) -> Result<()> {
        self.write_attachment_to_path(message_id, Path::new(path), None)
            .await
    }

    /// Получить расшифрованные байты вложения в память. Plaintext НЕ кладётся
    /// на диск — вызывающая сторона (Qt) сама держит их в RAM (например, в
    /// `QQuickImageProvider`). Persistent на диске — только зашифрованный
    /// `attachment-cache/<msg_id>.enc`.
    pub async fn cache_attachment_bytes(&self, message_id: &str) -> Result<Vec<u8>> {
        let Some(message) = self.store.get_message_by_id(&self.key, message_id)? else {
            anyhow::bail!("attachment_not_found");
        };
        let file = match &message.content {
            MessageContent::File(file)
            | MessageContent::Image(file)
            | MessageContent::Voice(file) => file,
            _ => anyhow::bail!("message_has_no_attachment"),
        };

        let enc_path = self.attachment_enc_path(message_id)?;

        // 1) Persistent encrypted cache → decrypt в память.
        if enc_path.exists() {
            let sealed = fs::read(&enc_path)?;
            let plaintext =
                crate::local_vault::decrypt_attachment(message_id.as_bytes(), &sealed)?;
            return Ok(plaintext);
        }

        // 2) Inline data в самом сообщении (мелкие/локальные).
        if !file.data.is_empty() {
            return Ok(file.data.clone());
        }

        // 3) Скачать с сервера прямо в RAM (никаких plaintext-файлов на диске).
        //    На диск уходит ТОЛЬКО зашифрованный enc_path.
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
        let plaintext = self
            .collect_remote_attachment_chunks(
                header_seq,
                &transfer_id,
                file.chunk_count,
                file.size,
            )
            .await?;

        // Шифруем и пишем persistent enc_path.
        let sealed = crate::local_vault::encrypt_attachment(message_id.as_bytes(), &plaintext)?;
        ensure_parent_dir(&enc_path)?;
        write_bytes_atomic(&enc_path, &sealed)?;

        // Обновляем message: downloaded=true, data clear (если был).
        // Это симметрично с write_attachment_to_path и нужно UI чтобы знать,
        // что вложение скачано (downloadable=true в JSON).
        let mut message_mut = message;
        if let MessageContent::File(ref mut f) | MessageContent::Image(ref mut f)
            | MessageContent::Voice(ref mut f) = message_mut.content
        {
            f.downloaded = true;
            f.data.clear();
            // cache_path НЕ ставим: единственный источник истины — enc_path
            // на диске. Plain байты живут в провайдере (Qt-сторона).
        }
        self.store.save_message(&message_mut)?;

        Ok(plaintext)
    }

    // ── внутренняя логика ─────────────────────────────────────────────────

    async fn fetch_map(&self, after_seq: u64, to_seq: u64) -> Result<MapResponse> {
        let username = &self.client_cfg.username;
        let partner = self.partner();
        let msg = format!("{username}{partner}{after_seq}{to_seq}");
        let sig = crypto::sign(&self.client_cfg.signing_key, msg.as_bytes());
        let core_map = CoreMap {
            sender: username.clone(),
            recver: partner.to_string(),
            after_seq,
            to_seq,
            sig,
        };
        self.transport.map(&core_map).await
    }

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
        // Сначала дешёвый /notify — если новых пакетов нет, пропускаем receive().
        if self.notify_count().await.unwrap_or(0) > 0 {
            self.receive().await?;
        }

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
        if self.notify_count().await.unwrap_or(0) > 0 {
            self.receive().await?;
        }

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

    async fn send_path_chunked<F>(
        &self,
        kind: AttachmentKind,
        filename: String,
        mime_type: String,
        path: &Path,
        mut on_progress: F,
    ) -> Result<Vec<Message>>
    where
        F: FnMut(u32, u32),
    {
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
            // Сообщаем подписчику о прогрессе ПОСЛЕ успешного push'а — callback
            // получает уже отосланные индексы.
            on_progress(i as u32 + 1, total);
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

    /// Вариант скачивания chunked attachment'а целиком в RAM (Vec<u8>).
    /// Используется для encrypted-cache flow: plaintext не пишется на диск,
    /// только зашифрованный результат уходит в `<msg_id>.enc`.
    async fn collect_remote_attachment_chunks(
        &self,
        header_seq: u64,
        transfer_id: &str,
        chunk_count: u32,
        total_size: usize,
    ) -> Result<Vec<u8>> {
        let mut buf: Vec<u8> = Vec::with_capacity(total_size);
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
                        buf.extend_from_slice(&data);
                        after_seq = pkt.seq;
                        expected_index += 1;
                    }
                    _ => anyhow::bail!("attachment_bad_chunk"),
                }
            }
        }
        if written != total_size {
            anyhow::bail!("attachment_bad_size");
        }
        Ok(buf)
    }

    /// Profile dir of currently configured client.
    fn profile_dir(&self) -> PathBuf {
        Path::new(&self.client_cfg.db_path)
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| PathBuf::from("."))
    }

    /// Постоянное место зашифрованного вложения.
    /// Формат имени — только message_id, без оригинального filename:
    /// filename остаётся в БД и не должен раскрываться через listing файлов.
    fn attachment_enc_path(&self, message_id: &str) -> Result<PathBuf> {
        let dir = self.profile_dir().join("attachment-cache");
        fs::create_dir_all(&dir)?;
        Ok(dir.join(format!("{message_id}.enc")))
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
            MessageContent::Delete { .. } => {
                // Legacy: реальное удаление теперь обнаруживается через /map
                // tombstone-sweep в receive(). Игнорируем старые Delete-пакеты,
                // если ещё придут от обновляющихся клиентов.
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
    let mut rng = rand::thread_rng();
    while remaining > 0 {
        let size = if remaining <= CHUNK_SIZE_MIN {
            remaining
        } else {
            rng.gen_range(CHUNK_SIZE_MIN..=CHUNK_SIZE_MAX.min(remaining))
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


/// Бинпоиск seq в сортированном списке непересекающихся runs `[(begin, end)]`.
fn seq_in_runs(runs: &[(u64, u64)], seq: u64) -> bool {
    runs.binary_search_by(|(begin, end)| {
        if seq < *begin {
            std::cmp::Ordering::Greater
        } else if seq > *end {
            std::cmp::Ordering::Less
        } else {
            std::cmp::Ordering::Equal
        }
    })
    .is_ok()
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
