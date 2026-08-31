//! Встроенный MCP-сервер (подкоманда `mcp`): MCP поверх stdio как
//! newline-delimited JSON-RPC 2.0. Зовёт внутренние функции CLI НАПРЯМУЮ — без
//! subprocess и парсинга текста (порт с прежнего paranoia_mcp.py на Rust).
//!
//! Надёжность:
//!  • КОНКУРЕНТНОСТЬ. tools/call исполняется в отдельной tokio-задаче; цикл чтения
//!    stdin продолжает отвечать на ping/tools-list, поэтому долгий `wait` (до ~25
//!    мин) не вешает сервер и клиент не считает его мёртвым.
//!  • DURABLE-ЛОГ. Каждое вытянутое сообщение дописывается (append+fsync, дедуп по
//!    id) в LOG ДО возврата клиенту — даже при обрыве восстановимо через `history`.
//!  • VAULT-SAFETY. `provision_from_ui` временно переключает глобальный vault на
//!    UI-стор; берём write-lock (provision) против read-lock (открытие клиента),
//!    чтобы переключение не пересеклось с открытием CLI-БД чужим ключом.

use anyhow::{Context, Result, anyhow};
use serde_json::{Value, json};
use std::collections::HashSet;
use std::io::Write as _;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::{Mutex as AsyncMutex, RwLock};

use paranoia_lib::{Message, MessageContent};

const SERVER_NAME: &str = "paranoia-cli";
const SERVER_VERSION: &str = "0.5.1";
const DEFAULT_PROTOCOL: &str = "2025-06-18";

pub struct McpConfig {
    pub server_url: String,
    pub reserve_server_urls: Vec<String>,
    pub db_path: String,
    pub username: String,
    pub peer: String,
    pub self_hash: String,
    pub log_path: PathBuf,
    pub ui_app_data_root: Option<String>,
    pub ui_pin: Option<String>,
    /// Режим КАНАЛА (push): объявляем capability `claude/channel` и фоновым
    /// лупом инжектим входящие как `notifications/claude/channel` (как Telegram-
    /// плагин). Включается env `PARANOIA_MCP_CHANNEL=1`. В этом режиме агент НЕ
    /// должен звать wait/receive (иначе двойной дренаж сообщений).
    pub channel: bool,
    /// Стартовый скоуп темы для channel-режима (env `PARANOIA_MCP_CHANNEL_TOPIC`).
    /// Задан — сессия слышит ТОЛЬКО эту ветку («Главная» → безтемовую). Пусто/None →
    /// тема НЕ задана: приём остановлен, агенту шлётся напоминание задать тему (НЕ «все»).
    pub channel_topic: Option<String>,
}

// ─────────────────────────── durable message log ────────────────────────────

struct LogInner {
    seen: HashSet<String>,
    loaded: bool,
}

struct DurableLog {
    path: PathBuf,
    inner: Mutex<LogInner>,
}

impl DurableLog {
    fn new(path: PathBuf) -> Self {
        Self {
            path,
            inner: Mutex::new(LogInner {
                seen: HashSet::new(),
                loaded: false,
            }),
        }
    }

    fn load_seen(&self, inner: &mut LogInner) {
        if inner.loaded {
            return;
        }
        inner.loaded = true;
        if let Ok(text) = std::fs::read_to_string(&self.path) {
            for line in text.lines() {
                let line = line.trim();
                if line.is_empty() {
                    continue;
                }
                if let Ok(v) = serde_json::from_str::<Value>(line) {
                    if let Some(id) = v.get("id").and_then(|x| x.as_str()) {
                        inner.seen.insert(id.to_string());
                    }
                }
            }
        }
    }

    /// Дописать новые (по id) сообщения. Идемпотентно: уже записанные id —
    /// пропускаются, поэтому повторные receive/wait не дублируют.
    fn persist(&self, msgs: &[Value]) {
        if msgs.is_empty() {
            return;
        }
        let mut inner = self.inner.lock().unwrap();
        self.load_seen(&mut inner);
        let new: Vec<&Value> = msgs
            .iter()
            .filter(|m| {
                m.get("id")
                    .and_then(|x| x.as_str())
                    .map(|id| !inner.seen.contains(id))
                    .unwrap_or(false)
            })
            .collect();
        if new.is_empty() {
            return;
        }
        match std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)
        {
            Ok(mut f) => {
                for m in &new {
                    if let Ok(s) = serde_json::to_string(m) {
                        let _ = writeln!(f, "{s}");
                    }
                }
                let _ = f.flush();
                let _ = f.sync_all();
                for m in &new {
                    if let Some(id) = m.get("id").and_then(|x| x.as_str()) {
                        inner.seen.insert(id.to_string());
                    }
                }
            }
            Err(e) => eprintln!("[paranoia-mcp] persist error: {e}"),
        }
    }

    fn read(&self, limit: i64, from: Option<&str>) -> Vec<Value> {
        let mut rows = Vec::new();
        if let Ok(text) = std::fs::read_to_string(&self.path) {
            for line in text.lines() {
                let line = line.trim();
                if line.is_empty() {
                    continue;
                }
                if let Ok(v) = serde_json::from_str::<Value>(line) {
                    rows.push(v);
                }
            }
        }
        if let Some(f) = from {
            rows.retain(|r| r.get("from").and_then(|x| x.as_str()) == Some(f));
        }
        if limit > 0 && rows.len() > limit as usize {
            rows = rows.split_off(rows.len() - limit as usize);
        }
        rows
    }
}

// ─────────────────────────────── context ────────────────────────────────────

#[derive(Clone)]
struct Ctx {
    cfg: Arc<McpConfig>,
    log: Arc<DurableLog>,
    out: Arc<AsyncMutex<tokio::io::Stdout>>,
    /// Сериализует открытие клиента (read) против переключения vault в
    /// provision (write). См. VAULT-SAFETY в шапке модуля.
    vault: Arc<RwLock<()>>,
    /// Активная тема сессии — РАНТАЙМ-настройка (init из env `PARANOIA_MCP_CHANNEL_TOPIC`).
    /// Тулза `set_channel_topic` меняет её на лету: channel-луп читает её каждую
    /// итерацию (фильтр приёма), `send` без явного `topic` дефолтит в неё. None/«» =
    /// тема НЕ задана → приём остановлен + напоминание (см. TopicScope::Unset); «Главная»
    /// → безтемовая ветка. Memory-driven: агент выставляет тему воркспейса на старте.
    channel_topic: Arc<Mutex<Option<String>>>,
}

