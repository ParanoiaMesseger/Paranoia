#!/usr/bin/env bash
# Cross-compile minimal FFmpeg for iOS and place artifacts into
# ParanoiaUiClient/deps/ffmpeg/ios-<arch> or iossim-<arch>.

set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
    echo "ERROR: this script requires macOS/Xcode" >&2
    exit 1
fi

FFMPEG_VERSION="${FFMPEG_VERSION:-7.1.2}"
FFMPEG_TARBALL_URL="${FFMPEG_TARBALL_URL:-https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz}"
FFMPEG_IOS_ARCHS="${FFMPEG_IOS_ARCHS:-arm64}"
FFMPEG_IOS_SDK="${FFMPEG_IOS_SDK:-iphoneos}"
IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"
FFMPEG_IOS_CONFIG_ID="${FFMPEG_IOS_CONFIG_ID:-ffmpeg-${FFMPEG_VERSION}-ios-h264-videotoolbox-avfilter-transcode1-20260617}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARANOIA_ROOT="${PARANOIA_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
OUT_DIR="${OUT_DIR:-$PARANOIA_ROOT/ParanoiaUiClient/deps/ffmpeg}"
FFMPEG_WORK_DIR="${FFMPEG_WORK_DIR:-$OUT_DIR/.build}"

SDK_PATH="$(xcrun --sdk "$FFMPEG_IOS_SDK" --show-sdk-path 2>/dev/null || true)"
if [ -z "$SDK_PATH" ]; then
    echo "ERROR: xcrun did not find SDK '$FFMPEG_IOS_SDK'" >&2
    exit 1
fi

CLANG_BIN="$(xcrun --sdk "$FFMPEG_IOS_SDK" --find clang)"
AR_BIN="$(xcrun --sdk "$FFMPEG_IOS_SDK" --find ar)"
RANLIB_BIN="$(xcrun --sdk "$FFMPEG_IOS_SDK" --find ranlib)"
STRIP_BIN="$(xcrun --sdk "$FFMPEG_IOS_SDK" --find strip)"
NM_BIN="$(xcrun --sdk "$FFMPEG_IOS_SDK" --find nm)"

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

ios_arch_name() {
    case "$1" in
        arm64)  echo "aarch64" ;;
        x86_64) echo "x86_64" ;;
        *) echo "" ;;
    esac
}


