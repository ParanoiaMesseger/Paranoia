//! `paranoia-cli mcp install` — мастер установки MCP-сервера.
//!
//! Делает всё, что раньше делал tools/install_mcp.sh, но из самого бинаря и
//! кросс-хостно: копирует бинарь в workdir, провижинит профиль (из стора UI
//! напрямую ЛИБО импортом export-файла), затем регистрирует MCP-сервер в выбранных
//! хостах (Claude Code/Desktop, Cursor, Windsurf, Cline, Codex).
//!
//! Двойной режим:
//!  • человек — интерактивные вопросы (tty), PIN'ы скрытым вводом;
//!  • агент/скрипт — всё флагами + `--non-interactive` (+ `--json` для разбора).
//! Подсказки/вопросы идут в STDERR, машинный результат `--json` — в STDOUT.

use anyhow::{Context, Result, anyhow, bail};
use serde_json::{Map, Value, json};
use std::fs;
use std::io::{self, IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::InstallSource;

pub struct InstallOpts {
    pub server_url: String,
    pub workdir: Option<PathBuf>,
    pub pin: Option<String>,
    pub source: Option<InstallSource>,
    pub ui_app_data_root: Option<PathBuf>,
    pub ui_pin: Option<String>,
    pub export_file: Option<PathBuf>,
    pub username: Option<String>,
    pub peer: Option<String>,
    pub hosts: Vec<String>,
    pub non_interactive: bool,
    pub dry_run: bool,
    pub json: bool,
}

// ─────────────────────────── реестр поддерживаемых хостов ────────────────────

#[derive(Clone, Copy, PartialEq, Eq)]
enum HostKind {
    /// Регистрация через `claude mcp add` (CLI Claude Code).
    ClaudeCli,
    /// JSON-файл вида {"mcpServers": {"<name>": {command,args,env}}}.
    JsonMcpServers,
    /// TOML ~/.codex/config.toml — добавляем [mcp_servers.<name>] если нет.
    CodexToml,
}

struct HostDef {
    id: &'static str,
    name: &'static str,
    kind: HostKind,
}

const HOSTS: &[HostDef] = &[
    HostDef { id: "claude-code", name: "Claude Code (CLI)", kind: HostKind::ClaudeCli },
    HostDef { id: "claude-desktop", name: "Claude Desktop", kind: HostKind::JsonMcpServers },
    HostDef { id: "cursor", name: "Cursor", kind: HostKind::JsonMcpServers },
    HostDef { id: "windsurf", name: "Windsurf (Codeium)", kind: HostKind::JsonMcpServers },
    HostDef { id: "cline", name: "Cline (VS Code)", kind: HostKind::JsonMcpServers },
    HostDef { id: "codex", name: "Codex CLI (OpenAI)", kind: HostKind::CodexToml },
];

fn host_ids() -> Vec<&'static str> {
    HOSTS.iter().map(|h| h.id).collect()
}

fn host_def(id: &str) -> Option<&'static HostDef> {
    HOSTS.iter().find(|h| h.id == id)
}

/// Путь конфиг-файла хоста (None для CLI-хостов и неизвестных). `home` — НАСТОЯЩИЙ
/// домашний каталог пользователя (его захватывают ДО подмены $HOME на workdir).
fn host_config_path(home: &Path, id: &str) -> Option<PathBuf> {
    match id {
        "cursor" => Some(home.join(".cursor").join("mcp.json")),
        "windsurf" => Some(home.join(".codeium").join("windsurf").join("mcp_config.json")),
        "codex" => Some(home.join(".codex").join("config.toml")),
        "claude-desktop" => claude_desktop_config(home),
        "cline" => vscode_user_dir(home).map(|d| {
            d.join("globalStorage")
                .join("saoudrizwan.claude-dev")
                .join("settings")
                .join("cline_mcp_settings.json")
        }),
        _ => None,
    }
}

fn claude_desktop_config(home: &Path) -> Option<PathBuf> {
    #[cfg(target_os = "macos")]
    return Some(
        home.join("Library")
            .join("Application Support")
            .join("Claude")
            .join("claude_desktop_config.json"),
    );
    #[cfg(target_os = "windows")]
    return dirs::config_dir().map(|c| c.join("Claude").join("claude_desktop_config.json"));
    #[cfg(all(unix, not(target_os = "macos")))]
    return Some(home.join(".config").join("Claude").join("claude_desktop_config.json"));
    #[allow(unreachable_code)]
    {
        let _ = home;
        None
    }
}