pub async fn serve(cfg: McpConfig) -> Result<()> {
    let log = Arc::new(DurableLog::new(cfg.log_path.clone()));
    eprintln!(
        "[paranoia-mcp] started v{SERVER_VERSION} (rust); server={} db={} peer={} log={}",
        cfg.server_url,
        cfg.db_path,
        if cfg.peer.is_empty() { "?" } else { &cfg.peer },
        cfg.log_path.display()
    );
    // Тема сессии: env → персист воркспейса → не задана. Персист спасает от
    // ТИХОГО рестарта MCP-процесса харнессом (RAM-тема испарялась, скоуп падал
    // в Unset и сессия молча глохла) и избавляет от повторного set_channel_topic
    // в каждой новой сессии того же воркспейса.
    let mut initial_topic = cfg.channel_topic.clone();
    if cfg.channel && initial_topic.is_none() {
        if let Some(t) = load_saved_topic(&cfg.db_path, &cfg.username) {
            eprintln!("[paranoia-mcp] channel: тема воркспейса восстановлена из персиста: {t}");
            initial_topic = Some(t);
        }
    }
    let ctx = Ctx {
        cfg: Arc::new(cfg),
        log,
        out: Arc::new(AsyncMutex::new(tokio::io::stdout())),
        vault: Arc::new(RwLock::new(())),
        channel_topic: Arc::new(Mutex::new(initial_topic)),
    };

    // tools/call исполняем через spawn_local на ЭТОМ же потоке (LocalSet): тогда
    // futures клиента/диалога НЕ обязаны быть Send (rusqlite-соединение может быть
    // !Send; tokio::spawn потребовал бы Send и не скомпилировался бы). Локальные
    // задачи двигаются, пока LocalSet опрашивается — т.е. пока цикл ждёт stdin,
    // идущий долгий `wait` продолжает работать, а ping/tools-list отвечают inline.
    let local = tokio::task::LocalSet::new();
    local
        .run_until(async move {
            // Режим канала: фоновый push-луп инжектит входящие как ходы агента.
            if ctx.cfg.channel {
                let c = ctx.clone();
                tokio::task::spawn_local(channel_push_loop(c));
            }
            let mut lines = BufReader::new(tokio::io::stdin()).lines();
            while let Some(line) = lines.next_line().await? {
                let line = line.trim();
                if line.is_empty() {
                    continue;
                }
                let parsed: Value = match serde_json::from_str(line) {
                    Ok(v) => v,
                    Err(_) => continue,
                };
                match parsed {
                    Value::Array(batch) => {
                        for r in batch {
                            handle(ctx.clone(), r).await;
                        }
                    }
                    other => handle(ctx.clone(), other).await,
                }
            }
            // EOF stdin: харнесс закрыл соединение. run_until вернётся и процесс
            // умрёт вместе с канал-лупом — осиротевший пулер жить не должен.
            eprintln!("[paranoia-mcp] stdin EOF — завершаемся");
            Ok::<(), anyhow::Error>(())
        })
        .await
}