build_one_arch() {
    local arch="$1"
    local ff_arch
    ff_arch="$(ios_arch_name "$arch")"
    if [ -z "$ff_arch" ]; then
        echo "WARN: unsupported iOS arch '$arch' — skip" >&2
        return
    fi

    local out_subdir="ios-${arch}"
    local min_flag="-mios-version-min=$IPHONEOS_DEPLOYMENT_TARGET"
    if [ "$FFMPEG_IOS_SDK" = "iphonesimulator" ]; then
        out_subdir="iossim-${arch}"
        min_flag="-mios-simulator-version-min=$IPHONEOS_DEPLOYMENT_TARGET"
    fi
    local prefix="$OUT_DIR/$out_subdir"
    local config_stamp="$prefix/.paranoia-ffmpeg-ios-config"

    if [ "$FORCE_REBUILD" != "1" ] \
       && [ -f "$prefix/lib/libavcodec.a" ] \
       && [ -f "$prefix/lib/libavutil.a" ] \
       && [ -f "$prefix/lib/libswscale.a" ] \
       && [ -f "$prefix/lib/libavfilter.a" ] \
       && [ -f "$prefix/include/libavcodec/avcodec.h" ] \
       && [ -f "$prefix/include/libavfilter/avfilter.h" ] \
       && [ -f "$config_stamp" ] \
       && grep -Fxq "$FFMPEG_IOS_CONFIG_ID|sdk=$FFMPEG_IOS_SDK|arch=$arch|deployment=$IPHONEOS_DEPLOYMENT_TARGET" "$config_stamp"; then
        echo "==> [$out_subdir] FFmpeg already built — skip"
        return
    fi

    echo "==> [$out_subdir] building FFmpeg"
    local builddir="$FFMPEG_WORK_DIR/build-$out_subdir"
    rm -rf "$builddir"
    mkdir -p "$builddir"

    local common_flags="-arch $arch -isysroot $SDK_PATH $min_flag -O3 -fPIC"
    # h264_videotoolbox присутствует в FFmpeg начиная с 3.x — проверка не нужна.
    local videotoolbox_args=(--enable-videotoolbox --enable-encoder=h264_videotoolbox)
    (
        cd "$builddir"
        "$SRCDIR/configure" \
            --prefix="$prefix" \
            --target-os=darwin \
            --arch="$ff_arch" \
            --cc="$CLANG_BIN" \
            --ar="$AR_BIN" \
            --ranlib="$RANLIB_BIN" \
            --strip="$STRIP_BIN" \
            --nm="$NM_BIN" \
            --enable-cross-compile \
            --sysroot="$SDK_PATH" \
            --enable-static \
            --disable-shared \
            --enable-pic \
            --disable-programs \
            --disable-doc \
            --disable-autodetect \
            --disable-avdevice \
            --disable-postproc \
            --disable-network \
            --disable-everything \
            --enable-avcodec \
            --enable-avutil \
            --enable-swscale \
            --enable-avfilter \
            --enable-avformat \
            --enable-swresample \
            --enable-filter=buffer \
            --enable-filter=buffersink \
            --enable-filter=transpose \
            --enable-filter=vflip \
            --enable-filter=hflip \
            --enable-filter=scale \
            --enable-filter=format \
            --enable-filter=pad \
            --enable-filter=null \
            --enable-decoder=h264 \
            --enable-parser=h264 \
            --enable-protocol=file \
            --enable-demuxer=mov \
            --enable-demuxer=matroska \
            --enable-muxer=mp4 \
            --enable-muxer=mov \
            --enable-decoder=hevc \
            --enable-decoder=mpeg4 \
            --enable-decoder=vp8 \
            --enable-decoder=vp9 \
            --enable-parser=hevc \
            --enable-parser=vp8 \
            --enable-parser=vp9 \
            --enable-parser=mpeg4video \
            --enable-decoder=aac \
            --enable-decoder=mp3 \
            --enable-decoder=opus \
            --enable-decoder=vorbis \
            --enable-decoder=ac3 \
            --enable-decoder=pcm_s16le \
            --enable-parser=aac \
            --enable-parser=opus \
            --enable-encoder=aac \
            --enable-bsf=aac_adtstoasc \
            --enable-bsf=h264_mp4toannexb \
            --enable-bsf=hevc_mp4toannexb \
            --enable-bsf=extract_extradata \
            "${videotoolbox_args[@]}" \
            --extra-cflags="$common_flags" \
            --extra-ldflags="-arch $arch -isysroot $SDK_PATH $min_flag"
        make -j"$(sysctl -n hw.ncpu)"
        rm -rf "$prefix"
        mkdir -p "$prefix"
        make install
    )

    if [ ! -f "$prefix/lib/libavcodec.a" ] \
       || [ ! -f "$prefix/lib/libavutil.a" ] \
       || [ ! -f "$prefix/lib/libswscale.a" ] \
       || [ ! -f "$prefix/lib/libavfilter.a" ] \
       || [ ! -f "$prefix/lib/libavformat.a" ] \
       || [ ! -f "$prefix/lib/libswresample.a" ] \
       || [ ! -f "$prefix/include/libavcodec/avcodec.h" ] \
       || [ ! -f "$prefix/include/libavfilter/avfilter.h" ]; then
        echo "ERROR: FFmpeg install for $out_subdir did not produce expected files" >&2
        exit 1
    fi
    printf '%s|sdk=%s|arch=%s|deployment=%s\n' \
        "$FFMPEG_IOS_CONFIG_ID" "$FFMPEG_IOS_SDK" "$arch" "$IPHONEOS_DEPLOYMENT_TARGET" > "$config_stamp"
    echo "==> [$out_subdir] OK: $prefix"
}

for arch in $FFMPEG_IOS_ARCHS; do
    build_one_arch "$arch"
done

echo "==> FFmpeg iOS artifacts ready."
