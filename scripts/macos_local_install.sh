#!/usr/bin/env bash
# Локальная установка клиента Paranoia на macOS БЕЗ предупреждений Gatekeeper.
#
# Зачем: .dmg/.app подписаны только ad-hoc (без Developer ID/нотаризации — нет
# платного Apple-аккаунта). На СКАЧАННОЙ копии macOS вешает карантин
# (com.apple.quarantine) и Gatekeeper ругается «Apple не удалось подтвердить…».
# Для ЛОКАЛЬНОЙ отладки это лишнее: снимаем карантин и переподписываем ad-hoc —
# приложение запускается без диалогов. Аккаунт разработчика для этого НЕ нужен.
# (Для раздачи другим без предупреждений нужна нотаризация — см.
# package_macos_dmg.sh, блок MACOS_SIGN_IDENTITY.)
#
# Использование:
#   scripts/macos_local_install.sh --app  <path/to/Paranoia.app>   [--launch]
#   scripts/macos_local_install.sh --dmg  <path/to/Paranoia-*.dmg> [--launch]
# Без --app/--dmg ищет свежий артефакт в build_client/.
set -euo pipefail

APP=""; DMG=""; LAUNCH=0
DEST="/Applications/Paranoia.app"

while [ $# -gt 0 ]; do
  case "$1" in
    --app)    APP="$2"; shift 2;;
    --dmg)    DMG="$2"; shift 2;;
    --launch) LAUNCH=1; shift;;
    *) echo "macos_local_install: unknown arg '$1'" >&2; exit 2;;
  esac
done

case "$(uname -s)" in Darwin) ;; *) echo "macos_local_install: только для macOS" >&2; exit 1;; esac

# Автопоиск артефакта, если ничего не указано.
if [ -z "$APP" ] && [ -z "$DMG" ]; then
  APP="$(find build_client -maxdepth 4 -name 'Paranoia.app' -type d 2>/dev/null | head -1 || true)"
  if [ -z "$APP" ]; then
    DMG="$(find build_client -maxdepth 1 -name 'Paranoia-*.dmg' -type f 2>/dev/null | head -1 || true)"
  fi
  [ -n "$APP$DMG" ] || { echo "macos_local_install: не найден .app/.dmg в build_client — укажи --app/--dmg" >&2; exit 1; }
fi

# Если дали .dmg — монтируем и достаём .app во временную папку.
MNT=""; TMP_APP=""
cleanup() { [ -n "$MNT" ] && hdiutil detach "$MNT" -quiet 2>/dev/null || true; [ -n "$TMP_APP" ] && rm -rf "$TMP_APP" 2>/dev/null || true; }
trap cleanup EXIT

if [ -n "$DMG" ]; then
  test -f "$DMG" || { echo "macos_local_install: .dmg не найден: $DMG" >&2; exit 1; }
  MNT="$(mktemp -d /tmp/paranoia-dmg-mnt.XXXXXX)"
  echo "macos_local_install: монтирую $DMG"
  hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MNT" >/dev/null
  SRC_APP="$(find "$MNT" -maxdepth 1 -name '*.app' -type d | head -1)"
  test -n "$SRC_APP" || { echo "macos_local_install: в .dmg нет .app" >&2; exit 1; }
  TMP_APP="$(mktemp -d /tmp/paranoia-app.XXXXXX)/Paranoia.app"
  mkdir -p "$(dirname "$TMP_APP")"
  cp -R "$SRC_APP" "$TMP_APP"
  APP="$TMP_APP"
fi

test -d "$APP" || { echo "macos_local_install: .app не найден: $APP" >&2; exit 1; }

echo "macos_local_install: устанавливаю $APP -> $DEST"
rm -rf "$DEST"
# cp -R сохраняет содержимое; источник из карантинного .dmg мог нести атрибут —
# снимем его ниже уже на установленной копии.
cp -R "$APP" "$DEST"

echo "macos_local_install: снимаю карантин и переподписываю ad-hoc"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
codesign --force --deep --sign - --timestamp=none "$DEST" >/dev/null 2>&1 || \
  echo "macos_local_install: предупреждение — ad-hoc переподпись не удалась (обычно ок, если карантин снят)"

# Валидация: приложение должно проходить как минимум собственную проверку подписи.
codesign --verify --deep --strict "$DEST" >/dev/null 2>&1 \
  && echo "macos_local_install: codesign verify OK" \
  || echo "macos_local_install: внимание — codesign verify не прошёл (запуск всё равно возможен после снятия карантина)"

echo "macos_local_install: готово → $DEST"
echo "  запуск: open \"$DEST\"   (или из Launchpad/Finder без предупреждений)"

if [ "$LAUNCH" = "1" ]; then
  echo "macos_local_install: запускаю…"
  open "$DEST"
fi