async fn handle(ctx: Ctx, req: Value) {
    let method = req
        .get("method")
        .and_then(|m| m.as_str())
        .unwrap_or("")
        .to_string();
    let id = req.get("id").cloned();
    let params = req.get("params").cloned().unwrap_or(Value::Null);

    match method.as_str() {
        "initialize" => {
            let proto = params
                .get("protocolVersion")
                .and_then(|p| p.as_str())
                .unwrap_or(DEFAULT_PROTOCOL)
                .to_string();
            let mut capabilities = json!({"tools": {"listChanged": false}});
            if ctx.cfg.channel {
                // Объявляем себя КАНАЛОМ — харнесс начнёт инжектить наши
                // notifications/claude/channel как ходы агента (push, как Telegram).
                capabilities["experimental"] = json!({"claude/channel": {}});
            }
            let mut result = json!({
                "protocolVersion": proto,
                "capabilities": capabilities,
                "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            });
            if ctx.cfg.channel {
                result["instructions"] = json!(CHANNEL_INSTRUCTIONS);
            }
            reply_ok(&ctx, id, result).await;
        }
        "notifications/initialized" => {} // нотификация — без ответа
        "tools/list" => {
            reply_ok(&ctx, id, json!({ "tools": tools_list() })).await;
        }
        "tools/call" => {
            // В ОТДЕЛЬНОЙ локальной задаче: долгий wait не должен блокировать цикл
            // чтения, иначе сервер перестанет отвечать на ping. Ответ уйдёт по id
            // из задачи. spawn_local (не spawn) — future может быть !Send.
            let ctx2 = ctx.clone();
            tokio::task::spawn_local(async move {
                let name = params
                    .get("name")
                    .and_then(|n| n.as_str())
                    .unwrap_or("")
                    .to_string();
                let args = params.get("arguments").cloned().unwrap_or(json!({}));
                let payload = match dispatch_tool(&ctx2, &name, &args).await {
                    Ok(v) => json!({
                        "content": [{"type": "text", "text": serde_json::to_string_pretty(&v).unwrap_or_default()}],
                    }),
                    Err(e) => {
                        eprintln!("[paranoia-mcp] tool {name} error: {e}");
                        json!({
                            "content": [{"type": "text", "text": format!("ERROR: {e}")}],
                            "isError": true,
                        })
                    }
                };
                reply_ok(&ctx2, id, payload).await;
            });
        }
        "ping" => {
            reply_ok(&ctx, id, json!({})).await;
        }
        _ => {
            if id.is_some() {
                reply_err(
                    &ctx,
                    id,
                    json!({"code": -32601, "message": format!("method not found: {method}")}),
                )
                .await;
            }
        }
    }
}

async fn reply_ok(ctx: &Ctx, id: Option<Value>, result: Value) {
    write_reply(ctx, id, Some(result), None).await;
}

async fn reply_err(ctx: &Ctx, id: Option<Value>, error: Value) {
    write_reply(ctx, id, None, Some(error)).await;
}

async fn write_reply(ctx: &Ctx, id: Option<Value>, result: Option<Value>, error: Option<Value>) {
    let Some(id) = id else {
        return; // нотификация — без ответа
    };
    let mut msg = serde_json::Map::new();
    msg.insert("jsonrpc".into(), json!("2.0"));
    msg.insert("id".into(), id);
    if let Some(e) = error {
        msg.insert("error".into(), e);
    } else {
        msg.insert("result".into(), result.unwrap_or(Value::Null));
    }
    let line = format!("{}\n", Value::Object(msg));
    // Под локом: ответы из разных задач не должны перемешать строки в stdout.
    let mut out = ctx.out.lock().await;
    if out.write_all(line.as_bytes()).await.is_err() || out.flush().await.is_err() {
        die_stdout_closed();
    }
}

/// stdout закрыт/сломан (EPIPE) — харнесс нас больше не слушает. Жить дальше
/// нельзя: осиротевший канал-луп продолжал бы тянуть сообщения и ставить 👀,
/// имитируя доставку (наблюдалось: зомби-пулер жил 10 часов после
/// «STDIO connection dropped»). Выходим; flock пулера освободится ядром, и
/// роль подхватит живой монитор.
fn die_stdout_closed() -> ! {
    eprintln!("[paranoia-mcp] stdout закрыт (харнесс отвалился) — завершаемся");
    std::process::exit(0);
}

/// Записать JSON-RPC НОТИФИКАЦИЮ (без id) в stdout — под тем же локом, что и
/// ответы, чтобы строки не перемешались. Для push'а событий канала.
async fn write_notification(ctx: &Ctx, method: &str, params: Value) {
    let line = format!(
        "{}\n",
        json!({"jsonrpc": "2.0", "method": method, "params": params})
    );
    let mut out = ctx.out.lock().await;
    if out.write_all(line.as_bytes()).await.is_err() || out.flush().await.is_err() {
        die_stdout_closed();
    }
}

// ───────────────────────────── channel (push) ───────────────────────────────

const CHANNEL_INSTRUCTIONS: &str = concat!(
    "Сообщения из Paranoia приходят как <channel source=\"paranoia\" chat_id=\"...\" ",
    "message_id=\"...\" user=\"...\" ts=\"...\">. Отвечай инструментом `reply` (он же `send`) — ",
    "твой обычный текст в транскрипт пользователю НЕ попадает. Markdown рендерится почти ",
    "весь, включая `#`-заголовки; НЕ рендерится подчёркивание (`__`, setext `===`/`---`); ",
    "URL не оборачивай в `**`.\n",
    "Прогресс-реакции на сообщение пользователя ставь инструментом `react` по схеме: ",
    "🤔 начал думать → ✍️ пишу ответ → ✔️ ответил. «👀 получил» сервер канала ставит сам при приёме.\n",
    "🧵 ТЕМЫ (ветки диалога). Каждый воркспейс ведёт ОДНУ тему. ПОКА тема сессии не задана, ",
    "ты НЕ получаешь сообщения — НИ ОДНОЙ ветки (защита: сессия не должна слышать чужие темы); ",
    "вместо сообщений придёт напоминание задать тему. В начале сессии ОБЯЗАТЕЛЬНО вызови ",
    "`set_channel_topic` с темой этого воркспейса: она и фильтрует приём (будешь слышать ",
    "только свою ветку), и становится дефолтом для `send`. Тему бери из памяти воркспейса; ",
    "если не сохранена — спроси пользователя, в какую тему писать, ВЫЗОВИ `set_channel_topic` ",
    "и сохрани имя в память воркспейса (в следующий раз не переспрашивай). Для главной ",
    "(безтемовой) ветки вызови `set_channel_topic` с темой «Главная». Входящее несёт своё ",
    "поле `topic` — отвечай в ту же тему (передай `topic` явно в `send`). Несколько воркспейсов = ",
    "несколько параллельных веток в одном аккаунте, не мешая друг другу. Привязка темы ",
    "персистится per-воркспейс и восстанавливается после рестарта MCP — повторный вызов ",
    "в знакомом воркспейсе не обязателен, но безвреден.\n",
    "Доступ/паринг менять из канала НЕЛЬЗЯ — только из терминала пользователем."
);

/// Инжектится агенту вместо сообщений, когда тема сессии не задана: новое сообщение
/// есть, но доставка остановлена — нужно привязать сессию к теме (memory-driven).
const TOPIC_REQUIRED_NUDGE: &str = concat!(
    "⚠️ В Paranoia-канале есть новое сообщение, но тема (ветка) этой сессии НЕ задана, ",
    "поэтому сообщения не доставляются (чтобы сессия не получала чужие ветки). ",
    "Определи тему этого воркспейса: посмотри в памяти воркспейса сохранённую тему и вызови ",
    "`set_channel_topic` с ней. Если в памяти темы нет — спроси пользователя, в какую тему ",
    "писать, СОХРАНИ её в память воркспейса и вызови `set_channel_topic`. Для главной ",
    "(безтемовой) ветки вызови `set_channel_topic` с темой «Главная». После этого бэклог ",
    "твоей темы будет доставлен."
);

/// Держатель advisory-лока пулера. flock(2) снимается ЯДРОМ при закрытии fd —
/// то есть и при exit, и при crash процесса. Поэтому stale-локов и гонок
/// переиспользования PID нет: умер пулер → лок свободен на следующем тике.
struct PullGuard {
    _file: std::fs::File,
}

/// Путь lock-файла пулера: рядом с .db, привязан к (username, peer) — у разных
/// диалогов свой пулер. pid внутри пишем только для human-debug; взаимоисключение
/// держит flock, не содержимое.
fn pull_lock_path(db_path: &str, user: &str, peer: &str) -> PathBuf {
    use sha2::{Digest, Sha256};
    let mut h = Sha256::new();
    h.update(user.as_bytes());
    h.update(b"\n");
    h.update(peer.as_bytes());
    let tag = hex::encode(&h.finalize()[..8]);
    let dir = std::path::Path::new(db_path)
        .parent()
        .unwrap_or_else(|| std::path::Path::new("."));
    dir.join(format!(".paranoia-pull-{tag}.lock"))
}

// ─────────────── персист темы воркспейса и курсора доставки ─────────────────
// Причина: харнесс ТИХО перезапускает MCP-процесс (наблюдалось «STDIO connection
// dropped» + respawn) — RAM-тема испарялась, скоуп падал в Unset и сессия глухла;
// а курсор доставки «max_seq на старте» терял всё, что пришло в окно рестарта.

/// Идентификатор воркспейса = cwd родителя (харнесса): у каждого воркспейса свой
/// процесс claude со своим cwd, а WORKDIR самого MCP у всех общий. /proc — Linux;
/// на прочих платформах персист темы тихо выключен (поведение как раньше).
fn workspace_key() -> Option<String> {
    let ppid = unsafe { libc::getppid() };
    std::fs::read_link(format!("/proc/{ppid}/cwd"))
        .ok()
        .map(|p| p.to_string_lossy().into_owned())
}

fn db_dir(db_path: &str) -> PathBuf {
    std::path::Path::new(db_path)
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| std::path::Path::new("."))
        .to_path_buf()
}

/// Файл привязок per-АККАУНТ: несколько агентов (Клод, codex) делят DATADIR,
/// и общий файл позволил бы одному аккаунту перетереть тему воркспейса другого,
/// работающего в том же каталоге. Изоляция аккаунтов — жёсткое требование.
fn topics_file(db_path: &str, user: &str) -> PathBuf {
    use sha2::{Digest, Sha256};
    let tag = hex::encode(&Sha256::digest(user.as_bytes())[..4]);
    db_dir(db_path).join(format!(".paranoia-workspace-topics-{tag}.json"))
}

/// Атомарная запись мелкого json (tmp+rename). RMW-гонка двух одновременных
/// set_channel_topic из разных воркспейсов теоретически может потерять чужую
/// свежую запись — самолечится следующим set; flock тут не оправдан.
fn write_json_atomic(path: &std::path::Path, value: &Value) {
    let tmp = path.with_extension("tmp");
    if std::fs::write(&tmp, serde_json::to_vec_pretty(value).unwrap_or_default()).is_ok() {
        let _ = std::fs::rename(&tmp, path);
    }
}

/// Восстановить тему этого воркспейса из персиста (после тихого рестарта MCP).
fn load_saved_topic(db_path: &str, user: &str) -> Option<String> {
    let ws = workspace_key()?;
    let bytes = std::fs::read(topics_file(db_path, user)).ok()?;
    let v: Value = serde_json::from_slice(&bytes).ok()?;
    v.get(&ws)?.as_str().map(str::to_string)
}

/// Запомнить (или забыть при None) тему этого воркспейса.
fn save_topic_binding(db_path: &str, user: &str, topic: Option<&str>) {
    let Some(ws) = workspace_key() else { return };
    let path = topics_file(db_path, user);
    let mut map = std::fs::read(&path)
        .ok()
        .and_then(|b| serde_json::from_slice::<serde_json::Map<String, Value>>(&b).ok())
        .unwrap_or_default();
    match topic {
        Some(t) => {
            map.insert(ws, json!(t));
        }
        None => {
            map.remove(&ws);
        }
    }
    write_json_atomic(&path, &Value::Object(map));
}

/// Ключ персиста курсора доставки: Unset — курсора нет, Main — пустая строка,
/// Named — нормализованное имя темы (как в движке, чтобы алиасы регистра сошлись).
fn scope_key(s: &TopicScope) -> Option<String> {
    match s {
        TopicScope::Unset => None,
        TopicScope::Main => Some(String::new()),
        TopicScope::Named(n) => Some(paranoia_lib::normalize_topic_name(n)),
    }
}

/// Файл курсора доставки per (user, peer, ключ скоупа). Одна тема = одна сессия
/// (соглашение «тема на воркспейс»), поэтому у файла один писатель.
fn cursor_file(db_path: &str, user: &str, peer: &str, key: &str) -> PathBuf {
    use sha2::{Digest, Sha256};
    let mut h = Sha256::new();
    h.update(user.as_bytes());
    h.update(b"\n");
    h.update(peer.as_bytes());
    h.update(b"\n");
    h.update(key.as_bytes());
    let tag = hex::encode(&h.finalize()[..8]);
    db_dir(db_path).join(format!(".paranoia-delivered-{tag}.json"))
}

fn load_cursor(db_path: &str, user: &str, peer: &str, key: &str) -> Option<u64> {
    let bytes = std::fs::read(cursor_file(db_path, user, peer, key)).ok()?;
    let v: Value = serde_json::from_slice(&bytes).ok()?;
    v.get("seq")?.as_u64()
}

fn save_cursor(db_path: &str, user: &str, peer: &str, key: &str, seq: u64) {
    write_json_atomic(
        &cursor_file(db_path, user, peer, key),
        &json!({"seq": seq}),
    );
}

/// Неблокирующая попытка стать пулером: flock(LOCK_EX|LOCK_NB). Успех → возвращаем
/// guard (fd жив, лок держится до drop/смерти процесса). Занято → None (мы монитор).
fn try_acquire_pull(path: &std::path::Path) -> Option<PullGuard> {
    use std::io::Write as _;
    use std::os::unix::io::AsRawFd;
    let file = std::fs::OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .open(path)
        .ok()?;
    let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if rc != 0 {
        return None; // EWOULDBLOCK — лок держит другой процесс
    }
    let _ = file.set_len(0);
    let _ = write!(&file, "{}", std::process::id()); // best-effort, для debug
    Some(PullGuard { _file: file })
}

/// Скоуп темы сессии — РАНТАЙМ-состояние из `ctx.channel_topic`. Три состояния:
/// - `Unset` — тема НЕ задана. Приём остановлен (ничего не доставляем — чтобы сессия
///   не слышала чужие ветки); агенту шлём напоминание задать тему. НЕ равно «Главной».
/// - `Main` — главная (безтемовая) ветка: только сообщения без темы (`topic_id = None`).
/// - `Named(name)` — конкретная тема: только её `topic_id`.
enum TopicScope {
    Unset,
    Main,
    Named(String),
}

/// Имя/алиас главной (безтемовой) ветки. Нормализуем так же, как движок имена тем,
/// чтобы «Главная»/«главная»/«main» сошлись. Реальную тему с таким именем никто не
/// заводит — это зарезервированный ярлык topicless-ветки во всём продукте.
fn is_main_alias(name: &str) -> bool {
    matches!(
        paranoia_lib::normalize_topic_name(name).as_str(),
        "главная" | "main"
    )
}

/// Классификация имени темы (trim + пусто→Unset, алиас→Main, иначе Named).
fn classify_topic(name: Option<&str>) -> TopicScope {
    match name.map(str::trim).filter(|s| !s.is_empty()) {
        None => TopicScope::Unset,
        Some(n) if is_main_alias(n) => TopicScope::Main,
        Some(n) => TopicScope::Named(n.to_string()),
    }
}

/// Текущий скоуп сессии из рантайм-состояния `ctx.channel_topic`.
fn current_scope(ctx: &Ctx) -> TopicScope {
    let raw = ctx.channel_topic.lock().ok().and_then(|g| g.clone());
    classify_topic(raw.as_deref())
}

/// Имя темы для ОТПРАВКИ по дефолту сессии: Named→Some(name); Main/Unset→None
/// («Главная», topicless). На отправке различать Main и Unset не нужно.
fn send_default_topic(ctx: &Ctx) -> Option<String> {
    match current_scope(ctx) {
        TopicScope::Named(n) => Some(n),
        _ => None,
    }
}

/// Человекочитаемое имя скоупа для логов.
fn scope_display(s: &TopicScope) -> &str {
    match s {
        TopicScope::Unset => "<не задана>",
        TopicScope::Main => "Главная",
        TopicScope::Named(n) => n.as_str(),
    }
}

/// Фоновый луп канала с выбором ЕДИНОГО пулера через flock.
///
/// Несколько MCP-сессий на одном аккаунте (каждая со своим `PARANOIA_MCP_CHANNEL_TOPIC`)
/// открывают один .db. Ровно ОДИН процесс держит flock и реально тянет с сервера
/// (`receive` → пишет расшифрованные строки в общий стор, ставит 👀). ВСЕ процессы
/// (пулер и мониторы) инкрементально читают стор по своему in-memory курсору и
/// инжектят агенту только сообщения СВОЕЙ темы. Тема — внутри E2E-payload, поэтому
/// фильтровать можно лишь после расшифровки (её делает пулер); сервер слеп, ставит
/// только один полл-отпечаток вместо N. Курсор вытягивания (server→стор) персистится
/// в `last_pulled_seq`, так что смерть пулера → промоушн монитора без потери.
async fn channel_push_loop(ctx: Ctx) {
    let peer = ctx.cfg.peer.clone();
    let user = ctx.cfg.username.clone();
    if peer.is_empty() || user.is_empty() {
        eprintln!("[paranoia-mcp] channel: peer/username не заданы — push отключён");
        return;
    }
    // Скоуп темы — РАНТАЙМ: читаем `ctx.channel_topic` на каждом тике (тулза
    // `set_channel_topic` меняет на лету). unset/пусто → приём ОСТАНОВЛЕН + nudge;
    // «Главная» → только безтемовые; имя → только эта ветка (см. TopicScope).
    let lock_path = pull_lock_path(&ctx.cfg.db_path, &user, &peer);
    eprintln!(
        "[paranoia-mcp] channel loop started (peer={peer}, topic={}, lock={})",
        scope_display(&current_scope(&ctx)),
        lock_path.display()
    );

    let mut puller: Option<PullGuard> = None;
    // Курсор ДОСТАВКИ активного скоупа. Персистится per (user, peer, тема):
    // рестарт MCP продолжает с последнего доставленного, а не с max_seq — окно
    // рестарта больше не теряет сообщения. active_key — чей курсор сейчас в руках.
    let mut cursor: Option<u64> = None;
    let mut active_key: Option<String> = None;
    // Отметка «max_seq на старте сессии» — floor для тем БЕЗ сохранённого курсора
    // (первая привязка темы: доставляем бэклог с начала сессии, не всю историю)
    // и для nudge-детекта в Unset.
    let mut session_floor: Option<u64> = None;
    let mut last_dv: i64 = i64::MIN; // последняя замеченная data_version (монитор)
    let mut last_nudge_seq: u64 = 0; // seq, на котором уже подтолкнули задать тему

    loop {
        // Клиент/диалог строим под read-lock (защита от смены vault в provision),
        // затем lock отпускаем — открытое соединение к БД иммунно к смене vault.
        // Раздельные let (как в tool_wait): Dialogue заимствует client, поэтому
        // оба должны жить в одном скоупе (client переживает dialogue).
        let client;
        let dialogue;
        {
            let _g = ctx.vault.read().await;
            client = match crate::build_client(
                &ctx.cfg.server_url,
                &ctx.cfg.reserve_server_urls,
                &user,
                &ctx.cfg.db_path,
            ) {
                Ok(c) => c,
                Err(e) => {
                    eprintln!("[paranoia-mcp] channel build_client error: {e}");
                    tokio::time::sleep(Duration::from_secs(5)).await;
                    continue;
                }
            };
            dialogue = match crate::build_dialogue(&client, &ctx.cfg.server_url, &user, &peer) {
                Ok(d) => d,
                Err(e) => {
                    eprintln!("[paranoia-mcp] channel build_dialogue error: {e}");
                    tokio::time::sleep(Duration::from_secs(5)).await;
                    continue;
                }
            };
        }
        if session_floor.is_none() {
            session_floor = Some(dialogue.max_server_seq().unwrap_or(0));
        }

        loop {
            // (Пере)захват роли пулера, если лок не держим. На старте побеждает
            // ровно один процесс; при смерти пулера лок освобождается ядром и
            // следующий монитор подхватывает на ближайшем тике.
            if puller.is_none() {
                puller = try_acquire_pull(&lock_path);
                if puller.is_some() {
                    eprintln!("[paranoia-mcp] channel: стал ПУЛЕРОМ (тяну с сервера)");
                }
            }

            // Скоуп читаем ДО гейта монитора: смена темы обязана форсировать
            // чтение стора немедленно (раньше data_version-гейт глотал бэклог
            // до следующей записи в БД). Смена скоупа = переключение курсора:
            // сохранённый для этой темы, иначе floor сессии.
            let scope = current_scope(&ctx);
            let key = scope_key(&scope);
            let scope_changed = key != active_key;
            if scope_changed {
                active_key = key;
                cursor = active_key.as_ref().map(|k| {
                    load_cursor(&ctx.cfg.db_path, &user, &peer, k)
                        .unwrap_or_else(|| session_floor.unwrap_or(0))
                });
                if let Some(c) = cursor {
                    eprintln!(
                        "[paranoia-mcp] channel: скоуп → {} (курсор доставки {c})",
                        scope_display(&scope)
                    );
                }
            }

            if puller.is_some() {
                // ПУЛЕР: серверный лонг-полл + вытягивание в общий стор.
                let _ = dialogue.notify_count_wait(25000).await;
                match dialogue.receive().await {
                    Ok((msgs, _errs)) => {
                        let batch: Vec<Value> = msgs
                            .iter()
                            .map(|m| message_to_json(m, &ctx.cfg.self_hash))
                            .collect();
                        ctx.log.persist(&batch); // durable-страховка (для history)
                        for m in &msgs {
                            // 👀 «получил» ставит ТОЛЬКО пулер (он реально принял с
                            // сервера); свои эхо/реакции пропускаем.
                            if !ctx.cfg.self_hash.is_empty() && m.sender == ctx.cfg.self_hash {
                                continue;
                            }
                            let _ = dialogue.send_reaction(&m.id, "👀").await;
                        }
                    }
                    Err(e) => {
                        eprintln!("[paranoia-mcp] channel receive error: {e}");
                        break; // пересоберём клиента (лок пулера сохраняем)
                    }
                }
            } else if !scope_changed {
                // МОНИТОР: дёшево ждём записей пулера через data_version (меняется
                // при модификации БД ДРУГИМ соединением). Нет изменений — не делаем
                // даже SELECT. При смене скоупа гейт пропускается: бэклог новой
                // темы читается сразу, а не после следующей записи в БД.
                match dialogue.data_version() {
                    Ok(v) if v != last_dv => last_dv = v,
                    Ok(_) => {
                        tokio::time::sleep(Duration::from_secs(1)).await;
                        continue;
                    }
                    Err(_) => tokio::time::sleep(Duration::from_secs(1)).await,
                }
            }

            // ОБЕ роли: доставка новых сообщений СВОЕЙ темы из стора по курсору.
            // Курсор двигаем по ВСЕМ прочитанным (включая пропущенные чужие темы),
            // чтобы не перечитывать их вечно; у каждой темы свой персист-курсор.
            // Named → id заранее (один раз на тик), чтобы не дёргать в цикле.
            let named_id: Option<String> = match &scope {
                TopicScope::Named(n) => dialogue.topic_id_for_name(Some(n)),
                _ => None,
            };
            // Unset: курсора нет — nudge-детект идёт от floor'а сессии.
            let from = cursor.or(session_floor).unwrap_or(0);
            match dialogue.messages_after_seq(from, 256) {
                // Тема НЕ задана: НИЧЕГО не доставляем (запрет утечки чужих веток) и
                // курсор НЕ двигаем — как только агент привяжет тему, её бэклог доедет.
                // Есть свежее сообщение собеседника → ОДИН раз подталкиваем задать тему.
                Ok(new_msgs) if matches!(scope, TopicScope::Unset) => {
                    let pending_max = new_msgs
                        .iter()
                        .filter(|m| ctx.cfg.self_hash.is_empty() || m.sender != ctx.cfg.self_hash)
                        .filter_map(|m| m.server_seq)
                        .max();
                    if let Some(seq) = pending_max {
                        if seq > last_nudge_seq {
                            last_nudge_seq = seq;
                            let params = json!({
                                "content": TOPIC_REQUIRED_NUDGE,
                                "meta": { "chat_id": peer, "kind": "topic_required" }
                            });
                            write_notification(&ctx, "notifications/claude/channel", params).await;
                        }
                    }
                }
                Ok(new_msgs) => {
                    let mut newcur = from;
                    for m in &new_msgs {
                        if let Some(seq) = m.server_seq {
                            newcur = newcur.max(seq);
                        }
                        // свои эхо/реакции не инжектим
                        if !ctx.cfg.self_hash.is_empty() && m.sender == ctx.cfg.self_hash {
                            continue;
                        }
                        // фильтр темы: Main → только безтемовые; Named → совпадающий id.
                        let in_scope = match &scope {
                            TopicScope::Main => m.topic_id.is_none(),
                            TopicScope::Named(_) => m.topic_id.as_deref() == named_id.as_deref(),
                            TopicScope::Unset => false, // обработано веткой выше
                        };
                        if !in_scope {
                            continue;
                        }
                        let params = json!({
                            "content": content_text(&m.content),
                            "meta": {
                                "chat_id": peer,
                                "message_id": m.id,
                                "user": m.sender,
                                "kind": classify(&m.content),
                                "ts": m.timestamp.to_string(),
                                "topic": m.topic_name,
                            }
                        });
                        write_notification(&ctx, "notifications/claude/channel", params).await;
                    }
                    if newcur != from {
                        cursor = Some(newcur);
                        // Персист после каждого продвижения: рестарт продолжит
                        // ровно отсюда, окно рестарта не теряет сообщений.
                        if let Some(k) = &active_key {
                            save_cursor(&ctx.cfg.db_path, &user, &peer, k, newcur);
                        }
                    }
                }
                Err(e) => eprintln!("[paranoia-mcp] channel store read error: {e}"),
            }

            // Пейсинг: пулер уже «поспал» в notify_count_wait, монитор — короткий тик.
            tokio::time::sleep(Duration::from_millis(if puller.is_some() {
                300
            } else {
                700
            }))
            .await;
        }
        tokio::time::sleep(Duration::from_secs(3)).await; // перед пересборкой
    }
}

// ─────────────────────────── tool dispatch ──────────────────────────────────

async fn dispatch_tool(ctx: &Ctx, name: &str, args: &Value) -> Result<Value> {
    match name {
        "send" => tool_send(ctx, args).await,
        "react" => tool_react(ctx, args).await,
        "receive" => tool_receive(ctx, args).await,
        "wait" => tool_wait(ctx, args).await,
        "send_file" => tool_send_file(ctx, args).await,
        "download" => tool_download(ctx, args).await,
        "history" => Ok(tool_history(ctx, args)),
        "topics" => tool_topics(ctx, args).await,
        "set_channel_topic" | "set_topic" => tool_set_channel_topic(ctx, args).await,
        "whoami" | "list_peers" => tool_whoami(),
        "provision_from_ui" => tool_provision(ctx, args).await,
        _ => Err(anyhow!("unknown tool: {name}")),
    }
}

fn arg_str<'a>(args: &'a Value, key: &str) -> Option<&'a str> {
    args.get(key)
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|s| !s.is_empty())
}

