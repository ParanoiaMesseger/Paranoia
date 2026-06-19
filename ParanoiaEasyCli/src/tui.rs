//! Интерактивный консольный мессенджер (TUI) для ParanoiaEasyCli — сабкоманда `tui`.
//!
//! **Стор ЕДИНЫЙ с графическим клиентом**: TUI работает НАПРЯМУЮ на сторе
//! UI-клиента (`~/.local/share/Paranoia/ParanoiaUiClient`): профили/диалоги/ключи —
//! из его vault (`read_ui_profiles`, разблокировка PIN'ом UI-клиента), история и
//! отправка/приём — в ту же per-profile `paranoia.db`. Так консольная и графическая
//! версии не расходятся. ⚠️ Не запускать TUI и десктоп одновременно на одном
//! профиле — оба читают/дренажат одну БД.
//!
//! Архитектура: UI-поток (ratatui+crossterm) + рабочий std::thread с клиентом
//! движка (current_thread runtime + LocalSet/spawn_local; клиент !Send живёт там).
//! Обмен каналами: команды UI→worker (tokio mpsc), события worker→UI (std mpsc).

use anyhow::{Context, Result};
use std::collections::HashMap;
use std::rc::Rc;
use std::time::Duration;

use base64::Engine;
use base64::engine::general_purpose::STANDARD as B64;
use ed25519_dalek::SigningKey;
use paranoia_lib::export::{ExportPayload, ecies_decrypt, validate_export_payload};
use paranoia_lib::{
    ClientConfig, Dialogue, DialogueConfig, DialogueKey, DialogueKeyEntry, Message, MessageContent,
    ParanoiaClient,
};

use ratatui::crossterm::event::{self, Event, KeyCode, KeyEventKind, KeyModifiers};
use ratatui::layout::{Constraint, Direction, Layout};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Clear, List, ListItem, ListState, Paragraph, Wrap};
use ratatui::{DefaultTerminal, Frame};

// ───────────────────────────── модель данных ────────────────────────────────

enum Cmd {
    Open(String),
    Send(String, String),
    React(String, String, String),
    SendFile(String, String),
    Download(String, String, String),
    Quit,
}

enum Evt {
    History(String, Vec<Msg>),
    New(String, Vec<Msg>),
    Status(String),
}

#[derive(Clone)]
struct Msg {
    id: String,
    me: bool,
    who: String,
    ts: String,
    /// Дата сообщения в формате "%d.%m.%Y" — для меток даты в ленте.
    date: String,
    /// Unix-время в мс — для устойчивой сортировки ленты (старые → новые).
    sort_ts: i64,
    body: String,
    att: Option<Att>,
    /// Эмодзи-реакции, прилепленные к ЭТОМУ сообщению (агрегируются из Reaction).
    reactions: Vec<String>,
    /// Для сообщений-реакций: id целевого сообщения (тогда это не строка ленты,
    /// а реакция, которую надо прилепить к таргету). У обычных — None.
    target_id: Option<String>,
}

#[derive(Clone)]
struct Att {
    filename: String,
}

/// Данные диалога из UI-стора для рабочего потока.
#[derive(Clone)]
struct DlgData {
    peer: String,             // peer_server_id (ключ диалога)
    name: String,             // local_name из UI (или server_id)
    keyring: Vec<(u64, String)>, // (start_seq, key_b64)
}

/// Контекст профиля (из UI-стора) для рабочего потока.
struct UiCtx {
    server_url: String,
    reserve: Vec<String>,
    server_id: String,
    private_key: String,
    db_path: String,
    dialogues: Vec<DlgData>,
}

fn shorten(s: &str) -> String {
    if s.len() > 10 { format!("{}…", &s[..10]) } else { s.to_string() }
}

fn human_size(n: usize) -> String {
    const U: [&str; 4] = ["Б", "КБ", "МБ", "ГБ"];
    let mut v = n as f64;
    let mut i = 0;
    while v >= 1024.0 && i < U.len() - 1 {
        v /= 1024.0;
        i += 1;
    }
    if i == 0 { format!("{n} Б") } else { format!("{v:.1} {}", U[i]) }
}

fn to_msg(m: &Message, self_id: &str, names: &HashMap<String, String>) -> Option<Msg> {
    let me = m.sender == self_id;
    let who = if me {
        "Вы".to_string()
    } else {
        names.get(&m.sender).cloned().unwrap_or_else(|| shorten(&m.sender))
    };
    let local = m.timestamp.with_timezone(&chrono::Local);
    let ts = local.format("%H:%M").to_string();
    let date = local.format("%d.%m.%Y").to_string();
    let sort_ts = m.timestamp.timestamp_millis();
    let att_of = |a: &paranoia_lib::FileAttachment| Att { filename: a.filename.clone() };
    // Реакция — не строка ленты, а эмодзи для прилепления к target_id (см. fold).
    if let MessageContent::Reaction { target_id, emoji } = &m.content {
        return Some(Msg {
            id: m.id.clone(),
            me,
            who,
            ts,
            date,
            sort_ts,
            body: emoji.clone(),
            att: None,
            reactions: Vec::new(),
            target_id: Some(target_id.clone()),
        });
    }
    let (body, att) = match &m.content {
        MessageContent::Text(t) => (t.clone(), None),
        MessageContent::TextReply { text, .. } => (format!("↩ {text}"), None),
        MessageContent::Image(a) => (format!("🖼 {} ({})", a.filename, human_size(a.size)), Some(att_of(a))),
        MessageContent::File(a) => (format!("📎 {} ({})", a.filename, human_size(a.size)), Some(att_of(a))),
        MessageContent::Voice(a) => (format!("🎤 {} ({})", a.filename, human_size(a.size)), Some(att_of(a))),
        MessageContent::Video(a) => (format!("🎬 {} ({})", a.filename, human_size(a.size)), Some(att_of(a))),
        MessageContent::PhotoGroup { caption, .. } => (format!("🖼 альбом {caption}"), None),
        _ => return None,
    };
    Some(Msg { id: m.id.clone(), me, who, ts, date, sort_ts, body, att, reactions: Vec::new(), target_id: None })
}

