#!/usr/bin/env bash
# Пересборка iOS QPA-плагина qtbase с применённым патчем
# ci/patches/qt-6.10.1-ios-qpa-im-module.patch.
#
# Зачем: официальный iOS QPA Qt 6.10.x жёстко создаёт QIOSInputContext и
# игнорирует QT_IM_MODULE — в отличие от Android, который через
# QPlatformInputContextFactory подцепляет qtvirtualkeyboard. Без этого на iOS
# параллельно с Qt VKB поднимается системная iOS-клавиатура (UITextResponder),
# а ввод уходит в неё. Для нашей threat-model (подозрение на keylog через
# Apple ML / сторонние клавиатуры) системная клавиатура неприемлема.
#
# Патч: 5-строчная вставка в qiosintegration.mm — bait для
# QPlatformInputContextFactory::requested(), как в Android-QPA. Полностью
# обратно-совместима, если QT_IM_MODULE не задан → поведение Qt по умолчанию.
#
# Use case: запускается ОДИН раз на macOS-раннере (или после каждого upgrade
# Qt). Помечает Qt iOS prefix файлом-маркером — последующие запуски no-op.
#
# Цена: ~15–30 минут на configure + build qtbase iOS arm64 (один раз). Идём
# тяжёлым путём (полный qtbase configure), потому что QIOSIntegrationPlugin
# использует Qt-internal CMake macros (qt_internal_add_plugin) которые
# доступны только при конфигурации внутри qtbase tree.
#
# Использование:
#   scripts/rebuild_ios_qtbase_qpa.sh
#
# Env (всё опционально, есть разумные default):
#   QT_VERSION          — default 6.10.1
#   QT_DIR              — корень установки Qt (default $HOME/Qt; в CI обычно
#                         /opt/qt задают через QT_IOS_DIR/QT_MACOS_DIR)
#   QT_IOS_PREFIX       — Qt iOS prefix (default $QT_DIR/$QT_VERSION/ios)
#   QT_HOST_PATH        — Qt macOS host prefix для build-tools
#                         (default $QT_DIR/$QT_VERSION/macos)
#   QT_SRC_ROOT         — где лежат исходники Qt (default $QT_DIR/$QT_VERSION/Src)
#   QT_HOST_OS          — для aqt install-src (default mac на macOS, иначе linux)
#   BUILD_DIR           — рабочий каталог (default /tmp/qtbase-ios-build)
#   IOS_DEPLOYMENT_TARGET — default 17.0
#   FORCE_REBUILD       — "1" чтобы пересобрать даже если marker уже есть
#   PATCH_FILE          — путь к патчу (default $REPO_ROOT/ci/patches/...)
#
# Зависимости: cmake, ninja, Xcode (xcrun), patch, curl, tar; aqt опционален
# (нужен только если qtbase исходников нет на машине).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

QT_VERSION="${QT_VERSION:-6.10.1}"
QT_DIR="${QT_DIR:-$HOME/Qt}"
QT_IOS_PREFIX="${QT_IOS_PREFIX:-$QT_DIR/$QT_VERSION/ios}"
QT_HOST_PATH="${QT_HOST_PATH:-$QT_DIR/$QT_VERSION/macos}"
QT_SRC_ROOT="${QT_SRC_ROOT:-$QT_DIR/$QT_VERSION/Src}"
BUILD_DIR="${BUILD_DIR:-/tmp/qtbase-ios-build}"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-17.0}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"
PATCH_FILE="${PATCH_FILE:-$REPO_ROOT/ci/patches/qt-6.10.1-ios-qpa-im-module.patch}"

case "$(uname -s)" in
    Darwin) DEFAULT_HOST_OS=mac   ;;
    Linux)  DEFAULT_HOST_OS=linux ;;
    *)      DEFAULT_HOST_OS=linux ;;
esac
QT_HOST_OS="${QT_HOST_OS:-$DEFAULT_HOST_OS}"

# Версия марке��а — менять, когда patch изменяется не-bug-fix способом.
MARKER_VERSION="1"
MARKER_FILE="$QT_IOS_PREFIX/.paranoia-ios-qpa-im-module-v${MARKER_VERSION}"
PLUGIN_INSTALLED="$QT_IOS_PREFIX/plugins/platforms/libqios.a"