fn peer_user(ctx: &Ctx, args: &Value) -> (String, String) {
    let peer = arg_str(args, "peer")
        .map(str::to_string)
        .unwrap_or_else(|| ctx.cfg.peer.clone());
    let user = arg_str(args, "username")
        .map(str::to_string)
        .unwrap_or_else(|| ctx.cfg.username.clone());
    (peer, user)
}

fn classify(content: &MessageContent) -> &'static str {
    match content {
        MessageContent::Text(_) | MessageContent::TextReply { .. } => "text",
        MessageContent::Image(_) => "image",
        MessageContent::Voice(_) => "voice",
        MessageContent::Video(_) => "video",
        MessageContent::File(_)
        | MessageContent::FileHeader { .. }
        | MessageContent::FileChunk { .. } => "file",
        MessageContent::PhotoGroup { .. } => "photo_group",
        _ => "other",
    }
}

fn content_text(content: &MessageContent) -> String {
    match content {
        MessageContent::Text(t) => t.clone(),
        MessageContent::TextReply { text, .. } => text.clone(),
        other => format!("{other:?}"),
    }
}

fn message_to_json(m: &Message, self_hash: &str) -> Value {
    let from = if !self_hash.is_empty() && m.sender == self_hash {
        "me"
    } else {
        "peer"
    };
    json!({
        "id": m.id.clone(),
        "ts": m.timestamp.to_string(),
        "sender": m.sender.clone(),
        "from": from,
        "kind": classify(&m.content),
        "text": content_text(&m.content),
        // Тема (ветка диалога): id (детерминированная производная) + имя. null —
        // «Главная». Позволяет агенту вести несколько сессий в одном диалоге.
        "topic_id": m.topic_id.clone(),
        "topic": m.topic_name.clone(),
    })
}