// ───────────────────────────── рабочий поток ────────────────────────────────

fn build_ui_client(ctx: &UiCtx) -> Result<ParanoiaClient> {
    let bytes = crate::validate_b64_32(&ctx.private_key, "UI signing key")?;
    let cfg = ClientConfig {
        server_url: ctx.server_url.clone(),
        reserve_server_urls: ctx.reserve.clone(),
        username: ctx.server_id.clone(),
        signing_key: SigningKey::from_bytes(&bytes),
        db_path: ctx.db_path.clone(),
    };
    ParanoiaClient::new(cfg)
}

fn build_ui_dialogue(
    client: &ParanoiaClient,
    server_id: &str,
    peer: &str,
    keyring: &[(u64, String)],
) -> Result<Dialogue> {
    let mut entries = Vec::with_capacity(keyring.len());
    for (seq, k) in keyring {
        let bytes = B64.decode(k.trim()).context("invalid base64 dialogue key")?;
        let arr: [u8; 32] = bytes
            .try_into()
            .map_err(|b: Vec<u8>| anyhow::anyhow!("dialogue key must be 32 bytes, got {}", b.len()))?;
        entries.push(DialogueKeyEntry { start_seq: *seq, key: arr });
    }
    let dcfg = DialogueConfig::with_keyring(DialogueKey::new(server_id, peer), entries)?;
    Ok(client.open_dialogue(dcfg))
}

async fn worker_loop(
    ctx: UiCtx,
    mut cmd_rx: tokio::sync::mpsc::UnboundedReceiver<Cmd>,
    evt_tx: std::sync::mpsc::Sender<Evt>,
) {
    let client = match build_ui_client(&ctx) {
        Ok(c) => c,
        Err(e) => {
            let _ = evt_tx.send(Evt::Status(format!("Ошибка клиента: {e}")));
            return;
        }
    };
    let self_id = ctx.server_id.clone();
    let keyrings: HashMap<String, Vec<(u64, String)>> =
        ctx.dialogues.iter().map(|d| (d.peer.clone(), d.keyring.clone())).collect();
    let names: HashMap<String, String> =
        ctx.dialogues.iter().map(|d| (d.peer.clone(), d.name.clone())).collect();

    let mut map: HashMap<String, Rc<Dialogue>> = HashMap::new();
    let mut live: Option<tokio::task::JoinHandle<()>> = None;

    let get_dlg = |map: &mut HashMap<String, Rc<Dialogue>>, peer: &str| -> Result<Rc<Dialogue>> {
        if let Some(d) = map.get(peer) {
            return Ok(d.clone());
        }
        let kr = keyrings
            .get(peer)
            .map(|v| v.as_slice())
            .unwrap_or(&[]);
        let d = Rc::new(build_ui_dialogue(&client, &self_id, peer, kr)?);
        map.insert(peer.to_string(), d.clone());
        Ok(d)
    };

    while let Some(cmd) = cmd_rx.recv().await {
        match cmd {
            Cmd::Open(peer) => {
                if let Some(h) = live.take() {
                    h.abort();
                }
                let dlg = match get_dlg(&mut map, &peer) {
                    Ok(d) => d,
                    Err(e) => {
                        let _ = evt_tx.send(Evt::Status(format!("Диалог: {e}")));
                        continue;
                    }
                };
                match dlg.history(300, None).await {
                    Ok(mut v) => {
                        v.reverse();
                        let view: Vec<Msg> =
                            v.iter().filter_map(|m| to_msg(m, &self_id, &names)).collect();
                        let _ = evt_tx.send(Evt::History(peer.clone(), view));
                    }
                    Err(e) => {
                        let _ = evt_tx.send(Evt::Status(format!("История: {e}")));
                    }
                }
                if let Ok((m, _)) = dlg.receive().await {
                    let v: Vec<Msg> = m.iter().filter_map(|x| to_msg(x, &self_id, &names)).collect();
                    if !v.is_empty() {
                        let _ = evt_tx.send(Evt::New(peer.clone(), v));
                    }
                }
                let d = dlg.clone();
                let tx = evt_tx.clone();
                let p = peer.clone();
                let sid = self_id.clone();
                let nm = names.clone();
                live = Some(tokio::task::spawn_local(async move {
                    loop {
                        let _ = d.notify_count_wait(25000).await;
                        match d.receive().await {
                            Ok((m, _)) if !m.is_empty() => {
                                let v: Vec<Msg> =
                                    m.iter().filter_map(|x| to_msg(x, &sid, &nm)).collect();
                                if !v.is_empty() && tx.send(Evt::New(p.clone(), v)).is_err() {
                                    break;
                                }
                            }
                            Ok(_) => {}
                            Err(_) => tokio::time::sleep(Duration::from_secs(2)).await,
                        }
                    }
                }));
            }
            Cmd::Send(peer, text) => {
                if let Some(d) = map.get(&peer).cloned() {
                    match d.send_text(text).await {
                        Ok(m) => {
                            if let Some(v) = to_msg(&m, &self_id, &names) {
                                let _ = evt_tx.send(Evt::New(peer.clone(), vec![v]));
                            }
                        }
                        Err(e) => {
                            let _ = evt_tx.send(Evt::Status(format!("Отправка: {e}")));
                        }
                    }
                }
            }
            Cmd::React(peer, mid, emoji) => {
                if let Some(d) = map.get(&peer).cloned() {
                    match d.send_reaction(&mid, &emoji).await {
                        Ok(_) => {
                            let _ = evt_tx.send(Evt::Status(format!("Реакция {emoji} отправлена")));
                        }
                        Err(e) => {
                            let _ = evt_tx.send(Evt::Status(format!("Реакция: {e}")));
                        }
                    }
                }
            }
            Cmd::SendFile(peer, path) => {
                if let Some(d) = map.get(&peer).cloned() {
                    let pb = std::path::PathBuf::from(&path);
                    if !pb.is_file() {
                        let _ = evt_tx.send(Evt::Status(format!("Файл не найден: {path}")));
                        continue;
                    }
                    let filename = pb
                        .file_name()
                        .and_then(|s| s.to_str())
                        .unwrap_or("attachment.bin")
                        .to_string();
                    let mime = crate::guess_mime(&filename);
                    let _ = evt_tx.send(Evt::Status(format!("Отправляю {filename}…")));
                    match d
                        .send_file_auto_with_progress(filename.clone(), mime, pb.as_path(), |_, _| {})
                        .await
                    {
                        Ok(msgs) => {
                            let v: Vec<Msg> =
                                msgs.iter().filter_map(|m| to_msg(m, &self_id, &names)).collect();
                            if !v.is_empty() {
                                let _ = evt_tx.send(Evt::New(peer.clone(), v));
                            }
                            let _ = evt_tx.send(Evt::Status(format!("Файл отправлен: {filename}")));
                        }
                        Err(e) => {
                            let _ = evt_tx.send(Evt::Status(format!("Файл: {e}")));
                        }
                    }
                }
            }
            Cmd::Download(peer, mid, out) => {
                if let Some(d) = map.get(&peer).cloned() {
                    match d.download_attachment(&mid, &out).await {
                        Ok(_) => {
                            let _ = evt_tx.send(Evt::Status(format!("Скачано → {out}")));
                        }
                        Err(e) => {
                            let _ = evt_tx.send(Evt::Status(format!("Скачивание: {e}")));
                        }
                    }
                }
            }
            Cmd::Quit => break,
        }
    }
}