fn vscode_user_dir(home: &Path) -> Option<PathBuf> {
    #[cfg(target_os = "macos")]
    return Some(
        home.join("Library")
            .join("Application Support")
            .join("Code")
            .join("User"),
    );
    #[cfg(target_os = "windows")]
    return dirs::config_dir().map(|c| c.join("Code").join("User"));
    #[cfg(all(unix, not(target_os = "macos")))]
    return Some(home.join(".config").join("Code").join("User"));
    #[allow(unreachable_code)]
    {
        let _ = home;
        None
    }
}

fn binary_on_path(name: &str) -> bool {
    let Some(paths) = std::env::var_os("PATH") else {
        return false;
    };
    std::env::split_paths(&paths).any(|dir| {
        dir.join(name).is_file()
            || dir.join(format!("{name}.exe")).is_file()
            || dir.join(format!("{name}.cmd")).is_file()
    })
}

/// Хост «обнаружен», если есть CLI (claude) или каталог/файл его конфига.
fn host_detected(home: &Path, id: &str) -> bool {
    if id == "claude-code" {
        return binary_on_path("claude");
    }
    match host_config_path(home, id) {
        Some(p) => p.exists() || p.parent().map(|d| d.exists()).unwrap_or(false),
        None => false,
    }
}

// ─────────────────────────── спецификация регистрации ────────────────────────

struct RegSpec {
    name: String,
    command: String,
    args: Vec<String>,
    env: Vec<(String, String)>,
}

fn spec_to_json(spec: &RegSpec) -> Value {
    let env: Map<String, Value> = spec
        .env
        .iter()
        .map(|(k, v)| (k.clone(), Value::String(v.clone())))
        .collect();
    json!({ "command": spec.command, "args": spec.args, "env": Value::Object(env) })
}

fn backup_if_exists(path: &Path) -> Result<()> {
    if path.exists() {
        let bak = PathBuf::from(format!("{}.paranoia.bak", path.display()));
        fs::copy(path, &bak).with_context(|| format!("backup {}", path.display()))?;
    }
    Ok(())
}

fn register_json_mcp_servers(path: &Path, spec: &RegSpec, dry_run: bool) -> Result<String> {
    let mut root: Value = if path.exists() {
        let txt = fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
        if txt.trim().is_empty() {
            json!({})
        } else {
            serde_json::from_str(&txt)
                .with_context(|| format!("{} — невалидный JSON", path.display()))?
        }
    } else {
        json!({})
    };
    let obj = root
        .as_object_mut()
        .ok_or_else(|| anyhow!("{}: корень не JSON-объект", path.display()))?;
    let servers = obj.entry("mcpServers").or_insert_with(|| json!({}));
    let servers = servers
        .as_object_mut()
        .ok_or_else(|| anyhow!("{}: mcpServers не объект", path.display()))?;
    servers.insert(spec.name.clone(), spec_to_json(spec));

    if dry_run {
        return Ok(format!("(dry-run) {} ← mcpServers.{}", path.display(), spec.name));
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("mkdir {}", parent.display()))?;
    }
    backup_if_exists(path)?;
    let pretty = serde_json::to_string_pretty(&root)?;
    fs::write(path, pretty).with_context(|| format!("write {}", path.display()))?;
    Ok(format!("{} ← mcpServers.{}", path.display(), spec.name))
}

fn toml_quote(s: &str) -> String {
    format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""))
}

fn codex_block(spec: &RegSpec) -> String {
    let args: Vec<String> = spec.args.iter().map(|a| toml_quote(a)).collect();
    let env: Vec<String> = spec
        .env
        .iter()
        .map(|(k, v)| format!("{k} = {}", toml_quote(v)))
        .collect();
    format!(
        "[mcp_servers.{}]\ncommand = {}\nargs = [{}]\nenv = {{ {} }}\n",
        spec.name,
        toml_quote(&spec.command),
        args.join(", "),
        env.join(", "),
    )
}

