#!/usr/bin/env bash
# Пересборка модуля qtvirtualkeyboard с включённым bundled Hunspell поверх
# существующей установки Qt. Официальные aqt-бинарники Qt 6.10.x идут с
# FEATURE_hunspell=OFF — без него виртуальная клавиатура не имеет
# word-prediction для en_US / ru_RU и т.п. (см. config_qtvirtualkeyboard.summary
# у установки: "Hunspell ... no").
#
# Скрипт:
#  1. Берёт исходники qtvirtualkeyboard из $QT_SRC_ROOT/qtvirtualkeyboard.
#  2. Если нет — пытается скачать через `aqt install-src`.
#  3. Подкладывает hunspell ${HUNSPELL_VERSION} в
#     src/plugins/hunspell/3rdparty/hunspell/hunspell/ (sub-submodule, которого
#     нет в aqt-архиве источников).
#  4. cmake configure с -DFEATURE_hunspell=ON -DFEATURE_3rdparty_hunspell=ON.
#  5. cmake build + install в тот же Qt prefix.
#
# Использование:
#   scripts/rebuild_qtvkb_hunspell.sh desktop
#   scripts/rebuild_qtvkb_hunspell.sh android-arm64-v8a
#   scripts/rebuild_qtvkb_hunspell.sh macos              (host build)
#   scripts/rebuild_qtvkb_hunspell.sh ios-arm64          (cross-build с macOS host)
#
# Env (всё опционально):
#   QT_VERSION         — default 6.10.1
#   QT_DIR             — корень установки Qt (default $HOME/Qt)
#   QT_SRC_ROOT        — корень исходников Qt (default $QT_DIR/$QT_VERSION/Src)
#   QT_HOST_PATH       — host Qt prefix для cross-build (android/ios)
#                        (default android: $QT_DIR/$QT_VERSION/gcc_64,
#                         ios: $QT_DIR/$QT_VERSION/macos)
#   QT_HOST_OS         — для aqt install-src (default linux на Linux, mac на macOS)
#   ANDROID_NDK_ROOT   — путь к NDK (только для android-* target)
#   ANDROID_SDK_ROOT   — путь к SDK
#   ANDROID_PLATFORM   — default android-24
#   IOS_DEPLOYMENT_TARGET — default 17.0
#   HUNSPELL_VERSION   — default 1.7.2
#   BUILD_DIR          — рабочий каталог сборки (default /tmp/qtvkb-build-$target)
#   FORCE_REBUILD      — "1" чтобы пересобрать даже если плагин уже стоит
#
# Зависимости: cmake, ninja, perl, curl (для скачивания hunspell), tar; для
# android — Android NDK; для ios — Xcode (xcrun); aqt опционален (нужен, только
# если исходников Qt нет).

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 <desktop|android-arm64-v8a|macos|ios-arm64>" >&2
    exit 2
fi

TARGET="$1"
QT_VERSION="${QT_VERSION:-6.10.1}"
QT_DIR="${QT_DIR:-$HOME/Qt}"
QT_SRC_ROOT="${QT_SRC_ROOT:-$QT_DIR/$QT_VERSION/Src}"
HUNSPELL_VERSION="${HUNSPELL_VERSION:-1.7.2}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"

# Определяем host OS для aqt install-src.
case "$(uname -s)" in
    Darwin) DEFAULT_HOST_OS=mac   ;;
    Linux)  DEFAULT_HOST_OS=linux ;;
    *)      DEFAULT_HOST_OS=linux ;;
esac
QT_HOST_OS="${QT_HOST_OS:-$DEFAULT_HOST_OS}"

