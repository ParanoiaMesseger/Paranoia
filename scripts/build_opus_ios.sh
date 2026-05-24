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

CLANG_BIN="$(xcrun --sdk "$OPUS_IOS_SDK" --find clang)"
AR_BIN="$(xcrun --sdk "$OPUS_IOS_SDK" --find ar)"
RANLIB_BIN="$(xcrun --sdk "$OPUS_IOS_SDK" --find ranlib)"

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

COMMON_CONF_ARGS=(
    --enable-static
    --disable-shared
    --disable-doc
    --disable-extra-programs
)

# Только arm64 имеет смысл для iOS-устройств; для симулятора используется
# arm64 (M-серия) или x86_64 (Intel) с sdk=iphonesimulator.
build_one_arch() {
    local arch="$1"
    local out_subdir="ios-${arch}"
    if [ "$OPUS_IOS_SDK" = "iphonesimulator" ]; then
        out_subdir="iossim-${arch}"
    fi
    local prefix="$OUT_DIR/$out_subdir"
    if [ "$FORCE_REBUILD" != "1" ] \
       && [ -f "$prefix/lib/libopus.a" ] \
       && [ -f "$prefix/include/opus/opus.h" ]; then
        echo "==> [$out_subdir] уже собран — пропуск"
        return
    fi

    # Триплет для autoconf.
    local host
    case "$arch" in
        arm64)  host="aarch64-apple-darwin" ;;
        x86_64) host="x86_64-apple-darwin" ;;
        *) echo "WARN: неподдерживаемая iOS arch '$arch'" >&2; return ;;
    esac

    local builddir="$OPUS_WORK_DIR/build-$out_subdir"
    rm -rf "$builddir"
    mkdir -p "$builddir"

    local arch_flags="-arch $arch"
    local min_flag="-mios-version-min=$IPHONEOS_DEPLOYMENT_TARGET"
    if [ "$OPUS_IOS_SDK" = "iphonesimulator" ]; then
        min_flag="-mios-simulator-version-min=$IPHONEOS_DEPLOYMENT_TARGET"
    fi

    (
        cd "$builddir"
        export CC="$CLANG_BIN"
        export AR="$AR_BIN"
        export RANLIB="$RANLIB_BIN"
        export CFLAGS="$arch_flags -isysroot $SDK_PATH $min_flag -fPIC -fembed-bitcode -O3"
        export LDFLAGS="$arch_flags -isysroot $SDK_PATH $min_flag"
        "$SRCDIR/configure" \
            --host="$host" \
            --prefix="$prefix" \
            "${COMMON_CONF_ARGS[@]}"
        make -j"$(sysctl -n hw.ncpu)"
        rm -rf "$prefix"
        mkdir -p "$prefix"
        make install
    )

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
