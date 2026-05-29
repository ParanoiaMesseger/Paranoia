#!/usr/bin/env bash
# Build Cisco OpenH264 (BSD) statically for desktop Linux and place artifacts
# into ParanoiaUiClient/deps/openh264/linux-<arch>/{include,lib}. Layout matches
# the Android variant (build_openh264_linux.sh ⇄ build_openh264_android.sh) and
# is consumed by build_ffmpeg_linux.sh (--enable-libopenh264) and by CMake.
#
# Why static OpenH264 on desktop: даёт собственный H.264 encoder/decoder,
# вкомпилированный в бинарь, чтобы клиент не зависел от системного FFmpeg и был
# переносим между Ubuntu 22.04/24.04 и пр. (libx264 — GPL, потому не вариант).
#
# Usage:
#   ./scripts/build_openh264_linux.sh
#
# Env:
#   OPENH264_VERSION       default 2.4.1
#   OPENH264_TARBALL_URL   override source tarball URL
#   PARANOIA_ROOT          repository root
#   OUT_DIR                default $PARANOIA_ROOT/ParanoiaUiClient/deps/openh264
#   OPENH264_WORK_DIR      source/build cache directory
#   FORCE_REBUILD          "1" to rebuild even when artifacts exist

set -euo pipefail

OPENH264_VERSION="${OPENH264_VERSION:-2.4.1}"
OPENH264_TARBALL_URL="${OPENH264_TARBALL_URL:-https://github.com/cisco/openh264/archive/refs/tags/v${OPENH264_VERSION}.tar.gz}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARANOIA_ROOT="${PARANOIA_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
OUT_DIR="${OUT_DIR:-$PARANOIA_ROOT/ParanoiaUiClient/deps/openh264}"
OPENH264_WORK_DIR="${OPENH264_WORK_DIR:-$OUT_DIR/.build}"

# OpenH264 Makefile ARCH для нативной сборки соответствует uname -m.
case "$(uname -m)" in
    x86_64)  OH_ARCH="x86_64"; TAG="linux-x86_64" ;;
    aarch64) OH_ARCH="arm64";  TAG="linux-aarch64" ;;
    *) echo "ERROR: unsupported host arch: $(uname -m)" >&2; exit 1 ;;
esac

mkdir -p "$OPENH264_WORK_DIR"
TARBALL="$OPENH264_WORK_DIR/openh264-${OPENH264_VERSION}.tar.gz"
SRCDIR="$OPENH264_WORK_DIR/openh264-${OPENH264_VERSION}"

if [ ! -f "$TARBALL" ]; then
    echo "==> Downloading OpenH264 ${OPENH264_VERSION}..."
    curl --proto '=https' --tlsv1.2 -fsSL "$OPENH264_TARBALL_URL" -o "$TARBALL.partial"
    mv "$TARBALL.partial" "$TARBALL"
fi
if [ ! -d "$SRCDIR" ]; then
    echo "==> Extracting OpenH264 ${OPENH264_VERSION}..."
    tar -xf "$TARBALL" -C "$OPENH264_WORK_DIR"
fi

jobs_count() { if command -v nproc >/dev/null 2>&1; then nproc; else echo 4; fi; }

prefix="$OUT_DIR/$TAG"
if [ "$FORCE_REBUILD" != "1" ] \
   && [ -f "$prefix/lib/libopenh264.a" ] \
   && [ -f "$prefix/include/wels/codec_api.h" ]; then
    echo "==> [$TAG] OpenH264 already built — skip"
    exit 0
fi

echo "==> [$TAG] building OpenH264 (arch=$OH_ARCH)"
rm -rf "$prefix"
mkdir -p "$prefix/include" "$prefix/lib"
(
    cd "$SRCDIR"
    make_vars=(OS=linux ARCH="$OH_ARCH" PREFIX="$prefix")
    make clean "${make_vars[@]}" >/dev/null 2>&1 || true
    # `libraries` target: только libopenh264.{a,so}, без decdemo/encdemo.
    make -j"$(jobs_count)" "${make_vars[@]}" libraries
    make "${make_vars[@]}" install-static
)

test -f "$prefix/lib/libopenh264.a" || { echo "ERROR: libopenh264.a not produced" >&2; exit 1; }
test -f "$prefix/lib/pkgconfig/openh264.pc" || { echo "ERROR: openh264.pc not produced" >&2; exit 1; }
echo "==> [$TAG] OK: $prefix"