case "$TARGET" in
    desktop)
        QT_PREFIX="${QT_PREFIX:-$QT_DIR/$QT_VERSION/gcc_64}"
        BUILD_DIR="${BUILD_DIR:-/tmp/qtvkb-build-desktop}"
        ;;
    android-arm64-v8a)
        QT_PREFIX="${QT_PREFIX:-$QT_DIR/$QT_VERSION/android_arm64_v8a}"
        QT_HOST_PATH="${QT_HOST_PATH:-$QT_DIR/$QT_VERSION/gcc_64}"
        ANDROID_PLATFORM="${ANDROID_PLATFORM:-android-24}"
        BUILD_DIR="${BUILD_DIR:-/tmp/qtvkb-build-android-arm64-v8a}"
        ;;
    macos)
        QT_PREFIX="${QT_PREFIX:-$QT_DIR/$QT_VERSION/macos}"
        BUILD_DIR="${BUILD_DIR:-/tmp/qtvkb-build-macos}"
        ;;
    ios-arm64)
        QT_PREFIX="${QT_PREFIX:-$QT_DIR/$QT_VERSION/ios}"
        QT_HOST_PATH="${QT_HOST_PATH:-$QT_DIR/$QT_VERSION/macos}"
        IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-17.0}"
        BUILD_DIR="${BUILD_DIR:-/tmp/qtvkb-build-ios-arm64}"
        ;;
    *)
        echo "Unknown target: $TARGET" >&2
        exit 2
        ;;
esac

# Имя файла плагина зависит от платформы (Android добавляет полный prefix; iOS
# собирается STATIC → .a; macOS → .dylib). Чтобы не дублировать ветки case,
# проверяем существование любого плагина в каталоге.
PLUGIN_DIR="$QT_PREFIX/qml/QtQuick/VirtualKeyboard/Plugins/Hunspell"
find_installed_plugin() {
    # Если каталога нет — плагин ещё не ставился, возвращаем пусто.
    [ -d "$PLUGIN_DIR" ] || return 0
    find "$PLUGIN_DIR" -maxdepth 1 \
        \( -name 'libqtvkbhunspellplugin*' -o -name '*Hunspell*qtvkbhunspellplugin*' \) \
        \( -name '*.so' -o -name '*.dylib' -o -name '*.a' \) \
        2>/dev/null | head -1 || true
}
PLUGIN_INSTALLED="$(find_installed_plugin)"
if [ "$FORCE_REBUILD" != "1" ] && [ -n "$PLUGIN_INSTALLED" ]; then
    echo "==> [$TARGET] Hunspell plugin уже установлен: $PLUGIN_INSTALLED — пропуск"
    echo "    (используйте FORCE_REBUILD=1 для пересборки)"
    exit 0
fi

# 1. Качаем исходники Qt VirtualKeyboard, если их нет.
QTVKB_SRC="$QT_SRC_ROOT/qtvirtualkeyboard"
if [ ! -d "$QTVKB_SRC" ]; then
    echo "==> [$TARGET] Qt source not found at $QTVKB_SRC — пробуем aqt install-src"
    command -v aqt >/dev/null 2>&1 || {
        echo "ERROR: aqt не найден; установите его или укажите QT_SRC_ROOT вручную." >&2
        exit 1
    }
    mkdir -p "$QT_DIR"
    aqt install-src "$QT_HOST_OS" desktop "$QT_VERSION" \
        --archives qtvirtualkeyboard --outputdir "$QT_DIR"
    [ -d "$QTVKB_SRC" ] || { echo "ERROR: aqt не положил qtvirtualkeyboard в $QTVKB_SRC" >&2; exit 1; }
fi

# 2. Подкладываем hunspell в bundled-каталог (aqt-source archive не содержит
#    git-submodule с собственно hunspell — только cmake-обёртку).
HUNSPELL_BUNDLE_DIR="$QTVKB_SRC/src/plugins/hunspell/3rdparty/hunspell/hunspell"
if [ ! -f "$HUNSPELL_BUNDLE_DIR/src/hunspell/hunspell.h" ]; then
    echo "==> [$TARGET] Подкладываем hunspell-${HUNSPELL_VERSION} в $HUNSPELL_BUNDLE_DIR"
    TARBALL="/tmp/hunspell-${HUNSPELL_VERSION}.tar.gz"
    if [ ! -f "$TARBALL" ]; then
        curl --proto '=https' --tlsv1.2 -fsSL \
            "https://github.com/hunspell/hunspell/archive/refs/tags/v${HUNSPELL_VERSION}.tar.gz" \
            -o "$TARBALL.partial"
        mv "$TARBALL.partial" "$TARBALL"
    fi
    rm -rf "$HUNSPELL_BUNDLE_DIR" "/tmp/hunspell-${HUNSPELL_VERSION}"
    tar -xzf "$TARBALL" -C /tmp
    mkdir -p "$(dirname "$HUNSPELL_BUNDLE_DIR")"
    mv "/tmp/hunspell-${HUNSPELL_VERSION}" "$HUNSPELL_BUNDLE_DIR"
    [ -f "$HUNSPELL_BUNDLE_DIR/src/hunspell/hunspell.h" ] || {
        echo "ERROR: после распаковки нет $HUNSPELL_BUNDLE_DIR/src/hunspell/hunspell.h" >&2
        exit 1
    }