fn register_codex_toml(path: &Path, spec: &RegSpec, dry_run: bool) -> Result<String> {
    let header = format!("[mcp_servers.{}]", spec.name);
    let existing = if path.exists() {
        fs::read_to_string(path).unwrap_or_default()
    } else {
        String::new()
    };
    if existing.contains(&header) {
        return Ok(format!(
            "{}: [mcp_servers.{}] уже есть — пропуск (правь вручную)",
            path.display(),
            spec.name
        ));
    }
    if dry_run {
        return Ok(format!(
            "(dry-run) {} ← append [mcp_servers.{}]",
            path.display(),
            spec.name
        ));
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("mkdir {}", parent.display()))?;
    }
    backup_if_exists(path)?;
    let mut out = existing;
    if !out.is_empty() && !out.ends_with('\n') {
        out.push('\n');
    }
    out.push('\n');
    out.push_str(&codex_block(spec));
    fs::write(path, out).with_context(|| format!("write {}", path.display()))?;
    Ok(format!("{} ← [mcp_servers.{}]", path.display(), spec.name))
}

fn register_claude_cli(spec: &RegSpec, dry_run: bool) -> Result<String> {
    if !binary_on_path("claude") {
        bail!("`claude` не найден в PATH (Claude Code не установлен?)");
    }
    let mut args: Vec<String> = vec![
        "mcp".into(),
        "add".into(),
        spec.name.clone(),
        "--scope".into(),
        "user".into(),
    ];
    for (k, v) in &spec.env {
        args.push("-e".into());
        args.push(format!("{k}={v}"));
    }
    args.push("--".into());
    args.push(spec.command.clone());
    args.extend(spec.args.iter().cloned());

    if dry_run {
        return Ok(format!("(dry-run) claude {}", args.join(" ")));
    }
    // снять прежнюю регистрацию (любого scope), потом добавить заново
    let _ = Command::new("claude")
        .args(["mcp", "remove", &spec.name, "--scope", "user"])
        .output();
    let _ = Command::new("claude")
        .args(["mcp", "remove", &spec.name, "--scope", "local"])
        .output();
    let out = Command::new("claude")
        .args(&args)
        .output()
        .context("запуск `claude mcp add`")?;
    if !out.status.success() {
        bail!(
            "claude mcp add: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(format!("claude mcp add {} (user-scope)", spec.name))
}

fn register_host(home: &Path, id: &str, spec: &RegSpec, dry_run: bool) -> Result<String> {
    let def = host_def(id).ok_or_else(|| {
        anyhow!("неизвестный хост '{id}'. Доступны: {}", host_ids().join(", "))
    })?;
    match def.kind {
        HostKind::ClaudeCli => register_claude_cli(spec, dry_run),
        HostKind::JsonMcpServers => {
            let path = host_config_path(home, id)
                .ok_or_else(|| anyhow!("не удалось определить путь конфига {id}"))?;
            register_json_mcp_servers(&path, spec, dry_run)
        }
        HostKind::CodexToml => {
            let path = host_config_path(home, id)
                .ok_or_else(|| anyhow!("не удалось определить путь конфига {id}"))?;
            register_codex_toml(&path, spec, dry_run)
        }
    }
}

// ─────────────────────────── интерактивные хелперы ───────────────────────────

fn ask(interactive: bool, label: &str, default: Option<&str>) -> Result<String> {
    if !interactive {
        return Ok(default.unwrap_or("").to_string());
    }
    eprint!("{label}");
    if let Some(d) = default {
        if !d.is_empty() {
            eprint!(" [{d}]");
        }
    }
    eprint!(": ");
    io::stderr().flush().ok();
    let mut s = String::new();
    io::stdin().read_line(&mut s).context("чтение stdin")?;
    let s = s.trim().to_string();
    Ok(if s.is_empty() {
        default.unwrap_or("").to_string()
    } else {
        s
    })
}

fn resolve_secret(
    flag: Option<String>,
    env_key: &str,
    interactive: bool,
    label: &str,
) -> Result<String> {
    if let Some(v) = flag {
        if !v.is_empty() {
            return Ok(v);
        }
    }
    if let Ok(v) = std::env::var(env_key) {
        if !v.is_empty() {
            return Ok(v);
        }
    }
    if interactive {
        eprint!("{label} (ввод скрыт): ");
        io::stderr().flush().ok();
        let v = rpassword::read_password().context("чтение PIN")?;
        if v.is_empty() {
            bail!("{label}: пусто");
        }
        Ok(v)
    } else {
        bail!("{label}: задай флагом или env {env_key} (режим --non-interactive)");
    }
}

fn resolve_source(flag: Option<InstallSource>, interactive: bool) -> Result<InstallSource> {
    if let Some(s) = flag {
        return Ok(s);
    }
    if !interactive {
        bail!("укажи --source ui|import|none (режим --non-interactive)");
    }
    eprintln!("Источник профиля:");
    eprintln!("  1) ui     — подключиться к стору действующего UI-клиента (нужен PIN UI)");
    eprintln!("  2) import — импортировать зашифрованный export-файл");
    eprintln!("  3) none   — профиль уже подключён, только регистрация в хостах");
    let c = ask(interactive, "Выбор", Some("1"))?;
    Ok(match c.as_str() {
        "2" | "import" => InstallSource::Import,
        "3" | "none" => InstallSource::None,
        _ => InstallSource::Ui,
    })
}

fn resolve_hosts(home: &Path, flag: &[String], interactive: bool) -> Result<Vec<String>> {
    if !flag.is_empty() {
        for h in flag {
            if host_def(h).is_none() {
                bail!("неизвестный хост '{h}'. Доступны: {}", host_ids().join(", "));
            }
        }
        return Ok(flag.to_vec());
    }
    let detected: Vec<String> = HOSTS
        .iter()
        .filter(|d| host_detected(home, d.id))
        .map(|d| d.id.to_string())
        .collect();
    if !interactive {
        if detected.is_empty() {
            bail!(
                "не найдено установленных MCP-хостов; укажи --hosts {}",
                host_ids().join("|")
            );
        }
        return Ok(detected);
    }
    eprintln!("Доступные MCP-хосты (через запятую; Enter — обнаруженные):");
    for d in HOSTS {
        let mark = if detected.iter().any(|x| x == d.id) {
            "✓ обнаружен"
        } else {
            ""
        };
        eprintln!("  {:<15} {} {}", d.id, d.name, mark);
    }
    let def = detected.join(",");
    let ans = ask(
        interactive,
        "Хосты",
        if def.is_empty() { None } else { Some(&def) },
    )?;
    let chosen: Vec<String> = ans
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();
    for h in &chosen {
        if host_def(h).is_none() {
            bail!("неизвестный хост '{h}'");
        }
    }
    if chosen.is_empty() {
        bail!("не выбрано ни одного хоста");
    }
    Ok(chosen)
}

fn resolve_username(
    flag: Option<String>,
    profiles: &[Value],
    interactive: bool,
) -> Result<String> {
    if let Some(u) = flag {
        if !u.is_empty() {
            return Ok(u);
        }
    }
    let ids: Vec<&str> = profiles
        .iter()
        .filter_map(|p| p["server_id"].as_str())
        .collect();
    match ids.len() {
        0 => bail!("в сторе нет профилей — нечего регистрировать (source=none без готового профиля?)"),
        1 => Ok(ids[0].to_string()),
        _ => {
            if !interactive {
                bail!("в сторе несколько профилей — укажи --username <server_id>");
            }
            eprintln!("Профили в сторе:");
            for p in profiles {
                eprintln!(
                    "  {} ({})",
                    p["server_id"].as_str().unwrap_or(""),
                    p["display_name"].as_str().unwrap_or("")
                );
            }
            let u = ask(interactive, "server_id для регистрации", Some(ids[0]))?;
            if u.is_empty() {
                bail!("server_id обязателен");
            }
            Ok(u)
        }
    }
}

fn default_workdir() -> PathBuf {
    dirs::data_dir()
        .map(|d| d.join("paranoia-mcp"))
        .unwrap_or_else(|| PathBuf::from(".paranoia-mcp"))
}

/// Найти каталог AppData UI-клиента (vault.json + profiles/) в ~/.local/share —
/// сам каталог или на один уровень вложенности (<org>/<app>).
fn guess_ui_app_data_root(base: &Path) -> Option<PathBuf> {
    let looks_like = |p: &Path| p.join("vault.json").is_file() && p.join("profiles").is_dir();
    let entries = fs::read_dir(base).ok()?;
    for entry in entries.flatten() {
        let p = entry.path();
        if !p.is_dir() {
            continue;
        }
        if looks_like(&p) {
            return Some(p);
        }
        if let Ok(subs) = fs::read_dir(&p) {
            for sub in subs.flatten() {
                let sp = sub.path();
                if sp.is_dir() && looks_like(&sp) {
                    return Some(sp);
                }
            }
        }
    }
    None
}

fn install_binary(workdir: &Path, dry_run: bool) -> Result<PathBuf> {
    let bindir = workdir.join("bin");
    let dest = bindir.join("paranoia-easy-cli");
    let cur = std::env::current_exe().context("current_exe")?;
    let cur = cur.canonicalize().unwrap_or(cur);
    if dest.canonicalize().ok().as_deref() == Some(cur.as_path()) {
        return Ok(dest); // уже на месте — копировать не нужно
    }
    if dry_run {
        return Ok(dest);
    }
    fs::create_dir_all(&bindir).with_context(|| format!("mkdir {}", bindir.display()))?;
    fs::copy(&cur, &dest)
        .with_context(|| format!("copy {} -> {}", cur.display(), dest.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&dest, fs::Permissions::from_mode(0o755)).ok();
    }
    Ok(dest)
}

// ─────────────────────────────── мастер ──────────────────────────────────────

pub fn run(opts: InstallOpts) -> Result<()> {
    let interactive = io::stdin().is_terminal() && !opts.non_interactive;
    if !opts.json {
        eprintln!("=== Paranoia MCP — установка ===");
    }

    // НАСТОЯЩИЕ home/data-dir — захватываем ДО подмены $HOME на workdir: конфиги
    // хостов (~/.cursor, ~/.codex, …) и автопоиск UI-стора должны смотреть в
    // реальный домашний каталог, а не в workdir.
    let real_home = dirs::home_dir().context("не удалось определить домашний каталог")?;
    let real_data = dirs::data_dir().unwrap_or_else(|| real_home.join(".local").join("share"));

    // 1) workdir
    let default_wd = default_workdir();
    let workdir = match &opts.workdir {
        Some(p) => p.clone(),
        None => PathBuf::from(ask(
            interactive,
            "Рабочий каталог рантайма",
            Some(&default_wd.display().to_string()),
        )?),
    };
    let workdir = if workdir.as_os_str().is_empty() {
        default_wd
    } else {
        workdir
    };
    fs::create_dir_all(&workdir).with_context(|| format!("mkdir {}", workdir.display()))?;
    let workdir = workdir.canonicalize().unwrap_or(workdir);

    // 2) PIN CLI-стора
    let pin = resolve_secret(opts.pin.clone(), "PARANOIA_CLI_PIN", interactive, "PIN CLI-стора")?;

    // 3) перевести процесс в workdir (cwd+HOME) и проставить PIN — весь стор будет
    //    адресоваться оттуда. SAFETY: мастер sync, до любого спавна задач.
    unsafe {
        std::env::set_var("PARANOIA_CLI_PIN", &pin);
        std::env::set_var("HOME", &workdir);
    }
    std::env::set_current_dir(&workdir).with_context(|| format!("chdir {}", workdir.display()))?;

    // 4) бинарь → workdir/bin (стабильный путь для регистрации)
    let bin_path = install_binary(&workdir, opts.dry_run)?;

    // 5) провижининг профиля
    let source = resolve_source(opts.source, interactive)?;
    let mut prov_kind = "none";
    let mut prov_stats: Value = Value::Null;
    let mut ui_creds: Option<(PathBuf, String)> = None;

    match source {
        InstallSource::Ui => {
            prov_kind = "ui";
            let root = match opts.ui_app_data_root.clone() {
                Some(p) => p,
                None => {
                    let guess = guess_ui_app_data_root(&real_data);
                    let guess_s = guess.as_ref().map(|p| p.display().to_string());
                    let ans = ask(interactive, "Каталог AppData UI-клиента", guess_s.as_deref())?;
                    if ans.is_empty() {
                        bail!("нужен каталог AppData UI-клиента (--ui-app-data-root)");
                    }
                    PathBuf::from(ans)
                }
            };
            let ui_pin = resolve_secret(
                opts.ui_pin.clone(),
                "PARANOIA_UI_PIN",
                interactive,
                "PIN vault UI-клиента",
            )?;
            prov_stats = crate::sync_from_ui_core(
                &opts.server_url,
                &root,
                &ui_pin,
                opts.username.as_deref(),
            )?;
            ui_creds = Some((root, ui_pin));
        }
        InstallSource::Import => {
            prov_kind = "import";
            let pk = crate::device_pubkey_b64()?;
            if !opts.json {
                eprintln!("device-pubkey (передай хозяину для зашифрованного export):");
                eprintln!("  {pk}");
            }
            let file = match opts.export_file.clone() {
                Some(f) => Some(f),
                None => {
                    if interactive {
                        let ans = ask(
                            interactive,
                            "Путь к export-файлу (Enter — получить файл позже)",
                            None,
                        )?;
                        if ans.is_empty() { None } else { Some(PathBuf::from(ans)) }
                    } else {
                        bail!("--export-file обязателен (source=import). device-pubkey: {pk}");
                    }
                }
            };
            match file {
                Some(f) => {
                    prov_stats = crate::import_core(&opts.server_url, &f)?;
                }
                None => {
                    // ещё нет export-файла — выходим, показав device-pubkey.
                    if opts.json {
                        println!(
                            "{}",
                            serde_json::to_string_pretty(&json!({
                                "ok": true,
                                "stage": "awaiting_export",
                                "device_pubkey": pk,
                                "next": "получи export под этот pubkey и запусти снова с --export-file"
                            }))
                            .unwrap_or_default()
                        );
                    } else {
                        eprintln!(
                            "\nОстановка: получи export-файл под device-pubkey выше и запусти снова:"
                        );
                        eprintln!("  paranoia-easy-cli … mcp install --source import --export-file <файл>");
                    }
                    return Ok(());
                }
            }
        }
        InstallSource::None => {}
    }

    // 6) server_id (= --username) для регистрации
    let profiles = crate::collect_server_id_profiles().unwrap_or_default();
    let server_id = resolve_username(opts.username.clone(), &profiles, interactive)?;
    let peer = opts.peer.clone().unwrap_or_default();

    // 7) хосты
    let hosts = resolve_hosts(&real_home, &opts.hosts, interactive)?;

    // 8) спецификация регистрации
    let mut env: Vec<(String, String)> = vec![
        ("PARANOIA_MCP_WORKDIR".into(), workdir.display().to_string()),
        ("PARANOIA_CLI_PIN".into(), pin.clone()),
        ("PARANOIA_MCP_USERNAME".into(), server_id.clone()),
        ("PARANOIA_MCP_SELF_HASH".into(), server_id.clone()),
        (
            "PARANOIA_MCP_LOG".into(),
            workdir.join("messages.jsonl").display().to_string(),
        ),
    ];
    if !peer.is_empty() {
        env.push(("PARANOIA_MCP_PEER".into(), peer.clone()));
    }
    // Источник=ui: пробросим креды UI, чтобы тулза provision_from_ui работала из
    // хоста и позже (повторная синхронизация ключей).
    if let Some((root, ui_pin)) = &ui_creds {
        env.push((
            "PARANOIA_UI_APP_DATA_ROOT".into(),
            root.display().to_string(),
        ));
        env.push(("PARANOIA_UI_PIN".into(), ui_pin.clone()));
    }
    let spec = RegSpec {
        name: "paranoia-cli".into(),
        command: bin_path.display().to_string(),
        args: vec![
            "--server-url".into(),
            opts.server_url.clone(),
            "--db-path".into(),
            "paranoia.db".into(),
            "mcp".into(),
        ],
        env,
    };

    // 9) регистрация
    let mut results: Vec<(String, bool, String)> = Vec::new();
    for h in &hosts {
        match register_host(&real_home, h, &spec, opts.dry_run) {
            Ok(desc) => results.push((h.clone(), true, desc)),
            Err(e) => results.push((h.clone(), false, e.to_string())),
        }
    }

    // 10) отчёт
    let all_ok = results.iter().all(|(_, ok, _)| *ok);
    if opts.json {
        let hosts_json: Vec<Value> = results
            .iter()
            .map(|(id, ok, detail)| json!({"host": id, "ok": ok, "detail": detail}))
            .collect();
        let out = json!({
            "ok": all_ok,
            "dry_run": opts.dry_run,
            "workdir": workdir.display().to_string(),
            "binary": spec.command,
            "server_id": server_id,
            "peer": peer,
            "source": prov_kind,
            "provision": prov_stats,
            "hosts": hosts_json,
        });
        println!("{}", serde_json::to_string_pretty(&out).unwrap_or_default());
    } else {
        eprintln!();
        eprintln!("Готово{}.", if opts.dry_run { " (dry-run)" } else { "" });
        eprintln!("  workdir:   {}", workdir.display());
        eprintln!("  бинарь:    {}", spec.command);
        eprintln!("  server_id: {server_id}");
        eprintln!("  источник:  {prov_kind}");
        eprintln!("Хосты:");
        for (id, ok, detail) in &results {
            eprintln!("  [{}] {:<14} {}", if *ok { "OK" } else { "FAIL" }, id, detail);
        }
        eprintln!("\nПерезапусти MCP-хост(ы), чтобы подхватить сервер 'paranoia-cli'.");
    }

    if !all_ok {
        bail!("часть хостов не зарегистрирована (см. отчёт)");
    }
    Ok(())
}