// ───────────────────────────── выбор профиля (UI-стор) ───────────────────────

fn ui_app_data_root() -> std::path::PathBuf {
    if let Ok(p) = std::env::var("PARANOIA_UI_APP_DATA_ROOT") {
        if !p.trim().is_empty() {
            return std::path::PathBuf::from(p);
        }
    }
    dirs::data_dir()
        .unwrap_or_else(|| std::path::PathBuf::from("."))
        .join("Paranoia")
        .join("ParanoiaUiClient")
}

/// Собрать `UiCtx` из выбранного профиля UI-стора. Возвращает (ctx, dialogues для UI).
fn build_ctx(
    up: &crate::ui_store::UiProfile,
    server_arg: &str,
    reserve: &[String],
    root: &std::path::Path,
) -> Result<(UiCtx, Vec<(String, String)>)> {
    let server_url = if up.server.trim().is_empty() {
        server_arg.to_string()
    } else {
        up.server.trim().to_string()
    };
    let server_id = crate::derive_server_id_b64(&up.private_key)
        .unwrap_or_else(|_| up.server_id.trim().to_string());
    if server_id.is_empty() {
        anyhow::bail!("не удалось определить server_id профиля");
    }
    let pid = crate::dialogue_store::profile_id(&server_url, &server_id);
    let db_path = root
        .join("profiles")
        .join(&pid)
        .join("paranoia.db")
        .to_string_lossy()
        .to_string();

    let mut dialogues = Vec::new();
    let mut ui_list = Vec::new();
    for d in &up.dialogues {
        if d.peer_server_id.trim().is_empty() {
            continue;
        }
        let name = if !d.local_name.trim().is_empty() {
            d.local_name.trim().to_string()
        } else if !d.peer.trim().is_empty() && d.peer.trim() != d.peer_server_id.trim() {
            // метка диалога из UI (ФИО/ник собеседника), не server_id
            d.peer.trim().to_string()
        } else {
            shorten(&d.peer_server_id)
        };
        dialogues.push(DlgData {
            peer: d.peer_server_id.clone(),
            name: name.clone(),
            keyring: d.keyring.clone(),
        });
        ui_list.push((d.peer_server_id.clone(), name));
    }
    ui_list.sort_by(|a, b| a.1.to_lowercase().cmp(&b.1.to_lowercase()));

    let ctx = UiCtx {
        server_url,
        reserve: reserve.to_vec(),
        server_id,
        private_key: up.private_key.clone(),
        db_path,
        dialogues,
    };
    Ok((ctx, ui_list))
}

// ──────────────────────── добавление профиля (рег./импорт) ───────────────────

fn profile_label(p: &crate::ui_store::UiProfile) -> String {
    if p.username.trim().is_empty() || p.username.trim() == p.server_id.trim() {
        shorten(&p.server_id)
    } else {
        p.username.trim().to_string()
    }
}

/// Сгенерировать Ed25519-пару: (secret_b64, pubkey_b64).
fn gen_keypair() -> (String, String) {
    use rand::RngCore;
    let mut sk = [0u8; 32];
    rand::rngs::OsRng.fill_bytes(&mut sk);
    let signing = SigningKey::from_bytes(&sk);
    let pubk = signing.verifying_key().to_bytes();
    (B64.encode(sk), B64.encode(pubk))
}

/// Ключ self-диалога «Избранное» — как у UI-клиента
/// (`SHA256("paranoia:self-dialog:v1\n" + server_id + private_key)`, 32 байта).
fn self_dialog_keyring(server_id: &str, private_key_b64: &str) -> Vec<(u64, String)> {
    use sha2::{Digest, Sha256};
    let mut h = Sha256::new();
    h.update(b"paranoia:self-dialog:v1\n");
    h.update(server_id.as_bytes());
    h.update(private_key_b64.as_bytes());
    let digest = h.finalize();
    vec![(1, B64.encode(&digest[..32]))]
}

fn prompt_line(label: &str) -> Result<String> {
    use std::io::Write;
    eprint!("{label}");
    let _ = std::io::stderr().flush();
    let mut line = String::new();
    if std::io::stdin().read_line(&mut line)? == 0 {
        anyhow::bail!("ввод прерван");
    }
    Ok(line.trim().to_string())
}