# 0. Sanity check
[ -f "$PATCH_FILE" ] || { echo "ERROR: patch не найден: $PATCH_FILE" >&2; exit 1; }
[ -d "$QT_IOS_PREFIX/lib/cmake/Qt6" ] || {
    echo "ERROR: Qt iOS не установлен под $QT_IOS_PREFIX (нет lib/cmake/Qt6)" >&2
    exit 1
}
[ -d "$QT_HOST_PATH/lib/cmake/Qt6" ] || {
    echo "ERROR: Qt host macOS не установлен под $QT_HOST_PATH (нет lib/cmake/Qt6)" >&2
    exit 1
}

if [ "$FORCE_REBUILD" != "1" ] && [ -f "$MARKER_FILE" ] && [ -f "$PLUGIN_INSTALLED" ]; then
    echo "==> iOS QPA уже пропатчен и собран (marker: $MARKER_FILE) — пропуск"
    echo "    (используйте FORCE_REBUILD=1 для пересборки)"
    exit 0
fi

# 1. Берём qtbase source.
QTBASE_SRC="$QT_SRC_ROOT/qtbase"
if [ ! -f "$QTBASE_SRC/src/plugins/platforms/ios/qiosintegration.mm" ]; then
    echo "==> qtbase source не найден; пробуем aqt install-src"
    command -v aqt >/dev/null 2>&1 || {
        echo "ERROR: aqt не найден; установите или укажите QT_SRC_ROOT вручную." >&2
        exit 1
    }
    mkdir -p "$QT_DIR"
    aqt install-src "$QT_HOST_OS" desktop "$QT_VERSION" \
        --archives qtbase --outputdir "$QT_DIR"
    [ -f "$QTBASE_SRC/src/plugins/platforms/ios/qiosintegration.mm" ] || {
        echo "ERROR: aqt не положил qtbase в $QTBASE_SRC" >&2
        exit 1
    }
fi

# 2. Применяем патч идемпотентно. `patch --forward` сам пропустит уже
#    применённый patch и вернёт 1 — это валидное состояние.
echo "==> Применяю патч (если ещё не применён)"
PATCH_TARGET="$QTBASE_SRC/src/plugins/platforms/ios/qiosintegration.mm"
if grep -q 'Paranoia patch:' "$PATCH_TARGET"; then
    echo "    patch уже применён в qtbase-src"
else
    (cd "$QTBASE_SRC" && patch -p1 --forward < "$PATCH_FILE")
    grep -q 'Paranoia patch:' "$PATCH_TARGET" || {
        echo "ERROR: после patch маркер не найден в $PATCH_TARGET" >&2
        exit 1
    }
fi

# 2b. Совместимость с clang из Xcode 26 (clang 21): qyieldcpu.h зовёт ARM-интринсик
#     __yield() в ветке `#if __has_builtin(__yield)`, но __has_builtin у нового
#     clang возвращает true, а сама функция объявлена только в <arm_acle.h>. Без
#     неё в C++/ObjC++ это hard error (implicit-function-declaration). Qt свои
#     модульные таргеты собирает с собственными флагами и игнорирует
#     CMAKE_CXX_FLAGS, поэтому force-include не проходит — инъектируем include
#     прямо в заголовок (идемпотентно). Апстрим Qt сделал то же самое.
QYIELD_HDR="$QTBASE_SRC/src/corelib/thread/qyieldcpu.h"
if [ -f "$QYIELD_HDR" ] && ! grep -q 'Paranoia: arm_acle' "$QYIELD_HDR"; then
    echo "==> Инъекция <arm_acle.h> в qyieldcpu.h (clang 21 / Xcode 26 fix)"
    # Вставляем include сразу после include-блока (после qtconfigmacros.h).
    /usr/bin/sed -i '' \
        's|#include <QtCore/qtconfigmacros.h>|#include <QtCore/qtconfigmacros.h>\
\
// Paranoia: arm_acle для объявления __yield() на ARM (clang 21 / Xcode 26)\
#if defined(__has_include)\
#  if defined(__aarch64__) \&\& __has_include(<arm_acle.h>)\
#    include <arm_acle.h>\
#  endif\
#endif|' "$QYIELD_HDR"
    grep -q 'Paranoia: arm_acle' "$QYIELD_HDR" || {
        echo "ERROR: не удалось инъектировать arm_acle.h в $QYIELD_HDR" >&2
        exit 1
    }
