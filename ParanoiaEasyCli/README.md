# ParanoiaEasyCli (`paranoia-easy-cli`)

Один Rust-бинарь, который сразу:

- **консольный клиент** Paranoia — отправка/приём сообщений и файлов из терминала;
- **MCP-сервер** для агентов (Claude Code, Cursor, Codex и др.) — подкоманда `mcp`;
- **установщик** — мастер `mcp install` (регистрация в MCP-хостах + провижининг профиля).

Зависит от `../ParanoiaLibrary` (крейт `paranoia-lib`). Версия монорепо единая
(`scripts/set_version.sh`).

```bash
cargo build --release            # → target/release/paranoia-easy-cli
```

---

## Быстрый старт

```bash
# 1) собрать (или скачать релизный бинарь)
cargo build --release
# 2) установить как MCP-сервер + подключить профиль (интерактивный мастер)
./target/release/paranoia-easy-cli mcp install
```

Мастер спросит рабочий каталог, PIN, источник профиля (подключение к стору
UI-клиента / импорт export-файла) и хосты для регистрации. Подробности по MCP —
в [`tools/README.md`](tools/README.md).

---

## Общие флаги

| Флаг | Назначение |
|------|------------|
| `--server-url <URL>` | адрес сервера Paranoia (по умолч. `https://paranoia.example.com/api`) |
| `--reserve-server-url <URL>` | резервный адрес (можно несколько раз) |
| `--db-path <PATH>` | путь SQLCipher-БД сообщений (по умолч. `paranoia.db`) |

PIN берётся из env `PARANOIA_CLI_PIN` (иначе спрашивается). Рантайм адресуется
относительно cwd/HOME — см. [Рантайм](#рантайм).

---

## Команды

### Связь / сообщения
| Команда | Что делает |
|---------|-----------|
| `send --username <sid> --peer <имя\|sid> --text <…>` | отправить текстовое сообщение |
| `receive --username <sid> --peer <…> [--long-poll-ms N]` | забрать новые сообщения (двигает курсор) |
| `watch --username <sid> --peer <…> [--interval N] [--long-poll-ms N]` | непрерывный приём (long-poll или поллинг) |
| `send-file --username <sid> --peer <…> --path <файл>` | отправить файл/картинку (канал авто по размеру) |
| `download --username <sid> --peer <…> --message-id <id> --out <файл>` | скачать вложение |
| `clear --username <sid> --peer <…> --cut-seq <N>` | очистить историю на сервере |

`--peer` принимает отображаемое имя (резолвится в server_id через `names`) или сам
server_id. `--username` — **всегда server_id** (см. ниже).

### Профиль / подключение
| Команда | Что делает |
|---------|-----------|
| `mcp install [--source ui\|import\|none] [--hosts …] [--non-interactive] [--json]` | мастер установки (см. [`tools/README.md`](tools/README.md)) |
| `sync-from-ui --app-data-root <UI AppData> [--profile <…>] [--pin <…>]` | подтянуть профиль НАПРЯМУЮ из стора UI-клиента (vault), без export/import |
| `import --file <export>` | импортировать зашифрованный export-файл (lossless: peer_server_id + имена) |
| `export --profile <client\|full> --username <sid> --peer <…> --receiver-pub <b64> --out <файл>` | создать зашифрованный export под device-pubkey получателя |
| `server-id [--signing-key-b64 <b64>] [--json]` | показать server_id профилей (= `--username`) или вычислить из ключа |
| `device-key show` | показать device-pubkey (для обмена под export/import) |

**server_id** = `hex(SHA256("paranoia:server-id:v1\n" ‖ ed25519_pubkey))` — это
идентичность, под которой профиль зарегистрирован на сервере, и именно она уходит
как отправитель. Узнать свою: `server-id`.

### Ключи диалогов (низкоуровнево)
| Команда | Что делает |
|---------|-----------|
| `dialogue init --peer <sid> --session-key-hex <hex>` | задать session-key диалога явно |
| `dialogue set-key --peer <sid>` | задать session-key из stdin |

### Администрирование / инициализация
| Команда | Что делает |
|---------|-----------|
| `user init` | сгенерировать пользовательские ключи (→ USER_PUB для регистрации админом) |
| `admin init` | сгенерировать админские ключи (ADMIN_PUB → в конфиг сервера) |
| `admin reg-user --username <sid>` | зарегистрировать пользователя на сервере (подпись админа → `/reg`) |

### Звонки (отладочное)
`call-offer` / `call-hangup` — послать тестовый Offer / Hangup peer'у (отладка
приёма входящих звонков в фоне).

---

## MCP-сервер

`paranoia-easy-cli … mcp` поднимает встроенный MCP-сервер поверх stdio
(JSON-RPC 2.0). Тулзы: `wait` (long-poll), `receive`, `send`, `send_file`,
`download`, `whoami`, `provision_from_ui`, `history`. Конфигурация — через env
`PARANOIA_MCP_*` (см. [`tools/README.md`](tools/README.md)). Регистрация в хостах —
мастером `mcp install` (Claude Code/Desktop, Cursor, Windsurf, Cline, Codex) или
вручную (generic-сниппет в `tools/README.md`).

---

## Рантайм

Состояние хранится относительно cwd (vault `./.paranoia-cli-data/`, `./DEVICE_KEY`,
`./paranoia.db`) и HOME (`~/.paranoia_dialogues.json` — стор профилей/диалогов).
Поэтому процесс должен работать с нужными cwd+HOME. Мастер `mcp install` сводит всё
в **рабочий каталог** (по умолч. `~/.local/share/paranoia-mcp/`) и регистрирует
сервер с env `PARANOIA_MCP_WORKDIR`, заставляя процесс перейти туда (cwd+HOME).

| Файл/каталог в рабочем каталоге | Что это |
|---|---|
| `bin/paranoia-easy-cli` | бинарь |
| `.paranoia-cli-data/` | local-vault (Argon2id→HKDF→ChaCha20) |
| `DEVICE_KEY` | ключ устройства для ECIES export/import |
| `paranoia.db` | SQLCipher-БД сообщений |
| `.paranoia_dialogues.json` | стор: профили + ключи диалогов + имена |
| `messages.jsonl` | durable-лог входящих (MCP) |

---

## Сборка и релиз

Не cargo-workspace — собирать по `--manifest-path`. CI: джоба
`build:easy-cli:linux` (`.gitlab-ci.yml`, образ `ci-linux-rust`) кладёт бинарь в
`release/paranoia-easy-cli-amd64`; release-джобы заливают его на тегах.

```bash
cargo build --release --manifest-path ParanoiaEasyCli/Cargo.toml
```
