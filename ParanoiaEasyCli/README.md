# ParanoiaEasyCli (`paranoia-easy-cli`)

Один Rust-бинарь, который сразу:

- **консольный клиент** Paranoia — отправка/приём сообщений и файлов из терминала;
- **MCP-сервер** для агентов (Claude Code, Cursor, Codex и др.) — подкоманда `mcp`;
- **установщик** — мастер `mcp install` (регистрация в MCP-хостах + провижининг профиля).

MCP-сервер **встроен в бинарь**: говорит MCP поверх stdio (newline-delimited
JSON-RPC 2.0) и зовёт внутренние функции напрямую — без подпроцессов и парсинга
текста. Установка тоже встроена (`mcp install`) — отдельного shell-скрипта нет.
Всё, что нужно конечному пользователю — **один бинарь**.

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
UI-клиента / импорт export-файла) и хосты для регистрации. Подробности —
в разделе [Установка](#установка-мастер-mcp-install).

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
| `react --username <sid> --peer <…> --message-id <id> --emoji <эмодзи>` | поставить эмодзи-реакцию на сообщение (например прогресс-статус 👀/🤔/✍️/✔️) |
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
| `mcp install [--source ui\|import\|none] [--hosts …] [--non-interactive] [--json]` | мастер установки (см. [Установка](#установка-мастер-mcp-install)) |
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

## Установка (мастер `mcp install`)

```bash
paranoia-easy-cli mcp install
```

Мастер копирует бинарь в рабочий каталог, **провижинит профиль** и **регистрирует**
MCP-сервер `paranoia-cli` в выбранных хостах. Работает в двух режимах:

**Человек (интерактивно).** Запусти без флагов — мастер сам спросит рабочий
каталог, PIN (скрытый ввод), источник профиля и хосты:

```
$ paranoia-easy-cli mcp install
Рабочий каталог рантайма [~/.local/share/paranoia-mcp]:
PIN CLI-стора (ввод скрыт):
Источник профиля:
  1) ui     — подключиться к стору действующего UI-клиента (нужен PIN UI)
  2) import — импортировать зашифрованный export-файл
  3) none   — профиль уже подключён, только регистрация
Выбор [1]:
Доступные MCP-хосты (через запятую; Enter — обнаруженные):
  claude-code     Claude Code (CLI)        ✓ обнаружен
  cursor          Cursor                   ✓ обнаружен
  …
```

**Агент / скрипт (неинтерактивно).** Всё задаётся флагами + `--non-interactive`
(+ `--json` для разбора результата на stdout). Если человек скачал бинарь и просто
просит агента настроить — агент вызывает мастер так:

```bash
paranoia-easy-cli --server-url https://<server> mcp install \
  --non-interactive --json \
  --source ui --ui-app-data-root ~/.local/share/<UI-AppData> --ui-pin <PIN-UI> \
  --pin <PIN-CLI> \
  --hosts claude-code,cursor,codex
```

Недостающее обязательное значение в `--non-interactive` → понятная ошибка (агент
поймёт, что спросить у человека). `--dry-run` показывает план без записи.

### Источник профиля

| Источник | Что делает | Нужно |
|----------|------------|-------|
| **`ui`** ⭐ | подтянуть профиль НАПРЯМУЮ из стора действующего UI-клиента (vault) | каталог AppData UI + PIN UI |
| **`import`** | импортировать зашифрованный export-файл | device-pubkey ↔ export от хозяина |
| **`none`** | профиль уже в сторе — только регистрация в хостах | — |

`ui` — самый turnkey: один проход, без export/import. Мастер пытается
**автоопределить** каталог UI-стора в `~/.local/share` (по наличию `vault.json` +
`profiles/`). Для `import` мастер покажет device-pubkey (передать хозяину) и
импортирует файл, когда укажешь `--export-file`.

### Поддерживаемые хосты

`claude-code` (через `claude mcp add`), `claude-desktop`, `cursor`, `windsurf`,
`cline`, `codex`. Без `--hosts` мастер **автоопределяет** установленные (по наличию
их конфигов) и в интерактиве предлагает выбрать. Запись:

- JSON `{"mcpServers": {…}}` — Claude Desktop / Cursor / Windsurf / Cline:
  **мёрж** в существующий файл (чужие серверы сохраняются), с бэкапом `*.paranoia.bak`.
- TOML `~/.codex/config.toml` — Codex: добавляет `[mcp_servers.paranoia-cli]`,
  если секции ещё нет (иначе не трогает).
- Claude Code — `claude mcp add … --scope user` (если `claude` в PATH).

После установки **перезапусти хост(ы)**, чтобы они подхватили сервер `paranoia-cli`.

> `mcp install` сам переходит в `workdir` (cwd+HOME), поэтому весь рантайм
> (`.paranoia-cli-data/`, `DEVICE_KEY`, `paranoia.db`, `.paranoia_dialogues.json`)
> и durable-лог лежат в нём. Пути конфигов хостов при этом адресуются в НАСТОЯЩИЙ
> `~`. По умолчанию `workdir` = `~/.local/share/paranoia-mcp`.

### Другие MCP-хосты

Сервер реализует стандартный MCP-over-stdio, поэтому совместим с любым MCP-хостом.
Если хоста нет в списке мастера — пропиши вручную ту же команду и env (см.
[Конфигурация](#конфигурация-env)) в конфиг своего хоста, например:

```jsonc
{ "command": "<workdir>/bin/paranoia-easy-cli",
  "args": ["--server-url", "https://<server>", "--db-path", "paranoia.db", "mcp"],
  "env": { "PARANOIA_MCP_WORKDIR": "<workdir>", "PARANOIA_CLI_PIN": "<pin>",
           "PARANOIA_MCP_USERNAME": "<server_id>", "PARANOIA_MCP_PEER": "<peer>" } }
```

Транспорт — только **stdio**; для HTTP/SSE-only хоста нужен отдельный адаптер.

### Провижининг вручную (без мастера)

server_id — идентичность для сервера (= `--username`), детерминированно из signing
key: `server_id = hex(SHA256("paranoia:server-id:v1\n" ‖ ed25519_pubkey))`.

```bash
# напрямую из стора UI (без export/import):
paranoia-easy-cli sync-from-ui --app-data-root ~/.local/share/<UI-AppData> [--profile <имя|server_id>]
# импорт зашифрованного export-файла (lossless: peer_server_id + names):
paranoia-easy-cli import --file <export-файл>
# узнать свой server_id (= --username):
paranoia-easy-cli server-id [--json] [--signing-key-b64 <b64>]
```

---

## MCP-сервер

`paranoia-easy-cli … mcp` поднимает встроенный MCP-сервер поверх stdio
(JSON-RPC 2.0). `peer`/`username` в тулзах опциональны — берутся из env. Инструменты:

- **`wait`** — long-poll, главный способ ждать ответ;
- **`receive`** — забрать новые сообщения (двигает курсор);
- **`send`** — отправить (Markdown);
- **`react`** — поставить эмодзи-реакцию на сообщение (`message_id` + `emoji`);
- **`send_file`** / **`download`** — файлы/вложения;
- **`whoami`** — свой server_id + собеседники;
- **`provision_from_ui`** — подключение из UI-стора без export/import;
- **`history`** — durable-лог без движения курсора.

Подробные схемы аргументов — в `tools/list` сервера и в `src/mcp_server.rs`.
Конфигурация — через env `PARANOIA_MCP_*` (см. [Конфигурация](#конфигурация-env)).
Регистрация в хостах — мастером `mcp install` (Claude Code/Desktop, Cursor,
Windsurf, Cline, Codex) или вручную (см. [Другие MCP-хосты](#другие-mcp-хосты)).

### Конфигурация (env)

Подкоманда `mcp` берёт `server_url`/`db_path` из общих флагов CLI; остальное — env
(их проставляет мастер при регистрации):

| Переменная | Назначение |
|------------|------------|
| `PARANOIA_MCP_WORKDIR` | рабочий каталог: процесс делает `chdir`+`HOME` (весь стор там) |
| `PARANOIA_CLI_PIN` | PIN CLI-стора (signing key / db_key) |
| `PARANOIA_MCP_USERNAME` | server_id профиля по умолчанию (= `--username`) |
| `PARANOIA_MCP_PEER` | peer по умолчанию |
| `PARANOIA_MCP_SELF_HASH` | sender-хеш своих сообщений (метка `from:"me"`); по умолч. = USERNAME |
| `PARANOIA_MCP_LOG` | durable-лог входящих (по умолч. `<workdir>/messages.jsonl`) |
| `PARANOIA_UI_APP_DATA_ROOT` | (опц.) каталог UI-стора для `provision_from_ui` |
| `PARANOIA_UI_PIN` | (опц.) PIN vault UI; иначе fallback на `PARANOIA_CLI_PIN` |
| `PARANOIA_MCP_CHANNEL` | `1`/`true` → **режим канала** (push): объявить `claude/channel` и инжектить входящие как ходы агента (см. [Режим канала](#режим-канала-push--как-в-telegram)) |

### Надёжность

- **Конкурентность.** `tools/call` исполняется в отдельной локальной задаче
  (`LocalSet`/`spawn_local`); цикл чтения stdin продолжает отвечать на
  `ping`/`tools/list` — долгий `wait` не вешает сервер.
- **Durable-лог.** Каждое вытянутое сообщение дописывается (append+fsync, дедуп по
  `id`) в `PARANOIA_MCP_LOG` ДО возврата клиенту — восстановимо через `history`.
- **Vault-safety.** `provision_from_ui` временно переключает vault на UI-стор; это
  сериализовано (RwLock) и CLI-vault восстанавливается в любом случае.

### Диагностика

```bash
claude mcp get paranoia-cli          # регистрация и env (для Claude Code)
paranoia-easy-cli server-id --json   # свой профиль/server_id
# ручной дымовой тест MCP-сервера:
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | env PARANOIA_MCP_WORKDIR=~/.local/share/paranoia-mcp PARANOIA_CLI_PIN=<pin> \
    ~/.local/share/paranoia-mcp/bin/paranoia-easy-cli --server-url <url> mcp
```

### Режим канала (push) — как в Telegram

По умолчанию MCP — **pull**: агент сам зовёт `wait`/`receive` (блокирующее
ожидание, тратит токены/ход). С env **`PARANOIA_MCP_CHANNEL=1`** тот же бинарь
работает как **channel-плагин Claude Code** (research-preview): объявляет
capability `claude/channel`, а фоновый push-луп инжектит каждое входящее от
собеседника как ход агента (`<channel source="paranoia-cli" chat_id … message_id …
user … ts …>`). Агент **просыпается на событие, не поллит и не тратит токены в
простое**. При приёме сервер сам ставит ack-реакцию **👀** («получил»); статус
обработки агент дальше двигает тулзой `react` (схема **👀 получил → 🤔 думаю →
✍️ отвечаю → ✔️ ответил**; реакции накапливаются). Отвечает агент тулзой `send`.

**Как включить:**

1. Мастером — режим канала **создаёт плагин-каталог, убирает pull-MCP и печатает
   команду запуска** (всё за один шаг):
   ```bash
   paranoia-easy-cli mcp install --channel
   # агент/скрипт: + --source none --non-interactive --username <sid> --pin <pin> [--json]
   ```
   Создаётся `<workdir>/channel-plugin/` (`.claude-plugin/plugin.json` + `.mcp.json`
   с командой/env, включая `PARANOIA_MCP_CHANNEL=1`; server-ключ `paranoia`), и
   best-effort удаляется pull-MCP `paranoia-cli` (иначе ДВА читателя — pull-тулзы и
   push-луп — дренажат сообщения друг у друга).
2. Запусти сессию Claude Code с dev-флагом канала (кастомные каналы вне allowlist в
   research-preview, нужен Claude Code v2.1.80+) из каталога плагина:
   ```bash
   cd <workdir>/channel-plugin
   claude --dangerously-load-development-channels server:paranoia
   ```

Вернуть pull-режим: `paranoia-easy-cli mcp install` (без `--channel`).

Проверка сервера-канала вручную (handshake): отправь `initialize` бинарю с
`PARANOIA_MCP_CHANNEL=1` — в ответе `capabilities.experimental["claude/channel"]`
и поле `instructions`, в stderr `channel push loop started`.

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
`release/paranoia-easy-cli-amd64`; release-джобы заливают его глобом `release/*`
на тегах. Версия — через `scripts/set_version.sh`. Конечному пользователю
достаточно скачать бинарь и выполнить `mcp install`.

```bash
cargo build --release --manifest-path ParanoiaEasyCli/Cargo.toml
```