fi

# 3. Configure qtbase для iOS.
#    NB: НЕ передаём qt.toolchain.cmake (auto-generated из qtbase) — Qt сам
#    ругается «qt.toolchain.cmake includes itself» (QtAutoDetectHelpers.cmake,
#    qt_auto_detect_cyclic_toolchain). qt.toolchain.cmake — для downstream-apps,
#    не для самого qtbase. Вместо этого задаём cross-vars напрямую:
#    CMAKE_SYSTEM_NAME=iOS + sysroot/arch/deployment-target + QT_HOST_PATH.
#
# qtbase top-level CMakeLists запрещает symlinks в build-пути
# (qt_internal_check_if_path_has_symlinks). На macOS /tmp → /private/tmp,
# поэтому default BUILD_DIR=/tmp/qtbase-ios-build падает с
# "The path ... contains symlinks". Резолвим симлинки через pwd -P.
echo "==> cmake configure qtbase iOS"
rm -rf "$BUILD_DIR"
BUILD_DIR_PARENT="$(dirname "$BUILD_DIR")"
mkdir -p "$BUILD_DIR_PARENT"
BUILD_DIR="$(cd "$BUILD_DIR_PARENT" && pwd -P)/$(basename "$BUILD_DIR")"
cmake -S "$QTBASE_SRC" \
    -B "$BUILD_DIR" \
    -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
    -DCMAKE_INSTALL_PREFIX="$QT_IOS_PREFIX" \
    -DCMAKE_BUILD_TYPE=Release \
    -DQT_HOST_PATH="$QT_HOST_PATH" \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_TESTING=OFF \
    -DQT_BUILD_EXAMPLES=OFF \
    -DQT_BUILD_TESTS=OFF \
    -DQT_BUILD_BENCHMARKS=OFF

# 4. Build только нужный target — qtbase соберёт его зависимости (Qt::Core,
#    Qt::Gui, их Private targets), но не остальные плагины/инструменты.
echo "==> cmake build QIOSIntegrationPlugin (это долгая операция, ~15–30 мин)"
cmake --build "$BUILD_DIR" --target QIOSIntegrationPlugin --parallel

# 5. Найти libqios.a и положить в Qt iOS prefix.
BUILT_PLUGIN="$(find "$BUILD_DIR" -name 'libqios.a' -type f -print -quit)"
if [ -z "$BUILT_PLUGIN" ]; then
    echo "ERROR: после build не найден libqios.a в $BUILD_DIR" >&2
    find "$BUILD_DIR" -name 'libqios*' 2>&1 | head
    exit 1
fi
echo "==> Найден: $BUILT_PLUGIN"

# Бэкап оригинального плагина (один раз — не перетираем при повторных запусках).
ORIG_BACKUP="$QT_IOS_PREFIX/plugins/platforms/libqios.a.paranoia-orig"
if [ ! -f "$ORIG_BACKUP" ] && [ -f "$PLUGIN_INSTALLED" ]; then
    cp "$PLUGIN_INSTALLED" "$ORIG_BACKUP"
    echo "==> Бэкап оригинального плагина: $ORIG_BACKUP"
fi

install -m 644 "$BUILT_PLUGIN" "$PLUGIN_INSTALLED"
echo "==> Установлен: $PLUGIN_INSTALLED"

# 6. Записываем маркер с метаданными.
{
    echo "Paranoia iOS QPA patch v${MARKER_VERSION}"
    echo "Applied: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "Patch source: $(basename "$PATCH_FILE")"
    echo "Qt version: $QT_VERSION"
    echo "Built plugin sha256: $(shasum -a 256 "$BUILT_PLUGIN" 2>/dev/null || sha256sum "$BUILT_PLUGIN" | awk '{print $1}')"
} > "$MARKER_FILE"

echo "==> OK. Маркер: $MARKER_FILE"
echo "    Для проверки: nm $PLUGIN_INSTALLED | grep -i InputContextFactory"
