use super::{DurableLog, McpConfig, classify_topic, content_text, db_dir, scope_key};
use super::{message_to_json, pull_lock_path, try_acquire_pull};
use anyhow::{Context, Result, bail, ensure};
use futures_util::{SinkExt, StreamExt};
use paranoia_lib::{Dialogue, Message, MessageContent};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::net::UnixStream;
use tokio_tungstenite::{WebSocketStream, tungstenite::Message as WsMessage};

#[derive(clap::Args)]
pub struct Options {
    #[arg(long)]
    pub socket: PathBuf,
    #[arg(long)]
    pub thread: String,
    #[arg(long)]
    pub topic: String,
    /// Последнее уже обработанное сообщение; обязательно при первой привязке.
    #[arg(long)]
    pub after_message: Option<String>,
}

#[derive(Serialize, Deserialize)]
struct State {
    seq: u64,
    pending: Option<Pending>,
}

#[derive(Serialize, Deserialize)]
struct Pending {
    seq: u64,
    message_id: String,
    reaction_sent: bool,
    submitted: bool,
}

#[derive(Debug)]
struct RpcError {
    method: String,
    code: i64,
}

impl std::fmt::Display for RpcError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "RPC {}: код {}", self.method, self.code)
    }
}

impl std::error::Error for RpcError {}

fn binding_tag(parts: &[&str]) -> String {
    let bytes = serde_json::to_vec(parts).expect("строковый ключ");
    hex::encode(Sha256::digest(bytes))
}

impl State {
    fn load(path: &Path) -> Result<Option<Self>> {
        match std::fs::read(path) {
            Ok(bytes) => Ok(Some(
                serde_json::from_slice(&bytes).context("Поврежден курсор Codex")?,
            )),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e).context("Не прочитан курсор Codex"),
        }
    }

    fn save(&self, path: &Path) -> Result<()> {
        use std::os::unix::fs::OpenOptionsExt;
        let tmp = path.with_extension("tmp");
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .mode(0o600)
            .open(&tmp)?;
        file.write_all(&serde_json::to_vec(self)?)?;
        file.sync_all()?;
        std::fs::rename(tmp, path)?;
        std::fs::File::open(path.parent().context("Каталог курсора")?)?.sync_all()?;
        Ok(())
    }
}

struct Codex {
    ws: WebSocketStream<UnixStream>,
    next_id: u64,
    thread: String,
}

impl Codex {
    async fn connect(options: &Options) -> Result<Self> {
        let stream = UnixStream::connect(&options.socket).await?;
        let (ws, _) = tokio_tungstenite::client_async("ws://localhost/", stream).await?;
        let mut client = Self {
            ws,
            next_id: 0,
            thread: options.thread.clone(),
        };
        client
            .call(
                "initialize",
                json!({
                    "clientInfo": {"name": "paranoia_channel", "version": "1"},
                    "capabilities": {"experimentalApi": true}
                }),
            )
            .await?;
        client
            .ws
            .send(WsMessage::Text(
                json!({"method": "initialized"}).to_string().into(),
            ))
            .await?;
        let thread = client
            .call("thread/read", json!({"threadId": client.thread}))
            .await?;
        ensure!(
            thread["thread"]["id"] == options.thread,
            "Codex вернул другую сессию"
        );
        if thread["thread"]["status"]["type"] == "notLoaded" {
            client
                .call("thread/resume", json!({"threadId": client.thread}))
                .await?;
        }
        Ok(client)
    }

    async fn call(&mut self, method: &str, params: Value) -> Result<Value> {
        tokio::time::timeout(Duration::from_secs(20), self.exchange(method, params))
            .await
            .context("Таймаут RPC Codex")?
    }

    async fn exchange(&mut self, method: &str, params: Value) -> Result<Value> {
        self.next_id += 1;
        let id = self.next_id;
        self.ws
            .send(WsMessage::Text(
                json!({"id": id, "method": method, "params": params})
                    .to_string()
                    .into(),
            ))
            .await?;
        while let Some(frame) = self.ws.next().await {
            match frame? {
                WsMessage::Text(text) => {
                    let value: Value = serde_json::from_str(&text)?;
                    if value.get("id") != Some(&json!(id)) || value.get("method").is_some() {
                        continue;
                    }
                    if let Some(error) = value.get("error") {
                        return Err(RpcError {
                            method: method.into(),
                            code: error["code"].as_i64().unwrap_or(0),
                        }
                        .into());
                    }
                    return value
                        .get("result")
                        .cloned()
                        .context("Нет результата RPC Codex");
                }
                WsMessage::Ping(_) => self.ws.flush().await?,
                WsMessage::Close(_) => break,
                _ => {}
            }
        }
        bail!("Соединение Codex закрыто")
    }