fn is_from(m: &Value, who: &str) -> bool {
    m.get("from").and_then(|x| x.as_str()) == Some(who)
}

async fn tool_send(ctx: &Ctx, args: &Value) -> Result<Value> {
    let (peer, user) = peer_user(ctx, args);
    let text = arg_str(args, "text").context("text обязателен")?;
    // Тема: явный `topic` перебивает (""/«Главная» → безтемовая «Главная»); отсутствует →
    // дефолт сессии из `set_channel_topic`/env (тема воркспейса; Main/Unset → «Главная»).
    let topic = match args.get("topic").and_then(|v| v.as_str()) {
        Some(t) => match classify_topic(Some(t)) {
            TopicScope::Named(n) => Some(n),
            _ => None, // ""/«Главная» → безтемовая ветка
        },
        None => send_default_topic(ctx),
    };
    let _g = ctx.vault.read().await;
    let client = crate::build_client(
        &ctx.cfg.server_url,
        &ctx.cfg.reserve_server_urls,
        &user,
        &ctx.cfg.db_path,
    )?;
    let dialogue =
        crate::build_dialogue(&client, &ctx.cfg.server_url, &user, &peer)?.with_topic(topic);
    let msg = dialogue.send_text(text).await?;
    Ok(json!({
        "ok": true, "peer": peer, "id": msg.id, "seq": msg.server_seq,
        "topic": msg.topic_name,
    }))
}