fi

# 3. cmake configure
echo "==> [$TARGET] cmake configure"
rm -rf "$BUILD_DIR"

CMAKE_ARGS=(
    -S "$QTVKB_SRC"
    -B "$BUILD_DIR"
    -G Ninja
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_PREFIX_PATH="$QT_PREFIX"
    -DCMAKE_INSTALL_PREFIX="$QT_PREFIX"
    -DFEATURE_hunspell=ON
    -DFEATURE_3rdparty_hunspell=ON
    -DFEATURE_system_hunspell=OFF
)

if [ "$TARGET" = "android-arm64-v8a" ]; then
    : "${ANDROID_NDK_ROOT:?ANDROID_NDK_ROOT must be set for android target}"
    CMAKE_ARGS+=(
        -DCMAKE_TOOLCHAIN_FILE="$QT_PREFIX/lib/cmake/Qt6/qt.toolchain.cmake"
        -DANDROID_ABI=arm64-v8a
        -DANDROID_PLATFORM="$ANDROID_PLATFORM"
        -DANDROID_STL=c++_shared
        -DANDROID_NDK_ROOT="$ANDROID_NDK_ROOT"
        -DQT_HOST_PATH="$QT_HOST_PATH"
    )
    [ -n "${ANDROID_SDK_ROOT:-}" ] && CMAKE_ARGS+=(-DANDROID_SDK_ROOT="$ANDROID_SDK_ROOT")
elif [ "$TARGET" = "ios-arm64" ]; then
    # Qt iOS — cross-build с macOS host. Plugin будет статической библиотекой
    # (Qt iOS принципиально STATIC-only). Подцепляется к приложению через
    # Q_IMPORT_PLUGIN, который генерирует Qt CMake машинерия.
    CMAKE_ARGS+=(
        -DCMAKE_TOOLCHAIN_FILE="$QT_PREFIX/lib/cmake/Qt6/qt.toolchain.cmake"
        -DCMAKE_SYSTEM_NAME=iOS
        -DCMAKE_OSX_SYSROOT=iphoneos
        -DCMAKE_OSX_ARCHITECTURES=arm64
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET"
        -DQT_HOST_PATH="$QT_HOST_PATH"
    )
fi

cmake "${CMAKE_ARGS[@]}"

# 4. build + install
echo "==> [$TARGET] cmake build"
cmake --build "$BUILD_DIR" --parallel

echo "==> [$TARGET] cmake install в $QT_PREFIX"
cmake --install "$BUILD_DIR"

# 5. Sanity check + summary
PLUGIN_INSTALLED="$(find_installed_plugin)"
if [ -z "$PLUGIN_INSTALLED" ]; then
    echo "ERROR: после install плагин не найден под $PLUGIN_DIR" >&2
    ls -la "$PLUGIN_DIR" 2>&1 || true
    exit 1
fi

SUMMARY="$QT_PREFIX/config_qtvirtualkeyboard.summary"
if [ -f "$SUMMARY" ]; then
    if ! grep -qE 'Hunspell *\.+ *yes' "$SUMMARY"; then
        echo "WARN: $SUMMARY всё ещё не помечен как Hunspell=yes" >&2
    fi
fi

echo "==> [$TARGET] OK: $PLUGIN_INSTALLED"