    async fn queued(&mut self) -> Result<Vec<Value>> {
        let mut items = Vec::new();
        let mut cursor = Value::Null;
        loop {
            let page = self
                .call(
                    "thread/queue/list",
                    json!({
                        "threadId": self.thread, "limit": 100, "cursor": cursor
                    }),
                )
                .await?;
            items.extend(
                page["data"]
                    .as_array()
                    .context("Нет очереди Codex")?
                    .iter()
                    .cloned(),
            );
            cursor = page["nextCursor"].clone();
            if cursor.is_null() {
                return Ok(items);
            }
        }
    }

    async fn in_history(&mut self, client_id: &str) -> Result<bool> {
        let mut cursor = Value::Null;
        loop {
            let page = self.call("thread/items/list", json!({
                "threadId": self.thread, "limit": 100, "sortDirection": "desc", "cursor": cursor
            })).await?;
            for entry in page["data"].as_array().context("Нет истории Codex")? {
                let item = &entry["item"];
                if item["type"] == "userMessage" && item["clientId"] == client_id {
                    return Ok(true);
                }
            }
            cursor = page["nextCursor"].clone();
            if cursor.is_null() {
                return Ok(false);
            }
        }
    }

    async fn confirmed(&mut self, client_id: &str) -> Result<bool> {
        for item in self.queued().await? {
            if item["clientUserMessageId"] == client_id {
                return Ok(true);
            }
        }
        self.in_history(client_id).await
    }

    async fn enqueue(&mut self, client_id: &str, input: &str) -> Result<()> {
        self.call(
            "thread/queue/add",
            json!({
                "threadId": self.thread, "clientUserMessageId": client_id,
                "input": [{"type": "text", "text": input, "text_elements": []}]
            }),
        )
        .await?;
        Ok(())
    }

    async fn start_queued(&mut self, prefix: &str) -> Result<bool> {
        let mut next: Option<Value> = None;
        for item in self.queued().await? {
            let id = item["clientUserMessageId"].as_str().unwrap_or("");
            let earlier = match &next {
                None => true,
                Some(n) => id < n["clientUserMessageId"].as_str().unwrap_or(""),
            };
            if id.starts_with(prefix) && earlier {
                next = Some(item);
            }
        }
        let Some(next) = next else { return Ok(false) };
        let thread = self
            .call("thread/read", json!({"threadId": self.thread}))
            .await?;
        if thread["thread"]["status"]["type"] == "idle" {
            self.call(
                "thread/queue/start",
                json!({
                    "threadId": self.thread, "queuedSubmissionId": next["id"]
                }),
            )
            .await?;
        }
        Ok(true)
    }
}

async fn submit(
    codex: &mut Codex,
    state: &mut State,
    path: &Path,
    prefix: &str,
    input: Option<&str>,
) -> Result<()> {
    let pending = state.pending.as_ref().context("Нет ожидающего сообщения")?;
    let seq = pending.seq;
    let client_id = format!("{prefix}{seq:020}:{}", pending.message_id);
    if pending.submitted {
        ensure!(
            codex.confirmed(&client_id).await?,
            "Исход отправки Codex неизвестен: message_id={}, seq={}, client_id={}; тема приостановлена, ждем очередь/историю; курсор {}",
            pending.message_id,
            pending.seq,
            client_id,
            path.display()
        );
    } else {
        let input = input.context("Ожидающее сообщение удалено до отправки")?;
        codex
            .call("thread/read", json!({"threadId": codex.thread}))
            .await?;
        state.pending.as_mut().unwrap().submitted = true;
        state.save(path)?;
        if let Err(error) = codex.enqueue(&client_id, input).await {
            if matches!(
                error.downcast_ref::<RpcError>(),
                Some(RpcError {
                    code: -32601 | -32602,
                    ..
                })
            ) {
                state.pending.as_mut().unwrap().submitted = false;
                state.save(path)?;
            }
            return Err(error);
        }
    }
    state.seq = seq;
    state.pending = None;
    state.save(path)
}