/// Регистрация: сгенерировать ключ, показать pubkey для админа, создать профиль
/// в UI-сторе (+ self-диалог «Избранное»). Возвращает server_id нового профиля.
fn do_register(root: &std::path::Path, server_default: &str) -> Result<String> {
    let s = prompt_line(&format!("Адрес сервера [{server_default}]: "))?;
    let server = if s.is_empty() { server_default.to_string() } else { s };
    if server.trim().is_empty() {
        anyhow::bail!("адрес сервера обязателен");
    }

    let (secret_b64, pubkey_b64) = gen_keypair();
    let server_id = crate::derive_server_id_b64(&secret_b64)?;
    let keyring = self_dialog_keyring(&server_id, &secret_b64);
    let dialogs = vec![crate::ui_store::NewDialog {
        peer: "Избранное".to_string(),
        peer_server_id: server_id.clone(),
        local_name: String::new(),
        keyring,
    }];
    // username хранит server_id (как у UI; локальный ник правится в настройках UI).
    crate::ui_store::create_profile(root, &server, &server_id, &secret_b64, &server_id, &dialogs)?;

    eprintln!("\n✅ Профиль создан в UI-сторе.");
    eprintln!("───────────────────────────────────────────────");
    eprintln!("Передай админу ПУБЛИЧНЫЙ КЛЮЧ для регистрации на сервере:");
    eprintln!("  pubkey:    {pubkey_b64}");
    eprintln!("  server_id: {server_id}");
    eprintln!("───────────────────────────────────────────────");
    eprintln!("Войти в профиль можно будет, как только админ зарегистрирует ключ.\n");
    Ok(server_id)
}

/// Импорт: расшифровать .json-экспорт device-ключом UI и материализовать
/// профиль(и) в UI-сторе. Возвращает число импортированных профилей.
fn do_import(root: &std::path::Path) -> Result<usize> {
    // Подсказываем device-pubkey: на него должен быть зашифрован экспорт.
    match crate::ui_store::ui_device_pubkey_b64(root) {
        Ok(pk) => {
            eprintln!("Device-pubkey этого стора (на него шифруй экспорт): {pk}");
        }
        Err(e) => eprintln!("(не удалось прочитать device-ключ: {e})"),
    }
    let path_s = prompt_line("Путь к файлу экспорта (.json): ")?;
    let path = std::path::PathBuf::from(&path_s);
    if !path.is_file() {
        anyhow::bail!("файл не найден: {}", path.display());
    }

    let device_priv = crate::ui_store::ui_device_priv(root)?;
    let envelope = std::fs::read_to_string(&path).context("чтение файла экспорта")?;
    let plaintext = ecies_decrypt(&device_priv, &envelope)
        .context("расшифровка экспорта (файл зашифрован не на этот device-ключ?)")?;
    let payload: ExportPayload =
        serde_json::from_slice(&plaintext).context("некорректный payload экспорта")?;
    validate_export_payload(&payload)?;

    let mut count = 0usize;
    for srv in &payload.servers {
        let server_id = crate::derive_server_id_b64(&srv.signing_key_b64)?;
        let dialogs: Vec<crate::ui_store::NewDialog> = srv
            .dialogues
            .iter()
            .filter_map(|d| {
                let psid = d.peer_server_id.clone().unwrap_or_default();
                if psid.trim().is_empty() {
                    return None; // без server_id диалог не восстановить
                }
                Some(crate::ui_store::NewDialog {
                    peer: d.peer.clone(),
                    peer_server_id: psid,
                    local_name: String::new(),
                    keyring: d.keyring.iter().map(|k| (k.start_seq, k.key.clone())).collect(),
                })
            })
            .collect();
        crate::ui_store::create_profile(
            root,
            &srv.url,
            &server_id,
            &srv.signing_key_b64,
            &server_id,
            &dialogs,
        )?;
        count += 1;
    }
    eprintln!("\n✅ Импортировано профилей: {count}\n");
    Ok(count)
}

/// Меню выбора профиля с возможностью зарегистрировать новый или импортировать.
/// Vault уже должен быть разлочен. Возвращает выбранный профиль (по значению).
fn choose_profile(
    root: &std::path::Path,
    server_url: &str,
    username_opt: Option<String>,
) -> Result<crate::ui_store::UiProfile> {
    use std::io::Write;
    let mut selector = username_opt.filter(|s| !s.trim().is_empty());

    loop {
        let mut profiles = crate::ui_store::list_ui_profiles(root, None)?;

        // Явный селектор из аргумента — применяем один раз.
        if let Some(sel) = selector.take() {
            if let Some(i) = profiles.iter().position(|p| {
                p.username == sel || p.server_id == sel || p.server_id.starts_with(&sel)
            }) {
                return Ok(profiles.swap_remove(i));
            }
            eprintln!("Профиль «{sel}» не найден, выбери из списка.");
        }

        eprintln!("\nПрофили:");
        if profiles.is_empty() {
            eprintln!("  (пусто — зарегистрируй новый или импортируй)");
        }
        for (i, p) in profiles.iter().enumerate() {
            eprintln!("  {}) {}  ({})", i + 1, profile_label(p), p.server);
        }
        let reg_n = profiles.len() + 1;
        let imp_n = profiles.len() + 2;
        eprintln!("  {reg_n}) ➕ Зарегистрировать новый профиль");
        eprintln!("  {imp_n}) 📥 Импортировать профиль из файла");

        eprint!("Номер: ");
        let _ = std::io::stderr().flush();
        let mut line = String::new();
        if std::io::stdin().read_line(&mut line).unwrap_or(0) == 0 {
            anyhow::bail!("ввод прерван");
        }
        let n: usize = match line.trim().parse() {
            Ok(n) => n,
            Err(_) => {
                eprintln!("Введите номер из списка.");
                continue;
            }
        };
        if n >= 1 && n <= profiles.len() {
            return Ok(profiles.swap_remove(n - 1));
        }
        if n == reg_n {
            match do_register(root, server_url) {
                Ok(sid) => {
                    let mut ps = crate::ui_store::list_ui_profiles(root, None)?;
                    if let Some(i) = ps.iter().position(|p| p.server_id == sid) {
                        return Ok(ps.swap_remove(i));
                    }
                }
                Err(e) => eprintln!("Регистрация не удалась: {e}"),
            }
            continue;
        }
        if n == imp_n {
            if let Err(e) = do_import(root) {
                eprintln!("Импорт не удался: {e}");
            }
            continue; // вернёмся в меню — импортированные профили появятся
        }
        eprintln!("Введите номер из списка.");
    }
}

