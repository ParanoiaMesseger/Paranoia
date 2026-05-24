#!/usr/bin/env bash
# Cross-compile libhunspell для iOS (iphoneos / iphonesimulator) и сложить
# артефакты в ParanoiaUiClient/deps/hunspell/ios-<arch>/{include,lib}.
# Подхватывается ParanoiaUiClient/CMakeLists.txt (см. iOS-ветку PARANOIA_HAS_HUNSPELL).
#
# Использование:
#   ./scripts/build_hunspell_ios.sh
#
# Env-переменные (всё опционально):
#   HUNSPELL_VERSION               — default 1.7.2
#   HUNSPELL_TARBALL_URL           — переопределить URL
#   HUNSPELL_IOS_ARCHS             — список архитектур через пробел (default "arm64")
#   HUNSPELL_IOS_SDK               — sdk (default "iphoneos")
#   IPHONEOS_DEPLOYMENT_TARGET     — default 17.0
#   PARANOIA_ROOT                  — корень репозитория
#   OUT_DIR                        — default $PARANOIA_ROOT/ParanoiaUiClient/deps/hunspell
#   FORCE_REBUILD                  — "1" для пересборки

set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
    echo "ERROR: этот скрипт работает только на macOS (нужен xcrun)" >&2
    exit 1
fi

HUNSPELL_VERSION="${HUNSPELL_VERSION:-1.7.2}"
HUNSPELL_TARBALL_URL="${HUNSPELL_TARBALL_URL:-https://github.com/hunspell/hunspell/archive/refs/tags/v${HUNSPELL_VERSION}.tar.gz}"
HUNSPELL_IOS_ARCHS="${HUNSPELL_IOS_ARCHS:-arm64}"
HUNSPELL_IOS_SDK="${HUNSPELL_IOS_SDK:-iphoneos}"
IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARANOIA_ROOT="${PARANOIA_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
OUT_DIR="${OUT_DIR:-$PARANOIA_ROOT/ParanoiaUiClient/deps/hunspell}"
HUNSPELL_WORK_DIR="${HUNSPELL_WORK_DIR:-$OUT_DIR/.build}"

SDK_PATH="$(xcrun --sdk "$HUNSPELL_IOS_SDK" --show-sdk-path 2>/dev/null || true)"
if [ -z "$SDK_PATH" ]; then
    echo "ERROR: xcrun не нашёл SDK '$HUNSPELL_IOS_SDK' — установлен ли Xcode?" >&2
    exit 1
fi

CLANG_BIN="$(xcrun --sdk "$HUNSPELL_IOS_SDK" --find clang++)"
AR_BIN="$(xcrun --sdk "$HUNSPELL_IOS_SDK" --find ar)"
RANLIB_BIN="$(xcrun --sdk "$HUNSPELL_IOS_SDK" --find ranlib)"

mkdir -p "$HUNSPELL_WORK_DIR"

TARBALL="$HUNSPELL_WORK_DIR/hunspell-${HUNSPELL_VERSION}.tar.gz"
SRCDIR="$HUNSPELL_WORK_DIR/hunspell-${HUNSPELL_VERSION}"

if [ ! -f "$TARBALL" ]; then
    echo "==> Загрузка hunspell-${HUNSPELL_VERSION}..."
    curl --proto '=https' --tlsv1.2 -fsSL "$HUNSPELL_TARBALL_URL" -o "$TARBALL.partial"
    mv "$TARBALL.partial" "$TARBALL"
fi
if [ ! -d "$SRCDIR" ]; then
    echo "==> Распаковка hunspell-${HUNSPELL_VERSION}..."
    tar -xzf "$TARBALL" -C "$HUNSPELL_WORK_DIR"
fi

# Генерируем configure если его нет (источник из git archive без autogen)
if [ ! -f "$SRCDIR/configure" ]; then
    echo "==> Генерация configure (autoreconf)..."
    (cd "$SRCDIR" && autoreconf -fi)
fi

build_one_arch() {
    local arch="$1"
    local out_subdir="ios-${arch}"
    if [ "$HUNSPELL_IOS_SDK" = "iphonesimulator" ]; then
        out_subdir="iossim-${arch}"
    fi
    local prefix="$OUT_DIR/$out_subdir"
    if [ "$FORCE_REBUILD" != "1" ] \
       && [ -f "$prefix/lib/libhunspell-1.7.a" ] \
       && [ -f "$prefix/include/hunspell/hunspell.h" ]; then
        echo "==> [$out_subdir] уже собран — пропуск"
        return
    fi

    local host
    case "$arch" in
        arm64)  host="aarch64-apple-darwin" ;;
        x86_64) host="x86_64-apple-darwin" ;;
        *) echo "WARN: неподдерживаемая iOS arch '$arch'" >&2; return ;;
    esac

    local builddir="$HUNSPELL_WORK_DIR/build-$out_subdir"
    rm -rf "$builddir" "$prefix"
    mkdir -p "$builddir"

    local arch_flags="-arch $arch"
    local min_flag="-mios-version-min=$IPHONEOS_DEPLOYMENT_TARGET"
    if [ "$HUNSPELL_IOS_SDK" = "iphonesimulator" ]; then
        min_flag="-mios-simulator-version-min=$IPHONEOS_DEPLOYMENT_TARGET"
    fi

    # --disable-dependency-tracking предотвращает deadlock в am--depfiles:
    # autotools пишет Makefile через pipe в make, pipe-буфер (64 KB) переполняется
    # при cross-compile на macOS → все процессы зависаю�� навсегда.
    (
        cd "$builddir"
        export CXX="$CLANG_BIN"
        export CC="$(xcrun --sdk "$HUNSPELL_IOS_SDK" --find clang)"
        export AR="$AR_BIN"
        export RANLIB="$RANLIB_BIN"
        export CXXFLAGS="$arch_flags -isysroot $SDK_PATH $min_flag -fPIC -O3 -std=c++11"
        export CFLAGS="$arch_flags -isysroot $SDK_PATH $min_flag -fPIC -O3"
        export LDFLAGS="$arch_flags -isysroot $SDK_PATH $min_flag"
        "$SRCDIR/configure" \
            --host="$host" \
            --prefix="$prefix" \
            --enable-static \
            --disable-shared \
            --disable-dependency-tracking \
            --disable-nls
        make -j"$(sysctl -n hw.ncpu)" -C src/hunspell
        rm -rf "$prefix"
        mkdir -p "$prefix/lib" "$prefix/include/hunspell"
        # make install пытается собрать CLI-инструмент (непригоден для iOS).
        # Копируем только библиотеку и заголовки вручную.
        cp src/hunspell/.libs/libhunspell-1.7.a "$prefix/lib/"
        cp "$SRCDIR/src/hunspell/"*.h "$prefix/include/hunspell/" 2>/dev/null || true
        cp "$SRCDIR/src/hunspell/"*.hxx "$prefix/include/hunspell/" 2>/dev/null || true
        "$AR_BIN" -s "$prefix/lib/libhunspell-1.7.a"
    )

    if [ ! -f "$prefix/lib/libhunspell-1.7.a" ] || [ ! -f "$prefix/include/hunspell/hunspell.h" ]; then
        echo "ERROR: установка hunspell для $out_subdir не дала ожидаемых файлов" >&2
        ls "$prefix/lib/" 2>/dev/null || true
        exit 1
    fi
    echo "==> [$out_subdir] OK: $prefix/lib/libhunspell-1.7.a"
}

for arch in $HUNSPELL_IOS_ARCHS; do
    build_one_arch "$arch"
done

echo "==> Готово."