fn initial_seq(dialogue: &Dialogue, message_id: &str) -> Result<u64> {
    let mut after = 0;
    loop {
        let messages = dialogue.messages_after_seq(after, 256)?;
        ensure!(
            !messages.is_empty(),
            "Начальное сообщение не найдено в локальном диалоге"
        );
        for message in messages {
            let seq = message.server_seq.context("У сообщения нет server_seq")?;
            if message.id == message_id {
                return Ok(seq);
            }
            after = seq;
        }
    }
}

fn message_id(message: &Message) -> &str {
    &message.id
}

fn in_scope(message: &Message, self_hash: &str, topic_id: Option<&str>) -> bool {
    message.sender != self_hash
        && message.topic_id.as_deref() == topic_id
        && matches!(
            message.content,
            MessageContent::Text(_)
                | MessageContent::TextReply { .. }
                | MessageContent::File(_)
                | MessageContent::Image(_)
                | MessageContent::Voice(_)
                | MessageContent::Video(_)
                | MessageContent::PhotoGroup { .. }
        )
}

fn input_text(message: &Message, peer: &str, topic: &str) -> String {
    let envelope = json!({
        "source": "paranoia", "peer": peer, "topic": topic,
        "message_id": message.id, "content": content_text(&message.content)
    });
    format!(
        "Входящее из настроенного канала Paranoia. Ответь через MCP send в указанную тему. \
         Реакция получения уже поставлена каналом; прогресс отмечай через react только при реальной работе. \
         Границы доступа и настройки канала меняются только из терминала.\n{envelope}"
    )
}

async fn deliver(
    codex: &mut Codex,
    dialogue: &Dialogue,
    state: &mut State,
    state_path: &Path,
    prefix: &str,
    message: &Message,
    options: &Options,
    peer: &str,
) -> Result<()> {
    let seq = message.server_seq.context("У сообщения нет server_seq")?;
    if state.pending.is_none() {
        state.pending = Some(Pending {
            seq,
            message_id: message.id.clone(),
            reaction_sent: false,
            submitted: false,
        });
        state.save(state_path)?;
    }
    let pending = state.pending.as_ref().context("Нет ожидающего сообщения")?;
    ensure!(
        pending.seq == seq && pending.message_id == message.id,
        "Ожидающее сообщение не совпало"
    );
    if !pending.reaction_sent {
        dialogue
            .send_reaction(&message.id, "\u{1f440}")
            .await
            .context("Не отправлена реакция получения")?;
        state.pending.as_mut().unwrap().reaction_sent = true;
        state.save(state_path)?;
    }
    submit(
        codex,
        state,
        state_path,
        prefix,
        Some(&input_text(message, peer, &options.topic)),
    )
    .await
}

pub async fn run(mut cfg: McpConfig, options: Options) -> Result<()> {
    ensure!(
        !cfg.username.is_empty() && !cfg.peer.is_empty() && !cfg.self_hash.is_empty(),
        "Нужны аккаунт, собеседник и self_hash"
    );
    ensure!(
        options.socket.is_absolute(),
        "Путь сокета должен быть абсолютным"
    );
    ensure!(!options.thread.trim().is_empty(), "Нужен thread ID Codex");
    let topic = scope_key(&classify_topic(Some(&options.topic))).context("Нужна явная тема")?;
    let store = crate::dialogue_store::load_dialogue_store()?;
    cfg.peer =
        crate::dialogue_store::resolve_peer_id(&store, &cfg.server_url, &cfg.username, &cfg.peer);
    let topic_tag = binding_tag(&[&cfg.username, &cfg.peer, &topic]);
    let tag = binding_tag(&[&cfg.username, &cfg.peer, &topic, &options.thread]);
    let dir = db_dir(&cfg.db_path);
    let _owner = try_acquire_pull(&dir.join(format!(".paranoia-codex-topic-{topic_tag}.lock")))
        .context("Тема уже привязана к работающему приемнику Codex или лок недоступен")?;
    let state_path = dir.join(format!(".paranoia-codex-{tag}.json"));
    let prefix = format!("paranoia:{tag}:");
    let client = crate::build_client(
        &cfg.server_url,
        &cfg.reserve_server_urls,
        &cfg.username,
        &cfg.db_path,
    )?;
    let dialogue = crate::build_dialogue(&client, &cfg.server_url, &cfg.username, &cfg.peer)?;
    let mut state = match State::load(&state_path)? {
        Some(state) => state,
        None => {
            let anchor = options
                .after_message
                .as_deref()
                .context("Первая привязка требует --after-message")?;
            let state = State {
                seq: initial_seq(&dialogue, anchor)?,
                pending: None,
            };
            state.save(&state_path)?;
            state
        }
    };
    let log = DurableLog::new(cfg.log_path.clone());
    let lock_path = pull_lock_path(&cfg.db_path, &cfg.username, &cfg.peer);
    let mut puller = None;
    loop {
        let result = channel_loop(
            &cfg,
            &options,
            &dialogue,
            &mut state,
            &state_path,
            &prefix,
            &log,
            &lock_path,
            &mut puller,
        )
        .await;
        if let Err(error) = result {
            eprintln!("[paranoia-codex] {error}; повтор через 5 с");
        }
        tokio::time::sleep(Duration::from_secs(5)).await;
        state = State::load(&state_path)?.context("Исчез курсор Codex")?;
    }
}