// ───────────────────────────────── публичный вход ───────────────────────────

pub async fn run(
    server_url: String,
    reserve: Vec<String>,
    _db_path: String,
    username_opt: Option<String>,
) -> Result<()> {
    let root = ui_app_data_root();
    if !root.exists() {
        anyhow::bail!(
            "каталог UI-клиента не найден: {} (запусти UI-клиент хотя бы раз или задай PARANOIA_UI_APP_DATA_ROOT)",
            root.display()
        );
    }

    // PIN UI-клиента: env PARANOIA_UI_PIN или скрытый ввод (до 3 попыток).
    let mut pin = match std::env::var("PARANOIA_UI_PIN") {
        Ok(p) if !p.trim().is_empty() => p,
        _ => rpassword::prompt_password("PIN UI-клиента: ").context("ввод PIN")?,
    };
    loop {
        match crate::ui_store::unlock_ui_vault(&root, &pin) {
            Ok(()) => break,
            Err(e) => {
                eprintln!("{e}");
                pin = rpassword::prompt_password("PIN UI-клиента (повтор): ").context("ввод PIN")?;
            }
        }
    }

    // Выбор/создание/импорт профиля.
    let chosen = choose_profile(&root, &server_url, username_opt)?;
    let (ctx, dialogues) = build_ctx(&chosen, &server_url, &reserve, &root)?;

    let (cmd_tx, cmd_rx) = tokio::sync::mpsc::unbounded_channel::<Cmd>();
    let (evt_tx, evt_rx) = std::sync::mpsc::channel::<Evt>();

    let worker = std::thread::spawn(move || {
        let rt = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
            Ok(rt) => rt,
            Err(_) => return,
        };
        let local = tokio::task::LocalSet::new();
        rt.block_on(local.run_until(worker_loop(ctx, cmd_rx, evt_tx)));
    });

    let mut terminal = ratatui::init();
    let res = ui_loop(&mut terminal, &cmd_tx, &evt_rx, dialogues);
    ratatui::restore();

    let _ = cmd_tx.send(Cmd::Quit);
    let _ = worker.join();
    res
}

// ──────────────────────────────── UI-состояние ──────────────────────────────

#[derive(PartialEq, Clone, Copy)]
enum Focus {
    List,
    Messages,
    Input,
}

enum Popup {
    None,
    Reactions,
    FilePrompt(String),
    Help,
}

const EMOJIS: [&str; 10] = ["👀", "🤔", "✍️", "✔️", "👍", "❤️", "😂", "🔥", "👌", "🙏"];

// Акцентные цвета в стиле клиента Paranoia (Theme.qml: accent #C91122,
// accentHover #FF2738).
const ACCENT: Color = Color::Rgb(0xC9, 0x11, 0x22);
const ACCENT_HI: Color = Color::Rgb(0xFF, 0x27, 0x38);

fn border_style(focused: bool) -> Style {
    if focused {
        Style::new().fg(ACCENT)
    } else {
        Style::new().fg(Color::DarkGray)
    }
}

struct App {
    dialogues: Vec<(String, String)>,
    sel: usize,
    active: Option<String>,
    msgs: HashMap<String, Vec<Msg>>,
    focus: Focus,
    input: String,
    msg_sel: usize,
    status: String,
    popup: Popup,
}

impl App {
    fn new(dialogues: Vec<(String, String)>) -> Self {
        App {
            dialogues,
            sel: 0,
            active: None,
            msgs: HashMap::new(),
            focus: Focus::List,
            input: String::new(),
            msg_sel: 0,
            status: "Tab — панели · Enter — открыть/отправить · r — реакция · d — скачать · a — файл · ? — помощь · q — выход".to_string(),
            popup: Popup::None,
        }
    }

    fn active_msgs(&self) -> &[Msg] {
        self.active
            .as_ref()
            .and_then(|p| self.msgs.get(p))
            .map(|v| v.as_slice())
            .unwrap_or(&[])
    }

    fn apply(&mut self, evt: Evt) {
        match evt {
            Evt::History(peer, v) => {
                let mut vec = Vec::new();
                fold_messages(&mut vec, v);
                let is_active = self.active.as_deref() == Some(peer.as_str());
                self.msgs.insert(peer, vec);
                if is_active {
                    self.msg_sel = self.active_msgs().len().saturating_sub(1);
                }
            }
            Evt::New(peer, v) => {
                let is_active = self.active.as_deref() == Some(peer.as_str());
                // Автоскролл к низу только если пользователь уже был внизу;
                // иначе не дёргаем его из прочитанного места.
                let was_at_bottom = !is_active
                    || self.msg_sel + 1 >= self.active_msgs().len();
                let entry = self.msgs.entry(peer.clone()).or_default();
                fold_messages(entry, v);
                if is_active {
                    let last = self.active_msgs().len().saturating_sub(1);
                    if was_at_bottom {
                        self.msg_sel = last;
                    } else {
                        self.msg_sel = self.msg_sel.min(last);
                    }
                }
            }
            Evt::Status(s) => self.status = s,
        }
    }
}