async fn tool_topics(ctx: &Ctx, args: &Value) -> Result<Value> {
    let (peer, user) = peer_user(ctx, args);
    let _g = ctx.vault.read().await;
    let client = crate::build_client(
        &ctx.cfg.server_url,
        &ctx.cfg.reserve_server_urls,
        &user,
        &ctx.cfg.db_path,
    )?;
    let dialogue = crate::build_dialogue(&client, &ctx.cfg.server_url, &user, &peer)?;
    // Подтянуть новое, чтобы темы, заведённые собеседником, были видны.
    let _ = dialogue.receive().await;
    let topics: Vec<Value> = dialogue
        .list_topics()?
        .into_iter()
        .map(|(id, name, count)| json!({"topic_id": id, "topic": name, "count": count}))
        .collect();
    Ok(json!({"peer": peer, "count": topics.len(), "topics": topics}))
}

/// Задать активную тему сессии. Меняет на лету: фильтр приёма канала (сессия слышит
/// ТОЛЬКО эту ветку) И дефолт темы для `send` без явного `topic`.
/// Пусто/без аргумента → СБРОС в «не задано»: приём ОСТАНОВЛЕН (сообщения не доставляются,
/// агенту приходит напоминание задать тему) — это НЕ «Главная». Тема «Главная» подписывает
/// именно на безтемовую главную ветку. Привязка персистится per-воркспейс (ключ — cwd
/// харнесса) и восстанавливается при рестарте MCP-процесса.
async fn tool_set_channel_topic(ctx: &Ctx, args: &Value) -> Result<Value> {
    let topic = arg_str(args, "topic").map(str::to_string); // arg_str: trim + пусто→None
    if let Ok(mut g) = ctx.channel_topic.lock() {
        *g = topic.clone();
    }
    save_topic_binding(&ctx.cfg.db_path, &ctx.cfg.username, topic.as_deref());
    let scope = match classify_topic(topic.as_deref()) {
        TopicScope::Unset => "unset",
        TopicScope::Main => "main",
        TopicScope::Named(_) => "single",
    };
    eprintln!(
        "[paranoia-mcp] set_channel_topic → {} ({scope})",
        scope_display(&current_scope(ctx))
    );
    Ok(json!({
        "ok": true,
        "topic": topic,
        "scope": scope,
    }))
}

