#!/usr/bin/env bash
# Cross-compile libopus для Android ABI и сложить артефакты в
# ParanoiaUiClient/deps/opus/<abi>/{include,lib}. Эту структуру подхватывает
# `ParanoiaUiClient/CMakeLists.txt` (см. секцию PARANOIA_HAS_OPUS).
#
# Использование:
#   ANDROID_NDK_ROOT=/path/to/ndk \
#   OPUS_ABIS="arm64-v8a armeabi-v7a x86_64 x86" \
#   ./scripts/build_opus_android.sh
#
# Env-переменные (всё опционально, кроме ANDROID_NDK_ROOT):
#   OPUS_VERSION       — версия opus (default 1.5.2)
#   OPUS_TARBALL_URL   — переопределить URL загрузки
#   OPUS_ABIS          — список ABI через пробел (default "arm64-v8a")
#   OPUS_API_LEVEL     — Android API level (default 24)
#   PARANOIA_ROOT      — корень репозитория (default — авто от расположения скрипта)
#   OUT_DIR            — куда сложить, default $PARANOIA_ROOT/ParanoiaUiClient/deps/opus
#   OPUS_WORK_DIR      — кеш распакованных исходников (default $OUT_DIR/.build)
#   FORCE_REBUILD      — если "1", игнорировать кеш и пересобрать всё
#
# Кеширование: если $OUT_DIR/<abi>/lib/libopus.a уже существует, ABI
# пропускается. Удалите целевую директорию или установите FORCE_REBUILD=1
# чтобы пересобрать.

set -euo pipefail

OPUS_VERSION="${OPUS_VERSION:-1.5.2}"
OPUS_TARBALL_URL="${OPUS_TARBALL_URL:-https://downloads.xiph.org/releases/opus/opus-${OPUS_VERSION}.tar.gz}"
OPUS_ABIS="${OPUS_ABIS:-arm64-v8a}"
OPUS_API_LEVEL="${OPUS_API_LEVEL:-24}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARANOIA_ROOT="${PARANOIA_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
OUT_DIR="${OUT_DIR:-$PARANOIA_ROOT/ParanoiaUiClient/deps/opus}"
OPUS_WORK_DIR="${OPUS_WORK_DIR:-$OUT_DIR/.build}"

if [ -z "${ANDROID_NDK_ROOT:-}" ]; then
    echo "ERROR: ANDROID_NDK_ROOT не задан" >&2
    exit 1
fi
if [ ! -d "$ANDROID_NDK_ROOT" ]; then
    echo "ERROR: ANDROID_NDK_ROOT не существует: $ANDROID_NDK_ROOT" >&2
    exit 1
fi

case "$(uname -s)" in
    Linux)  HOST_TAG="linux-x86_64" ;;
    Darwin) HOST_TAG="darwin-x86_64" ;;
    *) echo "ERROR: неподдерживаемая host OS: $(uname -s)" >&2; exit 1 ;;
esac

TOOLCHAIN="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/$HOST_TAG"
if [ ! -d "$TOOLCHAIN" ]; then
    echo "ERROR: NDK toolchain не найден: $TOOLCHAIN" >&2
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

abi_target() {
    case "$1" in
        arm64-v8a)    echo "aarch64-linux-android" ;;
        armeabi-v7a)  echo "armv7a-linux-androideabi" ;;
        x86_64)       echo "x86_64-linux-android" ;;
        x86)          echo "i686-linux-android" ;;
        *) echo "" ;;
    esac
}

# Configure-флаги общие для всех ABI: только статическая библиотека,
# без doc/extra программ; нам нужен лишь encoder/decoder.
COMMON_CONF_ARGS=(
    --enable-static
    --disable-shared
    --disable-doc
    --disable-extra-programs
)

build_one_abi() {
    local abi="$1"
    local target
    target="$(abi_target "$abi")"
    if [ -z "$target" ]; then
        echo "WARN: неизвестный ABI '$abi' — пропуск" >&2
        return
    fi
    local prefix="$OUT_DIR/$abi"
    if [ "$FORCE_REBUILD" != "1" ] \
       && [ -f "$prefix/lib/libopus.a" ] \
       && [ -f "$prefix/include/opus/opus.h" ]; then
        echo "==> [$abi] уже собран ($prefix/lib/libopus.a) — пропуск"
        return
    fi

    echo "==> [$abi] сборка opus (target=$target)"
    local builddir="$OPUS_WORK_DIR/build-$abi"
    rm -rf "$builddir"
    mkdir -p "$builddir"

    (
        cd "$builddir"
        local cc_bin="$TOOLCHAIN/bin/${target}${OPUS_API_LEVEL}-clang"
        if [ ! -x "$cc_bin" ]; then
            echo "ERROR: clang для $target не найден: $cc_bin" >&2
            exit 1
        fi
        # Очищаем кэш-флаги от CCACHE и т.п., чтобы они не сломали clang detection.
        export CC="$cc_bin"
        export AR="$TOOLCHAIN/bin/llvm-ar"
        export RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
        export STRIP="$TOOLCHAIN/bin/llvm-strip"
        export NM="$TOOLCHAIN/bin/llvm-nm"
        # CFLAGS: -O3 + -fPIC. ВАЖНО: autoconf вставляет дефолтные `-g -O2`
        # только когда CFLAGS не задан caller'ом — как только мы экспортируем
        # свой CFLAGS, дефолт пропадает и opus компилируется с -O0 (выдаёт
        # «You appear to be compiling without optimization» pragma message и
        # работает в разы медленнее). Поэтому -O3 указываем явно.
        export CFLAGS="${CFLAGS:-} -O3 -fPIC"
        "$SRCDIR/configure" \
            --host="$target" \
            --prefix="$prefix" \
            "${COMMON_CONF_ARGS[@]}"
        make -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
        rm -rf "$prefix"
        mkdir -p "$prefix"
        make install
    )

    # Sanity check.
    if [ ! -f "$prefix/lib/libopus.a" ] || [ ! -f "$prefix/include/opus/opus.h" ]; then
        echo "ERROR: установка opus для $abi не дала ожидаемых файлов" >&2
        exit 1
    fi
    echo "==> [$abi] OK: $prefix/lib/libopus.a"
}

for abi in $OPUS_ABIS; do
    build_one_abi "$abi"
done

echo "==> Готово. Артефакты:"
for abi in $OPUS_ABIS; do
    target="$(abi_target "$abi")"
    [ -z "$target" ] && continue
    echo "    - $OUT_DIR/$abi/lib/libopus.a"
done