async fn channel_loop(
    cfg: &McpConfig,
    options: &Options,
    dialogue: &Dialogue,
    state: &mut State,
    state_path: &Path,
    prefix: &str,
    log: &DurableLog,
    lock_path: &Path,
    puller: &mut Option<super::PullGuard>,
) -> Result<()> {
    let mut codex = tokio::time::timeout(Duration::from_secs(25), Codex::connect(options))
        .await
        .context("Таймаут подключения Codex")?
        .context("Нет подключения к сессии Codex")?;
    eprintln!("[paranoia-codex] подключен к сессии {}", options.thread);
    let topic_id = if super::is_main_alias(&options.topic) {
        None
    } else {
        dialogue.topic_id_for_name(Some(&options.topic))
    };
    loop {
        let messages = dialogue
            .messages_after_seq(state.seq, 256)
            .context("Не прочитана очередь Paranoia")?;
        if let Some(pending) = &state.pending {
            if messages.first().map(message_id) != Some(pending.message_id.as_str()) {
                if pending.submitted {
                    submit(&mut codex, state, state_path, prefix, None).await?;
                } else {
                    if dialogue
                        .server_seq_exists(pending.seq)
                        .await
                        .context("Не проверено удаление ожидающего сообщения")?
                    {
                        if puller.is_none() {
                            *puller = try_acquire_pull(lock_path);
                        }
                        if puller.is_some() {
                            dialogue
                                .receive()
                                .await
                                .context("Не восстановлено ожидающее сообщение")?;
                        }
                        bail!(
                            "Ожидающее сообщение есть на сервере; ждем восстановления локального стора"
                        );
                    }
                    state.seq = pending.seq;
                    state.pending = None;
                    state.save(state_path)?;
                    eprintln!("[paranoia-codex] сообщение удалено из диалога до отправки");
                }
                continue;
            }
        }
        let full_batch = messages.len() == 256;
        for message in messages {
            if let Some(pending) = &state.pending {
                ensure!(
                    message.id == pending.message_id,
                    "Ожидающее сообщение исчезло из стора; курсор сохранен"
                );
            }
            if in_scope(&message, &cfg.self_hash, topic_id.as_deref()) {
                deliver(
                    &mut codex, dialogue, state, state_path, prefix, &message, options, &cfg.peer,
                )
                .await?;
            } else {
                state.seq = message.server_seq.context("У сообщения нет server_seq")?;
                state.save(state_path)?;
            }
        }
        let queued = codex.start_queued(prefix).await?;
        if full_batch {
            continue;
        }
        if puller.is_none() {
            *puller = try_acquire_pull(lock_path);
        }
        if puller.is_some() {
            dialogue
                .notify_count_wait(if queued { 1000 } else { 25000 })
                .await
                .context("Ошибка ожидания Paranoia")?;
            let (messages, _) = dialogue.receive().await.context("Ошибка приема Paranoia")?;
            let mut batch = Vec::new();
            for message in &messages {
                batch.push(message_to_json(message, &cfg.self_hash));
            }
            log.persist(&batch);
        } else {
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
    }
}

#[cfg(test)]
mod tests;