async fn tool_react(ctx: &Ctx, args: &Value) -> Result<Value> {
    let (peer, user) = peer_user(ctx, args);
    let message_id = arg_str(args, "message_id").context("message_id обязателен")?;
    let emoji = arg_str(args, "emoji").context("emoji обязателен")?;
    let _g = ctx.vault.read().await;
    let client = crate::build_client(
        &ctx.cfg.server_url,
        &ctx.cfg.reserve_server_urls,
        &user,
        &ctx.cfg.db_path,
    )?;
    let dialogue = crate::build_dialogue(&client, &ctx.cfg.server_url, &user, &peer)?;
    let msg = dialogue.send_reaction(message_id, emoji).await?;
    Ok(json!({"ok": true, "peer": peer, "id": msg.id, "seq": msg.server_seq}))
}

async fn tool_receive(ctx: &Ctx, args: &Value) -> Result<Value> {
    let (peer, user) = peer_user(ctx, args);
    let include_own = args
        .get("include_own")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    let _g = ctx.vault.read().await;
    let client = crate::build_client(
        &ctx.cfg.server_url,
        &ctx.cfg.reserve_server_urls,
        &user,
        &ctx.cfg.db_path,
    )?;
    let dialogue = crate::build_dialogue(&client, &ctx.cfg.server_url, &user, &peer)?;
    let (msgs, _errs) = dialogue.receive().await?;
    let batch: Vec<Value> = msgs
        .iter()
        .map(|m| message_to_json(m, &ctx.cfg.self_hash))
        .collect();
    ctx.log.persist(&batch); // durable-страховка ДО фильтрации/возврата
    let keep: Vec<Value> = if include_own {
        batch
    } else {
        batch.into_iter().filter(|m| !is_from(m, "me")).collect()
    };
    Ok(json!({"peer": peer, "count": keep.len(), "messages": keep}))
}

async fn tool_wait(ctx: &Ctx, args: &Value) -> Result<Value> {
    let (peer, user) = peer_user(ctx, args);
    let timeout = args
        .get("timeout_seconds")
        .and_then(|v| v.as_u64())
        .unwrap_or(1500);
    let poll_interval = args
        .get("poll_interval")
        .and_then(|v| v.as_u64())
        .unwrap_or(20)
        .max(5);
    let long_poll_ms = args
        .get("long_poll_ms")
        .and_then(|v| v.as_u64())
        .unwrap_or(25000) as u32;
    let include_own = args
        .get("include_own")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);

    // Клиент открываем под read-lock (защита от переключения vault в provision),
    // затем lock отпускаем — открытое соединение к БД иммунно к смене vault.
    let client;
    let dialogue;
    {
        let _g = ctx.vault.read().await;
        client = crate::build_client(
            &ctx.cfg.server_url,
            &ctx.cfg.reserve_server_urls,
            &user,
            &ctx.cfg.db_path,
        )?;
        dialogue = crate::build_dialogue(&client, &ctx.cfg.server_url, &user, &peer)?;
    }

    let deadline = Instant::now() + Duration::from_secs(timeout);
    let mut collected: Vec<Value> = Vec::new();
    let mut polls: u64 = 0;

    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Ok(json!({
                "peer": peer, "timed_out": true, "polls": polls,
                "count": collected.len(), "messages": collected
            }));
        }
        if long_poll_ms > 0 {
            // Сервер держит /notify до нового сообщения или своего потолка.
            // best-effort: при ошибке (старый сервер/CDN режет) — обычный pull.
            let hold = long_poll_ms.min(remaining.as_millis().min(u32::MAX as u128) as u32);
            let _ = dialogue.notify_count_wait(hold).await;
        }
        let poll_start = Instant::now();
        let (msgs, _errs) = dialogue.receive().await?;
        polls += 1;
        let batch: Vec<Value> = msgs
            .iter()
            .map(|m| message_to_json(m, &ctx.cfg.self_hash))
            .collect();
        ctx.log.persist(&batch); // durable-страховка на КАЖДОМ поллинге
        let keep: Vec<Value> = if include_own {
            batch
        } else {
            batch.into_iter().filter(|m| !is_from(m, "me")).collect()
        };
        collected.extend(keep);
        if collected.iter().any(|m| is_from(m, "peer")) {
            return Ok(json!({
                "peer": peer, "timed_out": false, "polls": polls,
                "count": collected.len(), "messages": collected
            }));
        }
        if Instant::now() >= deadline {
            return Ok(json!({
                "peer": peer, "timed_out": true, "polls": polls,
                "count": collected.len(), "messages": collected
            }));
        }
        // Если запрос вернулся быстро (long-poll не держался) — выдержать паузу,
        // чтобы не молотить сервер. Если держался — сразу перевзводим.
        if poll_start.elapsed() < Duration::from_secs(2) {
            let pause =
                Duration::from_secs(poll_interval).min(deadline.saturating_duration_since(Instant::now()));
            if !pause.is_zero() {
                tokio::time::sleep(pause).await;
            }
        }
    }
}

async fn tool_send_file(ctx: &Ctx, args: &Value) -> Result<Value> {
    let (peer, user) = peer_user(ctx, args);
    let path = arg_str(args, "path").context("path обязателен")?;
    let _g = ctx.vault.read().await;
    let client = crate::build_client(
        &ctx.cfg.server_url,
        &ctx.cfg.reserve_server_urls,
        &user,
        &ctx.cfg.db_path,
    )?;
    let dialogue = crate::build_dialogue(&client, &ctx.cfg.server_url, &user, &peer)?;
    let p = std::path::Path::new(path);
    let filename = p
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("attachment.bin")
        .to_string();
    let mime = crate::guess_mime(&filename);
    let msgs = dialogue
        .send_file_auto_with_progress(filename.clone(), mime, p, |_, _| {})
        .await?;
    let id = msgs.first().map(|m| m.id.clone()).unwrap_or_default();
    Ok(json!({"ok": true, "peer": peer, "id": id, "name": filename, "parts": msgs.len()}))
}

async fn tool_download(ctx: &Ctx, args: &Value) -> Result<Value> {
    let (peer, user) = peer_user(ctx, args);
    let mid = arg_str(args, "message_id").context("message_id обязателен")?;
    let out = arg_str(args, "out").context("out обязателен")?;
    let _g = ctx.vault.read().await;
    let client = crate::build_client(
        &ctx.cfg.server_url,
        &ctx.cfg.reserve_server_urls,
        &user,
        &ctx.cfg.db_path,
    )?;
    let dialogue = crate::build_dialogue(&client, &ctx.cfg.server_url, &user, &peer)?;
    dialogue.download_attachment(mid, out).await?;
    Ok(json!({"ok": true, "path": out}))
}

fn tool_history(ctx: &Ctx, args: &Value) -> Value {
    let limit = args.get("limit").and_then(|v| v.as_i64()).unwrap_or(50);
    let from = arg_str(args, "from");
    let rows = ctx.log.read(limit, from);
    json!({
        "count": rows.len(),
        "log": ctx.cfg.log_path.display().to_string(),
        "messages": rows
    })
}

fn tool_whoami() -> Result<Value> {
    let profiles = crate::collect_server_id_profiles()?;
    Ok(json!({ "profiles": profiles }))
}

