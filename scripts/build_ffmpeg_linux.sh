#!/usr/bin/env bash
# Build a minimal FFmpeg statically for desktop Linux and place artifacts into
# ParanoiaUiClient/deps/ffmpeg/linux-<arch>/{include,lib}. Mirror of
# build_ffmpeg_android.sh — same minimal config (avcodec/avutil/swscale/avfilter
# + libopenh264 + native h264 decoder + filters для нашего video-pipeline'а),
# но нативная сборка под хост, без cross-compile.
#
# Цель: вкомпилировать FFmpeg в бинарь статически, чтобы клиент не зависел от
# системного FFmpeg (на Ubuntu 22.04 это 4.4, на 24.04 — 6.x) и был переносим
# между дистрибутивами. Требует уже собранного OpenH264 (build_openh264_linux.sh).
#
# Usage:
#   ./scripts/build_openh264_linux.sh && ./scripts/build_ffmpeg_linux.sh
#
# Env:
#   FFMPEG_VERSION       default 7.1.2
#   FFMPEG_TARBALL_URL   override source tarball URL
#   PARANOIA_ROOT        repository root
#   OUT_DIR              default $PARANOIA_ROOT/ParanoiaUiClient/deps/ffmpeg
#   FFMPEG_WORK_DIR      source/build cache directory
#   FORCE_REBUILD        "1" to rebuild even when artifacts exist

set -euo pipefail

FFMPEG_VERSION="${FFMPEG_VERSION:-7.1.2}"
FFMPEG_TARBALL_URL="${FFMPEG_TARBALL_URL:-https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARANOIA_ROOT="${PARANOIA_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
OUT_DIR="${OUT_DIR:-$PARANOIA_ROOT/ParanoiaUiClient/deps/ffmpeg}"
FFMPEG_WORK_DIR="${FFMPEG_WORK_DIR:-$OUT_DIR/.build}"

case "$(uname -m)" in
    x86_64)  FF_ARCH="x86_64";  TAG="linux-x86_64" ;;
    aarch64) FF_ARCH="aarch64"; TAG="linux-aarch64" ;;
    *) echo "ERROR: unsupported host arch: $(uname -m)" >&2; exit 1 ;;
esac

OPENH264_PREFIX="$PARANOIA_ROOT/ParanoiaUiClient/deps/openh264/$TAG"
if [ ! -f "$OPENH264_PREFIX/lib/libopenh264.a" ]; then
    echo "ERROR: OpenH264 prebuilt not found at $OPENH264_PREFIX" >&2
    echo "       Run scripts/build_openh264_linux.sh first." >&2
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

jobs_count() { if command -v nproc >/dev/null 2>&1; then nproc; else echo 4; fi; }

prefix="$OUT_DIR/$TAG"
openh264_hash="$(sha256sum "$OPENH264_PREFIX/lib/libopenh264.a" | awk '{print $1}' | head -c 16)"
current_id="ffmpeg=$FFMPEG_VERSION openh264=$openh264_hash feat=transcode1"
sentinel="$prefix/.paranoia-build-id"
if [ "$FORCE_REBUILD" != "1" ] \
   && [ -f "$prefix/lib/libavcodec.a" ] \
   && [ -f "$prefix/lib/libavfilter.a" ] \
   && [ -f "$prefix/include/libavcodec/avcodec.h" ] \
   && [ -f "$sentinel" ] && [ "$(cat "$sentinel" 2>/dev/null)" = "$current_id" ]; then
    echo "==> [$TAG] FFmpeg already built — skip"
    exit 0
fi

echo "==> [$TAG] building FFmpeg (arch=$FF_ARCH) with static OpenH264"
builddir="$FFMPEG_WORK_DIR/build-$TAG"
rm -rf "$builddir"; mkdir -p "$builddir"
(
    cd "$builddir"
    configure_args=(
        --prefix="$prefix"
        --arch="$FF_ARCH"
        --enable-static
        --disable-shared
        --disable-programs
        --disable-doc
        --disable-autodetect
        --disable-avdevice
        --disable-postproc
        --disable-network
        --disable-everything
        --enable-pic
        --enable-avcodec
        --enable-avutil
        --enable-swscale
        --enable-avfilter
        # avformat + swresample нужны для ТРАНСКОДА видео-вложений (демукс
        # исходного контейнера, ремукс в mp4, ресемпл аудио в AAC). В звонках
        # они не используются (там raw NAL), но включены для VideoTranscoder.
        --enable-avformat
        --enable-swresample
        # Минимальный набор фильтров video-pipeline'а звонков (см. android-скрипт).
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
        # ── Транскод видео-вложений (только локально выбранный отправителем
        #    файл; входящее видео играет нативный плеер ОС, не наш ffmpeg) ──
        # Контейнеры-источники: mp4/mov/m4v/3gp (mov), mkv/webm (matroska).
        --enable-protocol=file
        --enable-demuxer=mov
        --enable-demuxer=matroska
        # Запись результата в mp4.
        --enable-muxer=mp4
        --enable-muxer=mov
        # Декодеры исходного видео (камеры телефонов: H.264 / HEVC; webm: vp8/9).
        --enable-decoder=hevc
        --enable-decoder=mpeg4
        --enable-decoder=vp8
        --enable-decoder=vp9
        --enable-parser=hevc
        --enable-parser=vp8
        --enable-parser=vp9
        --enable-parser=mpeg4video
        # Аудио-дорожка: декод исходной + кодирование в AAC для mp4.
        --enable-decoder=aac
        --enable-decoder=mp3
        --enable-decoder=opus
        --enable-decoder=vorbis
        --enable-decoder=ac3
        --enable-decoder=pcm_s16le
        --enable-parser=aac
        --enable-parser=opus
        --enable-encoder=aac
        # Bitstream-фильтры для корректной упаковки в mp4.
        --enable-bsf=aac_adtstoasc
        --enable-bsf=h264_mp4toannexb
        --enable-bsf=hevc_mp4toannexb
        --enable-bsf=extract_extradata
        # OpenH264 (BSD) software H.264 encoder/decoder.
        --enable-libopenh264
        --enable-encoder=libopenh264
        --enable-decoder=libopenh264
        --extra-cflags="-O3 -fPIC -I$OPENH264_PREFIX/include"
        --extra-ldflags="-L$OPENH264_PREFIX/lib"
        --pkg-config-flags=--static
    )
    export PKG_CONFIG_PATH="$OPENH264_PREFIX/lib/pkgconfig"
    "$SRCDIR/configure" "${configure_args[@]}"
    make -j"$(jobs_count)"
    rm -rf "$prefix"; mkdir -p "$prefix"
    make install
)

for f in libavcodec libavutil libswscale libavfilter libavformat libswresample; do
    test -f "$prefix/lib/$f.a" || { echo "ERROR: $f.a not produced" >&2; exit 1; }
done
test -f "$prefix/include/libavcodec/avcodec.h" || { echo "ERROR: headers missing" >&2; exit 1; }
echo "$current_id" > "$sentinel"
echo "==> [$TAG] OK: $prefix"
