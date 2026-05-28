#!/usr/bin/env bash
# Cross-compile minimal FFmpeg for Android ABI and place artifacts into
# ParanoiaUiClient/deps/ffmpeg/<abi>/{include,lib}. This is the layout consumed
# by ParanoiaUiClient/CMakeLists.txt for PARANOIA_HAS_FFMPEG/PARANOIA_HAS_VIDEO.
#
# Usage:
#   ANDROID_NDK_ROOT=/path/to/ndk \
#   FFMPEG_ABIS="arm64-v8a" \
#   ./scripts/build_ffmpeg_android.sh
#
# Env variables:
#   FFMPEG_VERSION                  default 7.1.2
#   FFMPEG_TARBALL_URL              override source tarball URL
#   FFMPEG_ABIS                     ABI list, default "arm64-v8a"
#   FFMPEG_API_LEVEL                Android API level, default 24
#   FFMPEG_ANDROID_ENABLE_MEDIACODEC default 1, enables MediaCodec decode support
#   PARANOIA_ROOT                   repository root
#   OUT_DIR                         default $PARANOIA_ROOT/ParanoiaUiClient/deps/ffmpeg
#   FFMPEG_WORK_DIR                 source/build cache directory
#   FORCE_REBUILD                   "1" to rebuild even when artifacts exist

set -euo pipefail

FFMPEG_VERSION="${FFMPEG_VERSION:-7.1.2}"
FFMPEG_TARBALL_URL="${FFMPEG_TARBALL_URL:-https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz}"
FFMPEG_ABIS="${FFMPEG_ABIS:-arm64-v8a}"
FFMPEG_API_LEVEL="${FFMPEG_API_LEVEL:-24}"
FFMPEG_ANDROID_ENABLE_MEDIACODEC="${FFMPEG_ANDROID_ENABLE_MEDIACODEC:-1}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARANOIA_ROOT="${PARANOIA_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
OUT_DIR="${OUT_DIR:-$PARANOIA_ROOT/ParanoiaUiClient/deps/ffmpeg}"
FFMPEG_WORK_DIR="${FFMPEG_WORK_DIR:-$OUT_DIR/.build}"

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

mkdir -p "$FFMPEG_WORK_DIR"

TARBALL="$FFMPEG_WORK_DIR/ffmpeg-${FFMPEG_VERSION}.tar.xz"
SRCDIR="$FFMPEG_WORK_DIR/ffmpeg-${FFMPEG_VERSION}"

if [ ! -f "$TARBALL" ]; then
    echo "==> Downloading FFmpeg ${FFMPEG_VERSION}..."
    curl --proto '=https' --tlsv1.2 -fsSL "$FFMPEG_TARBALL_URL" -o "$TARBALL.partial"
    mv "$TARBALL.partial" "$TARBALL"
fi

if [ ! -d "$SRCDIR" ]; then
    echo "==> Extracting FFmpeg ${FFMPEG_VERSION}..."
    tar -xf "$TARBALL" -C "$FFMPEG_WORK_DIR"
fi

jobs_count() {
    if command -v nproc >/dev/null 2>&1; then
        nproc
    else
        sysctl -n hw.ncpu
    fi
}

ffmpeg_has_list_entry() {
    local list_name="$1"
    local entry="$2"
    "$SRCDIR/configure" "--list-${list_name}" | grep -qx "$entry"
}

abi_params() {
    case "$1" in
        arm64-v8a)    echo "aarch64 armv8-a aarch64-linux-android" ;;
        armeabi-v7a)  echo "arm armv7-a armv7a-linux-androideabi" ;;
        x86_64)       echo "x86_64 x86_64 x86_64-linux-android" ;;
        x86)          echo "x86 i686 i686-linux-android" ;;
        *) echo "" ;;
    esac
}

