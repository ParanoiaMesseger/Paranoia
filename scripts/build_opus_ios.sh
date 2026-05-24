#!/usr/bin/env bash
# Cross-compile libopus для iOS (iphoneos / iphonesimulator) и сложить
# артефакты в ParanoiaUiClient/deps/opus/ios-<arch>/{include,lib}.
# Подхватывается ParanoiaUiClient/CMakeLists.txt (см. iOS-ветку PARANOIA_HAS_OPUS).
#
# Использование:
#   ./scripts/build_opus_ios.sh
#
# Env-переменные (всё опционально):
#   OPUS_VERSION                 — default 1.5.2
#   OPUS_TARBALL_URL             — переопределить URL
#   OPUS_IOS_ARCHS               — список архитектур через пробел (default "arm64")
#   OPUS_IOS_SDK                 — sdk (default "iphoneos")
#                                   "iphonesimulator" — для симулятора
#   IPHONEOS_DEPLOYMENT_TARGET   — default 17.0
#   PARANOIA_ROOT                — корень репозитория
#   OUT_DIR                      — default $PARANOIA_ROOT/ParanoiaUiClient/deps/opus
#   FORCE_REBUILD                — "1" для пересборки

set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
    echo "ERROR: этот скрипт работает только на macOS (нужен xcrun)" >&2
    exit 1
fi

OPUS_VERSION="${OPUS_VERSION:-1.5.2}"
OPUS_TARBALL_URL="${OPUS_TARBALL_URL:-https://downloads.xiph.org/releases/opus/opus-${OPUS_VERSION}.tar.gz}"
OPUS_IOS_ARCHS="${OPUS_IOS_ARCHS:-arm64}"
OPUS_IOS_SDK="${OPUS_IOS_SDK:-iphoneos}"
IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARANOIA_ROOT="${PARANOIA_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
OUT_DIR="${OUT_DIR:-$PARANOIA_ROOT/ParanoiaUiClient/deps/opus}"
OPUS_WORK_DIR="${OPUS_WORK_DIR:-$OUT_DIR/.build}"

SDK_PATH="$(xcrun --sdk "$OPUS_IOS_SDK" --show-sdk-path 2>/dev/null || true)"
if [ -z "$SDK_PATH" ]; then
    echo "ERROR: xcrun не нашёл SDK '$OPUS_IOS_SDK' — установлен ли Xcode?" >&2
    exit 1
fi

mkdir -p "$OPUS_WORK_DIR"

TARBALL="$OPUS_WORK_DIR/opus-${OPUS_VERSION}.tar.gz"
SRCDIR="$OPUS_WORK_DIR/opus-${OPUS_VERSION}"

if [ ! -f "$TARBALL" ]; then
    echo "==> Загрузка opus-${OPUS_VERSION}..."
    curl --proto '=https' --tlsv1.2 -fsSL "$OPUS_TARBALL_URL" -o "$TARBALL.partial"
    mv "$TARBALL.partial" "$TARBALL"
fi
if [ ! -d "$SRCDIR" ]; then
    echo "==> Распаковка opus-${OPUS_VERSION}..."
    tar -xzf "$TARBALL" -C "$OPUS_WORK_DIR"
fi

# Только arm64 имеет смысл для iOS-устройств; для симулятора используется
# arm64 (M-серия) или x86_64 (Intel) с sdk=iphonesimulator.
build_one_arch() {
    local arch="$1"
    local out_subdir="ios-${arch}"
    local cmake_system_name="iOS"
    if [ "$OPUS_IOS_SDK" = "iphonesimulator" ]; then
        out_subdir="iossim-${arch}"
        cmake_system_name="iOS"
    fi
    local prefix="$OUT_DIR/$out_subdir"
    if [ "$FORCE_REBUILD" != "1" ] \
       && [ -f "$prefix/lib/libopus.a" ] \
       && [ -f "$prefix/include/opus/opus.h" ]; then
        echo "==> [$out_subdir] уже собран — пропуск"
        return
    fi

    local builddir="$OPUS_WORK_DIR/cmake-build-$out_subdir"
    rm -rf "$builddir" "$prefix"
    mkdir -p "$builddir"

    # Используем cmake вместо autotools: autotools генерирует depfiles через
    # `make -f - am--depfiles`, что вызывает deadlock pipe-буфера на macOS
    # при cross-компиляции для iOS. cmake/ninja лишён этой проблемы.
    cmake -S "$SRCDIR" -B "$builddir" \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME="$cmake_system_name" \
        -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$IPHONEOS_DEPLOYMENT_TARGET" \
        -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DBUILD_SHARED_LIBS=OFF \
        -DOPUS_BUILD_PROGRAMS=OFF \
        -DOPUS_BUILD_TESTING=OFF \
        -DOPUS_INSTALL_PKG_CONFIG_MODULE=ON

    cmake --build "$builddir" --parallel
    cmake --install "$builddir"

    if [ ! -f "$prefix/lib/libopus.a" ] || [ ! -f "$prefix/include/opus/opus.h" ]; then
        echo "ERROR: установка opus для $out_subdir не дала ожидаемых файлов" >&2
        exit 1
    fi
    echo "==> [$out_subdir] OK: $prefix/lib/libopus.a"
}

for arch in $OPUS_IOS_ARCHS; do
    build_one_arch "$arch"
done

echo "==> Готово."
