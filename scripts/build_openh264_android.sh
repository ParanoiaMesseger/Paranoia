#!/usr/bin/env bash
# Cross-compile Cisco OpenH264 (BSD) for Android ABI(s) and place artifacts
# into ParanoiaUiClient/deps/openh264/<abi>/{include,lib}. This is the layout
# consumed by the FFmpeg build script (--enable-libopenh264) and by CMake when
# linking the Paranoia binary.
#
# Why OpenH264: FFmpeg has no built-in H.264 software encoder (GPL + patents).
# libx264 is GPL — incompatible with our usage. OpenH264 is BSD-licensed and
# Cisco even sponsors the patent license, so it's the standard pick for
# Android/iOS H.264 encoding.
#
# Usage:
#   ANDROID_NDK_ROOT=/path/to/ndk \
#   OPENH264_ABIS="arm64-v8a" \
#   ./scripts/build_openh264_android.sh
#
# Env:
#   OPENH264_VERSION       default 2.4.1
#   OPENH264_TARBALL_URL   override source tarball URL
#   OPENH264_ABIS          ABI list, default "arm64-v8a"
#   OPENH264_API_LEVEL     Android API level, default 24
#   PARANOIA_ROOT          repository root
#   OUT_DIR                default $PARANOIA_ROOT/ParanoiaUiClient/deps/openh264
#   OPENH264_WORK_DIR      source/build cache directory
#   FORCE_REBUILD          "1" to rebuild even when artifacts exist

set -euo pipefail

OPENH264_VERSION="${OPENH264_VERSION:-2.4.1}"
OPENH264_TARBALL_URL="${OPENH264_TARBALL_URL:-https://github.com/cisco/openh264/archive/refs/tags/v${OPENH264_VERSION}.tar.gz}"
OPENH264_ABIS="${OPENH264_ABIS:-arm64-v8a}"
OPENH264_API_LEVEL="${OPENH264_API_LEVEL:-24}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARANOIA_ROOT="${PARANOIA_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
OUT_DIR="${OUT_DIR:-$PARANOIA_ROOT/ParanoiaUiClient/deps/openh264}"
OPENH264_WORK_DIR="${OPENH264_WORK_DIR:-$OUT_DIR/.build}"

if [ -z "${ANDROID_NDK_ROOT:-}" ]; then
    echo "ERROR: ANDROID_NDK_ROOT is not set" >&2
    exit 1
fi
if [ ! -d "$ANDROID_NDK_ROOT" ]; then
    echo "ERROR: ANDROID_NDK_ROOT does not exist: $ANDROID_NDK_ROOT" >&2
    exit 1
fi

case "$(uname -s)" in
    Linux)  HOST_TAG="linux-x86_64" ;;
    Darwin) HOST_TAG="darwin-x86_64" ;;
    *) echo "ERROR: unsupported host OS: $(uname -s)" >&2; exit 1 ;;
esac

TOOLCHAIN="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/$HOST_TAG"
if [ ! -d "$TOOLCHAIN" ]; then
    echo "ERROR: NDK toolchain was not found: $TOOLCHAIN" >&2
    exit 1
fi

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

jobs_count() {
    if command -v nproc >/dev/null 2>&1; then nproc; else sysctl -n hw.ncpu; fi
}

# OpenH264 Makefile принимает архитектуру через переменную ARCH; никаких
# отдельных «целей» под платформу у него нет — OS=android задаёт Android-ветку
# в build/platform-android.mk, ARCH — конкретный ABI.
abi_to_openh264_arch() {
    case "$1" in
        arm64-v8a)   echo "arm64" ;;
        armeabi-v7a) echo "arm" ;;
        x86_64)      echo "x86_64" ;;
        x86)         echo "x86" ;;
        *) echo "" ;;
    esac
}

build_one_abi() {
    local abi="$1"
    local arch
    arch="$(abi_to_openh264_arch "$abi")"
    if [ -z "$arch" ]; then
        echo "WARN: unknown ABI '$abi' — skip" >&2
        return
    fi
    local prefix="$OUT_DIR/$abi"
    if [ "$FORCE_REBUILD" != "1" ] \
       && [ -f "$prefix/lib/libopenh264.a" ] \
       && [ -f "$prefix/include/wels/codec_api.h" ]; then
        echo "==> [$abi] OpenH264 already built — skip"
        return
    fi

    echo "==> [$abi] building OpenH264 (arch=$arch)"
    rm -rf "$prefix"
    mkdir -p "$prefix/include" "$prefix/lib"

    (
        cd "$SRCDIR"
        local make_vars=(
            OS=android
            ARCH="$arch"
            NDKROOT="$ANDROID_NDK_ROOT"
            NDKLEVEL="$OPENH264_API_LEVEL"
            TARGET="android-${OPENH264_API_LEVEL}"
            PREFIX="$prefix"
        )
        # `make clean` чтобы не подцепить артефакты прошлого ABI.
        make clean "${make_vars[@]}" >/dev/null 2>&1 || true
        # Дефолтный target тянет decdemo/encdemo (требуют Gradle wrapper,
        # которого у нас нет). Таргет `libraries` собирает только
        # libopenh264.a + libopenh264.so без demo.
        make -j"$(jobs_count)" "${make_vars[@]}" libraries
        make "${make_vars[@]}" install-static
    )

    # Cross-check.
    if [ ! -f "$prefix/lib/libopenh264.a" ]; then
        echo "ERROR: OpenH264 install for $abi did not produce libopenh264.a" >&2
        exit 1
    fi
    if [ ! -f "$prefix/lib/pkgconfig/openh264.pc" ]; then
        echo "ERROR: OpenH264 install for $abi did not produce pkgconfig/openh264.pc" >&2
        exit 1
    fi
    # OpenH264 install-static ставит Libs.private: -lm -lstdc++.
    # У Android NDK нет libstdc++ — есть libc++_shared (через ANDROID_STL).
    # Без замены FFmpeg ./configure упадёт на проверке либы (ld не найдёт
    # libstdc++); просто удалить тоже мало — без C++ runtime sanity-check тоже
    # фейлится с unresolved operator new/__cxa_*. Подмена на -lc++_shared
    # делает FFmpeg-тест корректным, а конечный APK всё равно линкуется с
    # libc++_shared.so через ANDROID_STL=c++_shared.
    sed -i 's/-lstdc++/-lc++_shared/g' "$prefix/lib/pkgconfig/openh264.pc"
    echo "==> [$abi] OK: $prefix"
}

for abi in $OPENH264_ABIS; do
    build_one_abi "$abi"
done

echo "==> OpenH264 artifacts ready:"
for abi in $OPENH264_ABIS; do
    [ -f "$OUT_DIR/$abi/lib/libopenh264.a" ] && echo "    - $OUT_DIR/$abi"
done
