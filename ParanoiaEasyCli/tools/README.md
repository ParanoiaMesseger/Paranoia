# Paranoia CLI — консольный клиент + встроенный MCP-сервер

`paranoia-easy-cli` — Rust-бинарь для асинхронной переписки в мессенджере
Paranoia из терминала и из агентов (Claude Code, Cursor, Codex и др.). MCP-сервер
**встроен в бинарь** (подкоманда `mcp`): говорит MCP поверх stdio (newline-delimited
JSON-RPC 2.0) и зовёт внутренние функции напрямую — без подпроцессов и парсинга
текста. Установка тоже встроена — подкоманда `mcp install` (отдельного
shell-скрипта больше нет).

Всё, что нужно конечному пользователю — **один бинарь**. Эта папка содержит только
`README.md`; исходники сервера/мастера — в `../src/{mcp_server,mcp_install,ui_store}.rs`
и `../src/main.rs`.

---

## Установка — мастер `mcp install`

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

---

## Провижининг вручную (без мастера)

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

## MCP-инструменты

`peer`/`username` опциональны — берутся из env. Тулзы: **`wait`** (long-poll,
главный способ ждать ответ), **`receive`**, **`send`** (Markdown), **`send_file`**,
**`download`**, **`whoami`** (свой server_id + собеседники), **`provision_from_ui`**
(подключение из UI-стора без export/import), **`history`** (durable-лог без
движения курсора). Подробные схемы аргументов — в `tools/list` сервера и в
`../src/mcp_server.rs`.

---

## Конфигурация (env)

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

---

## Надёжность

- **Конкурентность.** `tools/call` исполняется в отдельной локальной задаче
  (`LocalSet`/`spawn_local`); цикл чтения stdin продолжает отвечать на
  `ping`/`tools/list` — долгий `wait` не вешает сервер.
- **Durable-лог.** Каждое вытянутое сообщение дописывается (append+fsync, дедуп по
  `id`) в `PARANOIA_MCP_LOG` ДО возврата клиенту — восстановимо через `history`.
- **Vault-safety.** `provision_from_ui` временно переключает vault на UI-стор; это
  сериализовано (RwLock) и CLI-vault восстанавливается в любом случае.

---

## Диагностика

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

---

## Сборка / релиз

CI собирает CLI job'ом `build:easy-cli:linux` (`.gitlab-ci.yml`, образ
`ci-linux-rust`) → `release/paranoia-easy-cli-amd64`; обе release-джобы заливают
его глобом `release/*` на тегах. Версия — через `scripts/set_version.sh`.
Конечному пользователю достаточно скачать бинарь и выполнить `mcp install`.
