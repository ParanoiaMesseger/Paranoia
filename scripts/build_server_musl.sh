#!/usr/bin/env bash
# Статическая musl-сборка сервера (ParanoiaServer) под заданную арку.
# Запускается в образе ci-linux-musl (см. ci/docker/ci-linux-musl.Dockerfile):
# musl-cross тулчейны лежат в /opt/musl, хост-libclang для bindgen — в образе.
#
# Результат — ПОЛНОСТЬЮ статический бинарь (без PT_INTERP, без glibc), который
# запускается на любом Linux: старый/новый glibc и musl (Alpine).
#
# Usage:  scripts/build_server_musl.sh <amd64|arm64|armhf> [out_dir]
#
# Env:
#   MUSL_ROOT   корень с musl-cross тулчейнами (default /opt/musl)
#   BINARY_NAME имя бинаря (default paranoia)
set -euo pipefail

ARCH="${1:?usage: build_server_musl.sh <amd64|arm64|armhf> [out_dir]}"
OUT_DIR="${2:-$(pwd)/release}"
MUSL_ROOT="${MUSL_ROOT:-/opt/musl}"
BINARY_NAME="${BINARY_NAME:-paranoia}"

case "$ARCH" in
  amd64) RUST_TARGET=x86_64-unknown-linux-musl;      MUSL_CROSS=x86_64-linux-musl-cross;       PREFIX=x86_64-linux-musl;       CLANG_TARGET=x86_64-linux-musl ;;
  arm64) RUST_TARGET=aarch64-unknown-linux-musl;     MUSL_CROSS=aarch64-linux-musl-cross;      PREFIX=aarch64-linux-musl;      CLANG_TARGET=aarch64-linux-musl ;;
  armhf) RUST_TARGET=armv7-unknown-linux-musleabihf; MUSL_CROSS=armv7l-linux-musleabihf-cross; PREFIX=armv7l-linux-musleabihf; CLANG_TARGET=armv7-linux-musleabihf ;;
  *) echo "ERROR: unknown arch '$ARCH' (amd64|arm64|armhf)" >&2; exit 1 ;;
esac

SYSROOT="$MUSL_ROOT/$MUSL_CROSS/$PREFIX"
export PATH="$MUSL_ROOT/$MUSL_CROSS/bin:$PATH"
test -x "$MUSL_ROOT/$MUSL_CROSS/bin/${PREFIX}-g++" || {
    echo "ERROR: musl toolchain not found: $MUSL_ROOT/$MUSL_CROSS" >&2; exit 1; }

# Линкер + статический crt — задаём ТОЛЬКО для target (не для host build-script).
ENVT="$(echo "$RUST_TARGET" | tr 'a-z-' 'A-Z_')"
export CARGO_TARGET_${ENVT}_LINKER="${PREFIX}-gcc"
# armv7: libstdc++ ссылается на legacy __sync_* (__sync_synchronize,
# __sync_val_compare_and_swap_4), которых нет в Rust compiler_builtins — берём из
# libgcc (-lgcc). libgcc при этом дублирует те __sync_*, что в compiler_builtins
# есть → разрешаем --allow-multiple-definition (для атомиков обе версии
# эквивалентны). На arm64/amd64 эти builtin'ы инлайнятся, ничего не нужно.
EXTRA_RF=""
[ "$ARCH" = "armhf" ] && EXTRA_RF=" -C link-arg=-lgcc -C link-arg=-Wl,--allow-multiple-definition"
export CARGO_TARGET_${ENVT}_RUSTFLAGS="-C target-feature=+crt-static${EXTRA_RF}"
# C/C++ для librocksdb-sys (крейт cc читает CC_<target>/CXX_<target>, '-'→'_').
ENVT_L="$(echo "$RUST_TARGET" | tr '-' '_')"
export CC_${ENVT_L}="${PREFIX}-gcc"
export CXX_${ENVT_L}="${PREFIX}-g++"
export AR_${ENVT_L}="${PREFIX}-ar"
# bindgen парсит заголовки ЦЕЛИ хост-libclang'ом — даём target + sysroot тулчейна.
export BINDGEN_EXTRA_CLANG_ARGS="--target=${CLANG_TARGET} --sysroot=${SYSROOT}"

echo "==> [$ARCH] cargo build --release --target $RUST_TARGET"
( cd "$(dirname "$0")/../ParanoiaServer" && cargo build --locked --release --target "$RUST_TARGET" )

SRC_BIN="$(cd "$(dirname "$0")/.." && pwd)/ParanoiaServer/target/$RUST_TARGET/release/$BINARY_NAME"
# CARGO_TARGET_DIR может быть переопределён в CI — учитываем.
if [ -n "${CARGO_TARGET_DIR:-}" ]; then
    SRC_BIN="$CARGO_TARGET_DIR/$RUST_TARGET/release/$BINARY_NAME"
fi
test -f "$SRC_BIN" || { echo "ERROR: binary not found: $SRC_BIN" >&2; exit 1; }

mkdir -p "$OUT_DIR"
cp "$SRC_BIN" "$OUT_DIR/${BINARY_NAME}-${ARCH}"
echo "==> [$ARCH] OK → $OUT_DIR/${BINARY_NAME}-${ARCH}"