build_one_abi() {
    local abi="$1"
    local params
    params="$(abi_params "$abi")"
    if [ -z "$params" ]; then
        echo "WARN: unknown ABI '$abi' — skip" >&2
        return
    fi

    set -- $params
    local arch="$1"
    local cpu="$2"
    local target="$3"
    local prefix="$OUT_DIR/$abi"

    # Sentinel: фиксируем, был ли openh264 закомпилен в FFmpeg в прошлый раз.
    # Если openh264 prebuilt появился/обновился, а FFmpeg кэш собран без него —
    # форсим пересборку, иначе мы продолжим выдавать «no usable encoder».
    local sentinel="$prefix/.paranoia-build-id"
    local openh264_prefix_pre="$PARANOIA_ROOT/ParanoiaUiClient/deps/openh264/$abi"
    local openh264_hash="none"
    if [ -f "$openh264_prefix_pre/lib/libopenh264.a" ]; then
        openh264_hash="$(sha256sum "$openh264_prefix_pre/lib/libopenh264.a" 2>/dev/null | awk '{print $1}' | head -c 16)"
    fi
    local current_id="ffmpeg=$FFMPEG_VERSION openh264=$openh264_hash"
    if [ "$FORCE_REBUILD" != "1" ] \
       && [ -f "$prefix/lib/libavcodec.a" ] \
       && [ -f "$prefix/lib/libavutil.a" ] \
       && [ -f "$prefix/lib/libswscale.a" ] \
       && [ -f "$prefix/include/libavcodec/avcodec.h" ] \
       && [ -f "$sentinel" ] \
       && [ "$(cat "$sentinel" 2>/dev/null)" = "$current_id" ]; then
        echo "==> [$abi] FFmpeg already built — skip"
        return
    fi
    if [ -f "$prefix/lib/libavcodec.a" ]; then
        echo "==> [$abi] FFmpeg cache invalidated (build id changed); rebuilding"
    fi

    local cc_bin="$TOOLCHAIN/bin/${target}${FFMPEG_API_LEVEL}-clang"
    local cxx_bin="$TOOLCHAIN/bin/${target}${FFMPEG_API_LEVEL}-clang++"
    if [ ! -x "$cc_bin" ]; then
        echo "ERROR: clang for $target was not found: $cc_bin" >&2
        exit 1
    fi

    echo "==> [$abi] building FFmpeg (arch=$arch target=$target)"
    local builddir="$FFMPEG_WORK_DIR/build-$abi"
    rm -rf "$builddir"
    mkdir -p "$builddir"

    local media_codec_args=()
    if [ "$FFMPEG_ANDROID_ENABLE_MEDIACODEC" = "1" ]; then
        media_codec_args=(
            --enable-jni
            --enable-mediacodec
        )
        if ffmpeg_has_list_entry decoders h264_mediacodec; then
            media_codec_args+=(--enable-decoder=h264_mediacodec)
        fi
        if ffmpeg_has_list_entry encoders h264_mediacodec; then
            media_codec_args+=(--enable-encoder=h264_mediacodec)
        else
            echo "WARN: FFmpeg ${FFMPEG_VERSION} has no h264_mediacodec encoder; will rely on libopenh264 for Android encode" >&2
        fi
    fi

    # OpenH264 (BSD H.264 encoder/decoder) — обязательный software encoder для
    # Android, потому что у FFmpeg нет встроенного h264 encoder'а, а libx264
    # под GPL. Скрипт build_openh264_android.sh кладёт артефакты сюда:
    local openh264_prefix="$PARANOIA_ROOT/ParanoiaUiClient/deps/openh264/$abi"
    local openh264_args=()
    local extra_cflags="-O3 -fPIC"
    local extra_ldflags=""
    local extra_libs=""
    if [ -f "$openh264_prefix/lib/libopenh264.a" ]; then
        echo "==> [$abi] including OpenH264 from $openh264_prefix"
        openh264_args=(
            --enable-libopenh264
            --enable-encoder=libopenh264
            --enable-decoder=libopenh264
        )
        extra_cflags="$extra_cflags -I$openh264_prefix/include"
        extra_ldflags="-L$openh264_prefix/lib"
        # libopenh264 is C++; its C++ runtime is pulled in at APK link time by
        # the NDK toolchain (libc++_shared, configured via ANDROID_STL). Не
        # передаём -lstdc++ здесь: в Android NDK его нет, и FFmpeg configure
        # упадёт на sanity-check.
        extra_libs="-lm"
    else
        echo "WARN: OpenH264 prebuilt not found at $openh264_prefix — H.264 encoding will be unavailable on $abi" >&2
        echo "      Run scripts/build_openh264_android.sh first." >&2
    fi

    (
        cd "$builddir"
        # --pkg-config-flags=--static: FFmpeg should link against the static
        # openh264.a we built, not look for shared libs (which don't exist).
        local configure_args=(
            --prefix="$prefix"
            --target-os=android
            --arch="$arch"
            --cpu="$cpu"
            --cc="$cc_bin"
            --cxx="$cxx_bin"
            --ar="$TOOLCHAIN/bin/llvm-ar"
            --ranlib="$TOOLCHAIN/bin/llvm-ranlib"
            --strip="$TOOLCHAIN/bin/llvm-strip"
            --nm="$TOOLCHAIN/bin/llvm-nm"
            --enable-cross-compile
            --sysroot="$TOOLCHAIN/sysroot"
            --enable-static
            --disable-shared
            --disable-programs
            --disable-doc
            --disable-autodetect
            --disable-avdevice
            --disable-avformat
            --disable-swresample
            --disable-postproc
            --disable-network
            --disable-everything
            --enable-avcodec
            --enable-avutil
            --enable-swscale
            --enable-avfilter
            # Минимальный набор фильтров для видео-pipeline'а звонков:
            #   buffer/buffersink — вход/выход графа
            #   transpose         — повороты 90°/270°
            #   vflip/hflip       — флипы (для mirrored-камеры)
            #   scale             — масштабирование
            #   format            — преобразование пиксельных форматов (NV12/NV21 → YUV420P)
            #   pad               — letterbox чёрными полосами при не-совпадении aspect ratio
            #   null              — обязателен для linking филтр-graph'а
            --enable-filter=buffer
            --enable-filter=buffersink
            --enable-filter=transpose
            --enable-filter=vflip
            --enable-filter=hflip
            --enable-filter=scale
            --enable-filter=format
            --enable-filter=pad
            --enable-filter=null
            --enable-decoder=h264
            --enable-parser=h264
            --extra-cflags="$extra_cflags"
            --pkg-config-flags=--static
        )
        if [ -n "$extra_ldflags" ]; then
            configure_args+=(--extra-ldflags="$extra_ldflags")
        fi
        if [ -n "$extra_libs" ]; then
            configure_args+=(--extra-libs="$extra_libs")
        fi
        # Point pkg-config at the OpenH264 prefix so --enable-libopenh264 finds it.
        # FFmpeg configure запускает subshell'ы — inline `VAR=val cmd` до них не
        # доходит, нужен export.
        export PKG_CONFIG_PATH="$openh264_prefix/lib/pkgconfig"
        export PKG_CONFIG_LIBDIR="$openh264_prefix/lib/pkgconfig"
        "$SRCDIR/configure" \
            "${configure_args[@]}" \
            "${openh264_args[@]}" \
            "${media_codec_args[@]}"
        make -j"$(jobs_count)"
        rm -rf "$prefix"
        mkdir -p "$prefix"
        make install
    )

    if [ ! -f "$prefix/lib/libavcodec.a" ] \
       || [ ! -f "$prefix/lib/libavutil.a" ] \
       || [ ! -f "$prefix/lib/libswscale.a" ] \
       || [ ! -f "$prefix/lib/libavfilter.a" ] \
       || [ ! -f "$prefix/include/libavcodec/avcodec.h" ] \
       || [ ! -f "$prefix/include/libavfilter/avfilter.h" ]; then
        echo "ERROR: FFmpeg install for $abi did not produce expected files" >&2
        exit 1
    fi
    echo "$current_id" > "$sentinel"
    echo "==> [$abi] OK: $prefix"
}

for abi in $FFMPEG_ABIS; do
    build_one_abi "$abi"
done

echo "==> FFmpeg artifacts ready:"
for abi in $FFMPEG_ABIS; do
    [ -f "$OUT_DIR/$abi/lib/libavcodec.a" ] && echo "    - $OUT_DIR/$abi"
done