/// Слить входящие в ленту: обычные — добавить (дедуп по id); реакции (target_id)
/// — прилепить эмодзи к целевому сообщению (не отдельной строкой).
fn fold_messages(existing: &mut Vec<Msg>, incoming: Vec<Msg>) {
    // Два прохода: сначала добавляем обычные сообщения, потом прилепляем реакции.
    // Иначе реакция, идущая в пачке раньше своего таргета (в истории так и бывает),
    // не нашла бы цель и потерялась.
    let mut reactions: Vec<Msg> = Vec::new();
    for m in incoming {
        if m.target_id.is_some() {
            reactions.push(m);
            continue;
        }
        if !existing.iter().any(|x| x.id == m.id) {
            existing.push(m);
        }
    }
    for m in reactions {
        let tid = match &m.target_id {
            Some(t) => t.clone(),
            None => continue,
        };
        // эмодзи + полное имя реактора (строка отдельная, места хватает)
        let badge = if m.who.trim().is_empty() {
            m.body.clone()
        } else {
            format!("{} {}", m.body, m.who.trim())
        };
        if let Some(t) = existing.iter_mut().find(|x| x.id == tid) {
            if !t.reactions.contains(&badge) {
                t.reactions.push(badge);
            }
        }
        // реакция без найденного таргета — пропускаем
    }
    // Лента всегда старые → новые (новейшее снизу).
    existing.sort_by_key(|m| m.sort_ts);
}

/// Перенос строки по ширине (по словам; длинное слово рвём). Ширина в символах.
fn wrap_text(s: &str, width: usize) -> Vec<String> {
    let width = width.max(8);
    let mut lines = Vec::new();
    for raw in s.split('\n') {
        let mut cur = String::new();
        let mut cur_len = 0usize;
        for word in raw.split(' ') {
            let wlen = word.chars().count();
            if wlen > width {
                // длинное слово — рвём по символам
                if !cur.is_empty() {
                    lines.push(std::mem::take(&mut cur));
                    cur_len = 0;
                }
                let mut chunk = String::new();
                let mut clen = 0;
                for ch in word.chars() {
                    if clen == width {
                        lines.push(std::mem::take(&mut chunk));
                        clen = 0;
                    }
                    chunk.push(ch);
                    clen += 1;
                }
                if !chunk.is_empty() {
                    cur = chunk;
                    cur_len = clen;
                }
                continue;
            }
            let add = if cur.is_empty() { wlen } else { wlen + 1 };
            if cur_len + add > width {
                lines.push(std::mem::take(&mut cur));
                cur = word.to_string();
                cur_len = wlen;
            } else {
                if !cur.is_empty() {
                    cur.push(' ');
                }
                cur.push_str(word);
                cur_len += add;
            }
        }
        lines.push(cur);
    }
    if lines.is_empty() {
        lines.push(String::new());
    }
    lines
}

fn ui_loop(
    terminal: &mut DefaultTerminal,
    cmd_tx: &tokio::sync::mpsc::UnboundedSender<Cmd>,
    evt_rx: &std::sync::mpsc::Receiver<Evt>,
    dialogues: Vec<(String, String)>,
) -> Result<()> {
    let mut app = App::new(dialogues);
    if !app.dialogues.is_empty() {
        app.active = Some(app.dialogues[0].0.clone());
        app.focus = Focus::Messages;
        let _ = cmd_tx.send(Cmd::Open(app.dialogues[0].0.clone()));
    }

    loop {
        while let Ok(evt) = evt_rx.try_recv() {
            app.apply(evt);
        }
        terminal.draw(|f| draw(f, &app))?;
        if event::poll(Duration::from_millis(100))? {
            if let Event::Key(k) = event::read()? {
                if k.kind == KeyEventKind::Press && handle_key(&mut app, k, cmd_tx) {
                    break;
                }
            }
        }
    }
    Ok(())
}

fn handle_key(
    app: &mut App,
    k: ratatui::crossterm::event::KeyEvent,
    cmd_tx: &tokio::sync::mpsc::UnboundedSender<Cmd>,
) -> bool {
    if k.modifiers.contains(KeyModifiers::CONTROL) && k.code == KeyCode::Char('c') {
        return true;
    }

    match &mut app.popup {
        Popup::Help => {
            app.popup = Popup::None;
            return false;
        }
        Popup::Reactions => {
            match k.code {
                KeyCode::Esc => app.popup = Popup::None,
                KeyCode::Char(c) if c.is_ascii_digit() => {
                    let idx = if c == '0' { 9 } else { (c as u8 - b'1') as usize };
                    if let (Some(peer), Some(m)) =
                        (app.active.clone(), app.active_msgs().get(app.msg_sel).cloned())
                    {
                        if idx < EMOJIS.len() {
                            let _ = cmd_tx.send(Cmd::React(peer, m.id, EMOJIS[idx].to_string()));
                        }
                    }
                    app.popup = Popup::None;
                }
                _ => {}
            }
            return false;
        }
        Popup::FilePrompt(buf) => {
            match k.code {
                KeyCode::Esc => app.popup = Popup::None,
                KeyCode::Enter => {
                    let path = buf.trim().to_string();
                    if let Some(peer) = app.active.clone() {
                        if !path.is_empty() {
                            let _ = cmd_tx.send(Cmd::SendFile(peer, path));
                        }
                    }
                    app.popup = Popup::None;
                }
                KeyCode::Backspace => {
                    buf.pop();
                }
                KeyCode::Char(c) => buf.push(c),
                _ => {}
            }
            return false;
        }
        Popup::None => {}
    }

    if app.focus == Focus::Input {
        match k.code {
            KeyCode::Esc => app.focus = Focus::Messages,
            KeyCode::Tab => app.focus = Focus::List, // циклический Tab: выходим из поля ввода
            KeyCode::Enter => {
                let text = app.input.trim().to_string();
                app.input.clear();
                if let Some(peer) = app.active.clone() {
                    if let Some(rest) = text.strip_prefix("/file ") {
                        let _ = cmd_tx.send(Cmd::SendFile(peer, rest.trim().to_string()));
                    } else if !text.is_empty() {
                        let _ = cmd_tx.send(Cmd::Send(peer, text));
                    }
                }
            }
            KeyCode::Backspace => {
                app.input.pop();
            }
            KeyCode::Char(c) => app.input.push(c),
            _ => {}
        }
        return false;
    }

    match k.code {
        KeyCode::Char('q') | KeyCode::Esc => return true,
        KeyCode::Char('?') => app.popup = Popup::Help,
        KeyCode::Tab => {
            app.focus = match app.focus {
                Focus::List => Focus::Messages,
                Focus::Messages => Focus::Input,
                Focus::Input => Focus::List,
            };
        }
        KeyCode::Char('i') => app.focus = Focus::Input,
        KeyCode::Char('a') => app.popup = Popup::FilePrompt(String::new()),
        KeyCode::Up | KeyCode::Char('k') => match app.focus {
            Focus::List => {
                if app.sel > 0 {
                    app.sel -= 1;
                }
            }
            Focus::Messages => {
                if app.msg_sel > 0 {
                    app.msg_sel -= 1;
                }
            }
            _ => {}
        },
        KeyCode::Down | KeyCode::Char('j') => match app.focus {
            Focus::List => {
                if app.sel + 1 < app.dialogues.len() {
                    app.sel += 1;
                }
            }
            Focus::Messages => {
                let n = app.active_msgs().len();
                if n > 0 && app.msg_sel + 1 < n {
                    app.msg_sel += 1;
                }
            }
            _ => {}
        },
        KeyCode::Enter | KeyCode::Right => {
            if app.focus == Focus::List {
                if let Some((id, _)) = app.dialogues.get(app.sel).cloned() {
                    app.active = Some(id.clone());
                    app.msg_sel = 0;
                    app.focus = Focus::Messages;
                    let _ = cmd_tx.send(Cmd::Open(id));
                }
            }
        }
        KeyCode::Left => app.focus = Focus::List,
        KeyCode::Char('r') => {
            if app.focus == Focus::Messages && !app.active_msgs().is_empty() {
                app.popup = Popup::Reactions;
            }
        }
        KeyCode::Char('d') => {
            if app.focus == Focus::Messages {
                if let (Some(peer), Some(m)) =
                    (app.active.clone(), app.active_msgs().get(app.msg_sel).cloned())
                {
                    if let Some(att) = m.att {
                        let dir = dirs::download_dir()
                            .or_else(dirs::home_dir)
                            .unwrap_or_else(|| std::path::PathBuf::from("."));
                        let out = dir.join(&att.filename);
                        let _ = cmd_tx.send(Cmd::Download(peer, m.id, out.to_string_lossy().to_string()));
                    } else {
                        app.status = "У этого сообщения нет вложения".to_string();
                    }
                }
            }
        }
        _ => {}
    }
    false
}

