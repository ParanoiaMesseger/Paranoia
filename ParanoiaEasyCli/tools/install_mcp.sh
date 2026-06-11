#!/usr/bin/env bash
#
# install_mcp.sh — установка Paranoia MCP-сервера в ПОСТОЯННУЮ папку вне репо.
#
# Зачем: рантайм CLI (paranoia.db, DEVICE_KEY, .paranoia-cli-data/ vault,
# ~/.paranoia_dialogues.json) — это untracked-файлы. Если их удалить, теряется
# device key + PIN-vault → нельзя расшифровать signing key → нельзя писать.
# Скрипт переносит всё это в DATADIR и регистрирует MCP в user-scope Claude Code,
# чтобы чистка untracked-файлов репо ничего не сломала.
#
# Идемпотентно: повторный запуск пересобирает бинарь, обновляет скрипт и НЕ
# перетирает уже перенесённое состояние.
#
# Переопределяемо через env (значения по умолчанию — dev-профиль Клода):
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"            # …/ParanoiaEasyCli
DATADIR="${PARANOIA_MCP_HOME:-$HOME/.local/share/paranoia-mcp}"
BINDIR="$DATADIR/bin"

SERVER_URL="${PARANOIA_MCP_SERVER:-https://paranoia.example.com}"
PIN="${PARANOIA_MCP_PIN:-paranoia-cli-dev}"
USERNAME="${PARANOIA_MCP_USERNAME:-95d76f326d0001cff161a0b929b23a7fca02cbd9f0041370eb2d0d9d8e9ade70}"
PEER="${PARANOIA_MCP_PEER:-Иванов Иван Иванович}"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

say "DATADIR = $DATADIR"
mkdir -p "$BINDIR"

# 1) Собрать бинарь (target/ untracked → пересобираем) и положить в DATADIR/bin.
say "Сборка paranoia-easy-cli (release)…"
( cd "$REPO" && cargo build --release )
install -m 0755 "$REPO/target/release/paranoia-easy-cli" "$BINDIR/paranoia-easy-cli"
say "бинарь → $BINDIR/paranoia-easy-cli"

# 2) MCP-сервер (python, без зависимостей).
install -m 0644 "$REPO/tools/paranoia_mcp.py" "$DATADIR/paranoia_mcp.py"
say "сервер → $DATADIR/paranoia_mcp.py"

# 3) Перенести состояние в DATADIR (move, единственная копия). Существующее в
#    DATADIR не трогаем (идемпотентность / не затереть свежее).
move_in() {  # src dst
  local src="$1" dst="$2"
  [ -e "$src" ] || return 0
  if [ -e "$dst" ]; then
    say "  оставляю $dst (в DATADIR уже есть); src $src не трогаю"
  else
    mkdir -p "$(dirname "$dst")"
    mv "$src" "$dst"
    say "  перенёс $src → $dst"
  fi
}
say "Перенос рантайм-состояния…"
move_in "$REPO/paranoia.db"               "$DATADIR/paranoia.db"
move_in "$REPO/DEVICE_KEY"                "$DATADIR/DEVICE_KEY"
move_in "$REPO/.paranoia-cli-data"        "$DATADIR/.paranoia-cli-data"
move_in "$HOME/.paranoia_dialogues.json"  "$DATADIR/.paranoia_dialogues.json"

# 4) Регистрация MCP в user-scope (хранится в ~/.claude.json, переживает чистку
#    репо). WORKDIR=DATADIR → CLI видит cwd- и home-relative состояние из DATADIR.
say "Регистрация MCP-сервера 'paranoia-cli' (user-scope)…"
claude mcp remove paranoia-cli --scope user  >/dev/null 2>&1 || true
claude mcp remove paranoia-cli --scope local >/dev/null 2>&1 || true
claude mcp add paranoia-cli --scope user \
  -e PARANOIA_MCP_BIN="$BINDIR/paranoia-easy-cli" \
  -e PARANOIA_MCP_SERVER="$SERVER_URL" \
  -e PARANOIA_MCP_PIN="$PIN" \
  -e PARANOIA_MCP_WORKDIR="$DATADIR" \
  -e PARANOIA_MCP_DB="paranoia.db" \
  -e PARANOIA_MCP_USERNAME="$USERNAME" \
  -e PARANOIA_MCP_PEER="$PEER" \
  -e PARANOIA_MCP_SELF_HASH="$USERNAME" \
  -- python3 "$DATADIR/paranoia_mcp.py"

# 5) Убрать project-scope .mcp.json (untracked, указывает в репо — станет битым
#    после чистки; user-scope его заменил).
if [ -f "$REPO/.mcp.json" ]; then
  rm -f "$REPO/.mcp.json"
  say "удалён project-scope $REPO/.mcp.json (заменён user-scope)"
fi

# 6) Дымовой тест: initialize + list_peers через установленный сервер.
say "Дымовой тест…"
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_peers","arguments":{}}}' \
| env PARANOIA_MCP_BIN="$BINDIR/paranoia-easy-cli" \
      PARANOIA_MCP_SERVER="$SERVER_URL" \
      PARANOIA_MCP_PIN="$PIN" \
      PARANOIA_MCP_WORKDIR="$DATADIR" \
      PARANOIA_MCP_DB="paranoia.db" \
      PARANOIA_MCP_USERNAME="$USERNAME" \
      PARANOIA_MCP_SELF_HASH="$USERNAME" \
      python3 "$DATADIR/paranoia_mcp.py" 2>/dev/null \
| grep -q '"id": 2' && say "сервер отвечает ✔" || { echo "дымовой тест НЕ прошёл" >&2; exit 1; }

cat <<EOF

Готово. MCP-сервер установлен в: $DATADIR
  бинарь:   $BINDIR/paranoia-easy-cli
  сервер:   $DATADIR/paranoia_mcp.py
  состояние: paranoia.db, DEVICE_KEY, .paranoia-cli-data/, .paranoia_dialogues.json

Дальше:
  • Перезапусти сессию Claude Code → подтверди сервер 'paranoia-cli'.
  • Проверка:  claude mcp list
  • Untracked-файлы в репо ($REPO) теперь можно чистить — рантайм в DATADIR.
EOF
