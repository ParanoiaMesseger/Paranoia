#!/usr/bin/env bash
# Упаковка клиента Paranoia в нативный macOS .dmg (drag-to-Applications).
#
# Почему не Qt Installer Framework: IFW на macOS генерирует .app-инсталлятор,
# который для нормальной работы Gatekeeper должен быть подписан и нотаризован.
# Подписать его мы не можем (нет Developer ID), а уже запакованный IFW-образ
# постфактум не подписать. Нативный .dmg с приложением и ярлыком на
# /Applications — стандартный для macOS способ раздачи, не требует
# installer-фреймворка и спокойно открывается после снятия карантина
# (правый клик → «Открыть» либо `xattr -dr com.apple.quarantine`).
#
# Что делает скрипт:
#   1. Ad-hoc переподписывает .app. macdeployqt при деплое правит install_name
#      у фреймворков/плагинов через install_name_tool — это инвалидирует
#      подпись, и на Apple Silicon приложение падает с "killed: 9" ещё до
#      main(). Переподпись (--sign -) восстанавливает валидную ad-hoc подпись.
#   2. Складывает .app + symlink на /Applications в staging-каталог.
#   3. Собирает сжатый (UDZO) .dmg через hdiutil — без GUI, работает headless.
#
# Использование:
#   package_macos_dmg.sh --app <path/to/Paranoia.app> --out <path/to/out.dmg> \
#                        [--version X.Y.Z] [--volname "Paranoia X.Y.Z"]
set -euo pipefail

APP=""
OUT=""
VERSION=""
VOLNAME=""

while [ $# -gt 0 ]; do
  case "$1" in
    --app)     APP="$2"; shift 2;;
    --out)     OUT="$2"; shift 2;;
    --version) VERSION="$2"; shift 2;;
    --volname) VOLNAME="$2"; shift 2;;
    *) echo "package_macos_dmg: unknown arg '$1'" >&2; exit 2;;
  esac
done

test -n "$APP" || { echo "package_macos_dmg: --app is required" >&2; exit 2; }
test -n "$OUT" || { echo "package_macos_dmg: --out is required" >&2; exit 2; }
test -d "$APP" || { echo "package_macos_dmg: app bundle not found: $APP" >&2; exit 1; }

APP_NAME="$(basename "$APP")"
VOLNAME="${VOLNAME:-Paranoia${VERSION:+ $VERSION}}"

echo "package_macos_dmg: app=$APP out=$OUT volname=$VOLNAME"

# 1. Подпись .app. macdeployqt правит install_name → подписи инвалидируются
#    (на Apple Silicon → "killed: 9" до main()), поэтому переподписываем ВСЕГДА.
#    По умолчанию ad-hoc (--sign -) — достаточно для локального запуска. Если
#    задан MACOS_SIGN_IDENTITY (имя сертификата Developer ID Application — только
#    платный Apple Developer аккаунт) — подписываем им + hardened runtime
#    (обязателен для нотаризации). Опц. MACOS_ENTITLEMENTS — путь к .entitlements.
if [ -n "${MACOS_SIGN_IDENTITY:-}" ]; then
  echo "package_macos_dmg: codesign Developer ID ($MACOS_SIGN_IDENTITY) + hardened runtime"
  ENTITLEMENTS_ARG=()
  [ -n "${MACOS_ENTITLEMENTS:-}" ] && ENTITLEMENTS_ARG=(--entitlements "$MACOS_ENTITLEMENTS")
  codesign --force --deep --options runtime --timestamp \
    "${ENTITLEMENTS_ARG[@]}" --sign "$MACOS_SIGN_IDENTITY" "$APP"
else
  echo "package_macos_dmg: ad-hoc codesign (без Developer ID — у скачавших будет Gatekeeper-карантин)"
  codesign --force --deep --sign - --timestamp=none "$APP"
fi
codesign --verify --deep --strict "$APP" \
  && echo "package_macos_dmg: codesign verify OK" \
  || { echo "package_macos_dmg: codesign verify FAILED" >&2; exit 1; }

# 2. Staging: только .app и ярлык на /Applications.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/paranoia-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/$APP_NAME"
ln -s /Applications "$STAGE/Applications"

# 3. Сборка сжатого образа. hdiutil сам создаёт том нужного размера.
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
echo "package_macos_dmg: hdiutil create ..."
hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$OUT"

test -f "$OUT" || { echo "package_macos_dmg: dmg was not created: $OUT" >&2; exit 1; }

# 4. Нотаризация (опционально — нужен Developer ID + платный Apple-аккаунт).
#    Включается, если в окружении заданы креды (CI-секреты). Иначе пропускаем —
#    остаётся ad-hoc dmg (запуск после снятия карантина, см. macos_local_install.sh).
#    Вариант 1: notarytool keychain-profile (`xcrun notarytool store-credentials`).
#    Вариант 2: тройка Apple ID / Team ID / app-specific password.
if [ -n "${MACOS_NOTARY_PROFILE:-}" ]; then
  echo "package_macos_dmg: notarize via keychain profile '$MACOS_NOTARY_PROFILE' (ждём вердикт Apple)…"
  xcrun notarytool submit "$OUT" --keychain-profile "$MACOS_NOTARY_PROFILE" --wait
  xcrun stapler staple "$OUT"
  echo "package_macos_dmg: notarized + stapled"
elif [ -n "${MACOS_NOTARY_APPLE_ID:-}" ] && [ -n "${MACOS_NOTARY_TEAM_ID:-}" ] && [ -n "${MACOS_NOTARY_PASSWORD:-}" ]; then
  echo "package_macos_dmg: notarize via Apple ID $MACOS_NOTARY_APPLE_ID (team $MACOS_NOTARY_TEAM_ID)…"
  xcrun notarytool submit "$OUT" \
    --apple-id "$MACOS_NOTARY_APPLE_ID" \
    --team-id "$MACOS_NOTARY_TEAM_ID" \
    --password "$MACOS_NOTARY_PASSWORD" --wait
  xcrun stapler staple "$OUT"
  echo "package_macos_dmg: notarized + stapled"
else
  echo "package_macos_dmg: нотаризация пропущена (нет MACOS_NOTARY_* / MACOS_SIGN_IDENTITY) — ad-hoc dmg"
fi

echo "package_macos_dmg: done -> $OUT"
ls -lh "$OUT"