async fn tool_provision(ctx: &Ctx, args: &Value) -> Result<Value> {
    let root = arg_str(args, "app_data_root")
        .map(str::to_string)
        .or_else(|| ctx.cfg.ui_app_data_root.clone())
        .context("app_data_root обязателен (или env PARANOIA_UI_APP_DATA_ROOT)")?;
    let pin = arg_str(args, "pin")
        .map(str::to_string)
        .or_else(|| ctx.cfg.ui_pin.clone())
        .context("PIN UI-vault не задан (аргумент pin / env PARANOIA_UI_PIN / PARANOIA_CLI_PIN)")?;
    let selector = arg_str(args, "profile");

    // write-lock: provision переключает глобальный vault — не должно пересечься
    // с открытием клиента в других задачах.
    let _g = ctx.vault.write().await;
    let synced =
        crate::sync_from_ui_core(&ctx.cfg.server_url, std::path::Path::new(&root), &pin, selector)?;
    let profiles = crate::collect_server_id_profiles().unwrap_or_default();
    Ok(json!({"ok": true, "synced": synced, "whoami": {"profiles": profiles}}))
}

// ─────────────────────────── tools/list schema ──────────────────────────────

fn tools_list() -> Value {
    json!([
        {
            "name": "wait",
            "description": "Заблокироваться и ждать новое сообщение ОТ собеседника (long-poll). Возвращается, как только peer написал, либо по timeout_seconds. Главный способ ждать ответ: ничего не теряется, парсинг логов не нужен.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "peer": {"type": "string"},
                    "username": {"type": "string"},
                    "timeout_seconds": {"type": "integer", "description": "Макс. ожидание (по умолчанию 1500)"},
                    "poll_interval": {"type": "integer", "description": "Пауза между опросами в режиме короткого поллинга, сек (мин 5, по умолч. 20)"},
                    "long_poll_ms": {"type": "integer", "description": "Удержание long-poll на сервере, мс (по умолч. 25000). 0 = короткий поллинг."},
                    "include_own": {"type": "boolean"}
                }
            }
        },
        {
            "name": "receive",
            "description": "Получить НОВЫЕ сообщения диалога (курсор двигается в БД). По умолчанию — только от собеседника (без своих эхо). В каждом сообщении поле topic — имя темы (ветки), null = «Главная».",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "peer": {"type": "string"},
                    "username": {"type": "string"},
                    "include_own": {"type": "boolean", "description": "Включать собственные отправленные. По умолчанию false."}
                }
            }
        },
        {
            "name": "send",
            "description": "Отправить текстовое сообщение собеседнику (peer) от профиля username. По умолчанию — настроенному в env. Клиент рендерит Markdown. topic — имя темы (ветки диалога): сообщение уйдёт в неё и тема появится у собеседника автоматически. Если topic НЕ задан — используется активная тема сессии (см. set_channel_topic); пустая строка topic=\"\" или topic=\"Главная\" — главная безтемовая ветка.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "text": {"type": "string", "description": "Текст сообщения"},
                    "peer": {"type": "string", "description": "Получатель (по умолч. из env)"},
                    "username": {"type": "string", "description": "Профиль-отправитель (по умолч. из env)"},
                    "topic": {"type": "string", "description": "Имя темы (ветки). Не задан → активная тема сессии. \"\" → «Главная». Создаётся неявно."}
                },
                "required": ["text"]
            }
        },
        {
            "name": "topics",
            "description": "Список тем (веток) диалога: имя темы и число сообщений. Темы — способ вести несколько параллельных линий разговора в одном диалоге.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "peer": {"type": "string"},
                    "username": {"type": "string"}
                }
            }
        },
        {
            "name": "set_channel_topic",
            "description": "Привязать сессию к ОДНОЙ теме (ветке диалога). Меняет на лету ДВА: (1) фильтр приёма — в channel-режиме сессия слышит ТОЛЬКО сообщения этой темы; (2) дефолт темы для send без явного topic. Так несколько сессий в одном аккаунте ведут параллельные ветки, не мешая друг другу. Вызывай в начале сессии с темой воркспейса (сохранённой в памяти; нет — спроси пользователя и сохрани). ⚠️ ПОКА тема не задана, сессия НЕ получает сообщений ни одной ветки (вместо них приходит напоминание задать тему) — это НЕ «Главная». Чтобы слушать главную безтемовую ветку, передай topic «Главная». Без аргумента/пусто — сброс в «не задано» (приём остановлен). Привязка персистится per-воркспейс и переживает рестарты MCP; повторный вызов в новой сессии того же воркспейса не обязателен, но безвреден.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "topic": {"type": "string", "description": "Имя темы. «Главная» — главная безтемовая ветка. Пусто/не задан — сброс в «не задано»: приём остановлен, нужно задать тему."}
                }
            }
        },
        {
            "name": "react",
            "description": "Поставить эмодзи-реакцию на сообщение собеседника по message_id (например 👀/🤔/✍️/✔️ — индикация статуса обработки).",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "message_id": {"type": "string", "description": "id сообщения, на которое ставится реакция"},
                    "emoji": {"type": "string", "description": "эмодзи реакции"},
                    "peer": {"type": "string", "description": "Собеседник (по умолч. из env)"},
                    "username": {"type": "string", "description": "Профиль-отправитель (по умолч. из env)"}
                },
                "required": ["message_id", "emoji"]
            }
        },
        {
            "name": "send_file",
            "description": "Отправить файл/картинку с диска (image/* по расширению — как картинку).",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Путь к файлу на диске"},
                    "peer": {"type": "string"},
                    "username": {"type": "string"}
                },
                "required": ["path"]
            }
        },
        {
            "name": "download",
            "description": "Скачать вложение сообщения по message_id в файл out (сообщение должно быть уже получено через receive/wait тем же профилем).",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "message_id": {"type": "string"},
                    "out": {"type": "string", "description": "Путь назначения"},
                    "peer": {"type": "string"},
                    "username": {"type": "string"}
                },
                "required": ["message_id", "out"]
            }
        },
        {
            "name": "whoami",
            "description": "Показать свой server_id (= --username для сервера) и собеседников из CLI-стора. Без аргументов.",
            "inputSchema": {"type": "object", "properties": {}}
        },
        {
            "name": "provision_from_ui",
            "description": "Подключить профиль НАПРЯМУЮ из стора UI-клиента (vault), без export/import. Читает client.json/dialogs.json под PIN и материализует профиль в CLI-сторе (server_id-ключи, имена). После этого send/receive работают.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "app_data_root": {"type": "string", "description": "Каталог AppData UI-клиента (vault.json + profiles/). По умолч. env PARANOIA_UI_APP_DATA_ROOT."},
                    "pin": {"type": "string", "description": "PIN vault UI-клиента. По умолч. env PARANOIA_UI_PIN, затем PARANOIA_CLI_PIN."},
                    "profile": {"type": "string", "description": "Выбрать один профиль по username/server_id (по умолч. — все)."}
                }
            }
        },
        {
            "name": "history",
            "description": "Прочитать durable-лог полученных сообщений (НЕ двигает курсор БД). Для восстановления, если результат receive/wait не доехал. from=peer|me фильтрует.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "limit": {"type": "integer", "description": "Сколько последних записей (по умолч. 50; 0 = все)"},
                    "from": {"type": "string", "description": "Фильтр: 'peer' или 'me'"}
                }
            }
        }
    ])
}