// ──────────────────────────────── рендер ────────────────────────────────────

fn draw(f: &mut Frame, app: &App) {
    let cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Length(30), Constraint::Min(0)])
        .split(f.area());

    let focus_list = app.focus == Focus::List;
    let items: Vec<ListItem> = app
        .dialogues
        .iter()
        .map(|(id, name)| {
            let active = app.active.as_deref() == Some(id.as_str());
            if active {
                ListItem::new(Line::from(vec![
                    Span::styled("● ", Style::new().fg(ACCENT)),
                    Span::styled(name.clone(), Style::new().add_modifier(Modifier::BOLD)),
                ]))
            } else {
                ListItem::new(Line::from(format!("  {name}")))
            }
        })
        .collect();
    let mut lst_state = ListState::default();
    lst_state.select(Some(app.sel.min(app.dialogues.len().saturating_sub(1))));
    let hl = if focus_list {
        Style::new().bg(ACCENT).fg(Color::White).add_modifier(Modifier::BOLD)
    } else {
        Style::new().add_modifier(Modifier::DIM)
    };
    let list = List::new(items)
        .block(
            Block::bordered()
                .title(" Диалоги ")
                .border_style(border_style(focus_list))
                .title_style(Style::new().fg(ACCENT).add_modifier(Modifier::BOLD)),
        )
        .highlight_style(hl);
    f.render_stateful_widget(list, cols[0], &mut lst_state);

    let right = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(0), Constraint::Length(3), Constraint::Length(1)])
        .split(cols[1]);

    let title_name = app
        .active
        .as_ref()
        .and_then(|p| app.dialogues.iter().find(|(id, _)| id == p))
        .map(|(_, n)| n.clone())
        .unwrap_or_else(|| "—".to_string());
    let focus_msgs = app.focus == Focus::Messages;
    let msgs_title = format!(" {title_name} ");

    // Доступная ширина для текста внутри ленты (минус рамки и небольшой отступ).
    let text_width = (right[0].width as usize).saturating_sub(4).max(8);
    // Метки даты: Сегодня / Вчера / дд.мм.гггг.
    let today = chrono::Local::now().format("%d.%m.%Y").to_string();
    let yesterday = (chrono::Local::now() - chrono::Duration::days(1))
        .format("%d.%m.%Y")
        .to_string();
    let date_label = |d: &str| -> String {
        if d == today {
            "Сегодня".to_string()
        } else if d == yesterday {
            "Вчера".to_string()
        } else {
            d.to_string()
        }
    };

    let mut rows: Vec<ListItem> = Vec::new();
    // row_for_msg[i] = индекс строки-ListItem, соответствующей сообщению i
    // (нужно из-за вставленных разделителей дат — выделение/навигация идут по
    // индексам сообщений, а не строк).
    let mut row_for_msg: Vec<usize> = Vec::new();
    let mut prev_date = String::new();
    let sep_width = (right[0].width as usize).saturating_sub(2).max(4);
    for m in app.active_msgs() {
        if m.date != prev_date {
            prev_date = m.date.clone();
            let label = format!(" {} ", date_label(&m.date));
            let dashes = sep_width.saturating_sub(label.chars().count());
            let left = dashes / 2;
            let right = dashes - left;
            let sep = format!(
                "{}{}{}",
                "─".repeat(left),
                label,
                "─".repeat(right)
            );
            rows.push(ListItem::new(Line::from(Span::styled(
                sep,
                Style::new().fg(ACCENT).add_modifier(Modifier::BOLD),
            ))));
        }
        let who_style = if m.me {
            Style::new().fg(ACCENT).add_modifier(Modifier::BOLD)
        } else {
            Style::new().fg(Color::Cyan).add_modifier(Modifier::BOLD)
        };
        let prefix = format!("{} {}: ", m.ts, m.who);
        let indent = " ".repeat(prefix.chars().count().min(text_width.saturating_sub(1)));
        let wrap_w = text_width.saturating_sub(prefix.chars().count()).max(8);
        let wrapped = wrap_text(&m.body, wrap_w);
        let mut lines: Vec<Line> = Vec::new();
        for (i, seg) in wrapped.iter().enumerate() {
            if i == 0 {
                lines.push(Line::from(vec![
                    Span::styled(format!("{} ", m.ts), Style::new().fg(Color::DarkGray)),
                    Span::styled(format!("{}: ", m.who), who_style),
                    Span::raw(seg.clone()),
                ]));
            } else {
                lines.push(Line::from(vec![
                    Span::raw(indent.clone()),
                    Span::raw(seg.clone()),
                ]));
            }
        }
        if !m.reactions.is_empty() {
            lines.push(Line::from(vec![
                Span::raw(indent.clone()),
                Span::styled(m.reactions.join("   "), Style::new().fg(ACCENT_HI)),
            ]));
        }
        row_for_msg.push(rows.len());
        rows.push(ListItem::new(lines));
    }
    let mut msg_state = ListState::default();
    if !app.active_msgs().is_empty() {
        let sel = app.msg_sel.min(app.active_msgs().len() - 1);
        msg_state.select(Some(row_for_msg[sel]));
    }
    let msg_hl = if focus_msgs {
        Style::new().fg(ACCENT_HI).add_modifier(Modifier::BOLD)
    } else {
        Style::new().add_modifier(Modifier::DIM)
    };
    let msg_list = List::new(rows)
        .block(
            Block::bordered()
                .title(msgs_title)
                .border_style(border_style(focus_msgs))
                .title_style(Style::new().fg(ACCENT).add_modifier(Modifier::BOLD)),
        )
        .highlight_style(msg_hl)
        .highlight_symbol("▌");
    f.render_stateful_widget(msg_list, right[0], &mut msg_state);

    let focus_input = app.focus == Focus::Input;
    let input_title = if focus_input { " Ввод (Enter — отправить) " } else { " Ввод (i) " };
    let input = Paragraph::new(app.input.as_str())
        .block(
            Block::bordered()
                .title(input_title)
                .border_style(border_style(focus_input))
                .title_style(Style::new().fg(ACCENT)),
        )
        .wrap(Wrap { trim: false });
    f.render_widget(input, right[1]);
    if focus_input {
        let x = right[1].x + 1 + (app.input.chars().count() as u16).min(right[1].width.saturating_sub(2));
        f.set_cursor_position((x, right[1].y + 1));
    }

    let status = Paragraph::new(Line::from(app.status.clone())).style(Style::new().fg(ACCENT_HI));
    f.render_widget(status, right[2]);

    match &app.popup {
        Popup::Reactions => {
            let area = centered(f.area(), 44, 7);
            f.render_widget(Clear, area);
            let line: String = EMOJIS
                .iter()
                .enumerate()
                .map(|(i, e)| format!("{}:{} ", (i + 1) % 10, e))
                .collect();
            let p = Paragraph::new(vec![
                Line::from("Реакция на выбранное сообщение:"),
                Line::from(""),
                Line::from(line),
                Line::from(""),
                Line::from("цифра — поставить · Esc — отмена"),
            ])
            .block(Block::bordered().title(" Реакция ").border_style(Style::new().fg(ACCENT)).title_style(Style::new().fg(ACCENT)))
            .wrap(Wrap { trim: false });
            f.render_widget(p, area);
        }
        Popup::FilePrompt(buf) => {
            let area = centered(f.area(), 60, 5);
            f.render_widget(Clear, area);
            let p = Paragraph::new(vec![
                Line::from("Путь к файлу для отправки:"),
                Line::from(buf.as_str()),
                Line::from("Enter — отправить · Esc — отмена"),
            ])
            .block(Block::bordered().title(" Отправить файл ").border_style(Style::new().fg(ACCENT)).title_style(Style::new().fg(ACCENT)));
            f.render_widget(p, area);
            let x = area.x + 1 + (buf.chars().count() as u16).min(area.width.saturating_sub(2));
            f.set_cursor_position((x, area.y + 2));
        }
        Popup::Help => {
            let area = centered(f.area(), 56, 14);
            f.render_widget(Clear, area);
            let p = Paragraph::new(vec![
                Line::from("Горячие клавиши:"),
                Line::from(""),
                Line::from("Tab — переключить панель (Диалоги/Лента/Ввод)"),
                Line::from("↑/↓ или k/j — выбор диалога/сообщения"),
                Line::from("Enter/→ — открыть диалог (в списке)"),
                Line::from("i — поле ввода; Enter — отправить"),
                Line::from("r — реакция на сообщение (в Ленте)"),
                Line::from("d — скачать вложение (в Ленте)"),
                Line::from("a — отправить файл (выбор пути)"),
                Line::from("/file <путь> в Вводе — тоже отправка файла"),
                Line::from("q/Esc — выход · Ctrl-C — выход"),
                Line::from(""),
                Line::from("любая клавиша — закрыть"),
            ])
            .block(Block::bordered().title(" Помощь ").border_style(Style::new().fg(ACCENT)).title_style(Style::new().fg(ACCENT)));
            f.render_widget(p, area);
        }
        Popup::None => {}
    }
}

fn centered(area: ratatui::layout::Rect, w: u16, h: u16) -> ratatui::layout::Rect {
    let w = w.min(area.width);
    let h = h.min(area.height);
    let x = area.x + (area.width.saturating_sub(w)) / 2;
    let y = area.y + (area.height.saturating_sub(h)) / 2;
    ratatui::layout::Rect { x, y, width: w, height: h }
}
