#!/usr/bin/env bash
set -euo pipefail

# ─── Пути ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QT_VERSION="6.10.1"
QT_DIR="$HOME/.qt"
QT_LINUX_INSTALL_DIR="gcc_64"
QT_ANDROID_ARCH="android_arm64_v8a"
ANDROID_NDK_VERSION="27.2.12479018"
ANDROID_SDK_ROOT="$HOME/.android/sdk"
ANDROID_NDK_ROOT="$ANDROID_SDK_ROOT/ndk/$ANDROID_NDK_VERSION"
CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
BINARY_NAME="paranoia"

# ─── Переменные подписи (заполни реальными данными) ───────────────────────────
# ─── Переменные подписи из /opt/apk_keys/keys ─────────────────────────────────
KEYS_FILE="/opt/apk_keys/keys"
if [ ! -f "$KEYS_FILE" ]; then
  echo "ERROR: Файл с ключами не найден: $KEYS_FILE"
  exit 1
fi
source "$KEYS_FILE"

# ─── Окружение ────────────────────────────────────────────────────────────────
export PATH="$CARGO_HOME/bin:$PATH"
export JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"

echo "==> Проверка инструментов..."
rustc --version && cargo --version
cmake --version | head -1
ninja --version
java -version 2>&1 | head -1

# ─── Сборка ───────────────────────────────────────────────────────────────────
echo "==> Конфигурация CMake..."
cmake -B "$SCRIPT_DIR/build_android" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$QT_DIR/$QT_VERSION/$QT_ANDROID_ARCH/lib/cmake/Qt6/qt.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-24 \
  -DANDROID_STL=c++_shared \
  -DANDROID_SDK_ROOT="$ANDROID_SDK_ROOT" \
  -DANDROID_NDK_ROOT="$ANDROID_NDK_ROOT" \
  -DCMAKE_PREFIX_PATH="$QT_DIR/$QT_VERSION/$QT_ANDROID_ARCH" \
  -DQT_HOST_PATH="$QT_DIR/$QT_VERSION/$QT_LINUX_INSTALL_DIR" \
  -DPARANOIA_CARGO_TARGET=aarch64-linux-android \
  "$SCRIPT_DIR/ParanoiaUiClient/"

echo "==> Сборка APK..."
cmake --build "$SCRIPT_DIR/build_android" --target apk --parallel

# ─── Поиск unsigned APK ───────────────────────────────────────────────────────
UNSIGNED_APK=$(find "$SCRIPT_DIR/build_android" -path "*/outputs/apk/release/*-release-unsigned.apk" -type f -print -quit || true)
if [ -z "$UNSIGNED_APK" ]; then
  UNSIGNED_APK=$(find "$SCRIPT_DIR/build_android" -path "*/outputs/apk/release/*.apk" -type f -print -quit || true)
fi
test -n "$UNSIGNED_APK" || { echo "ERROR: Unsigned APK не найден после сборки"; exit 1; }
echo "==> Найден unsigned APK: $UNSIGNED_APK"

# ─── Подпись APK ─────────────────────────────────────────────────────────────
BUILD_TOOLS_DIR="$ANDROID_SDK_ROOT/build-tools/35.0.0"
ZIPALIGN="$BUILD_TOOLS_DIR/zipalign"
APKSIGNER="$BUILD_TOOLS_DIR/apksigner"
SIGNED_APK="$SCRIPT_DIR/build_android/${BINARY_NAME}-android-arm64.apk"
ALIGNED_APK="${UNSIGNED_APK%.apk}-aligned.apk"

test -x "$ZIPALIGN" || { echo "ERROR: zipalign не найден: $ZIPALIGN"; exit 1; }
test -x "$APKSIGNER" || { echo "ERROR: apksigner не найден: $APKSIGNER"; exit 1; }

rm -f "$SIGNED_APK" "$ALIGNED_APK"
"$ZIPALIGN" -f -p 4 "$UNSIGNED_APK" "$ALIGNED_APK"

if [ -n "$ANDROID_KEYSTORE_BASE64" ]; then
  echo "==> Подпись release keystore..."
  test -n "$ANDROID_KEYSTORE_PASSWORD" || { echo "ERROR: ANDROID_KEYSTORE_PASSWORD пустой"; exit 1; }
  test -n "$ANDROID_KEY_ALIAS"         || { echo "ERROR: ANDROID_KEY_ALIAS пустой"; exit 1; }
  test -n "$ANDROID_KEY_PASSWORD"      || { echo "ERROR: ANDROID_KEY_PASSWORD пустой"; exit 1; }

  KEYSTORE_FILE="$SCRIPT_DIR/android-release.keystore"
  printf '%s' "$ANDROID_KEYSTORE_BASE64" | base64 -d > "$KEYSTORE_FILE"
  "$APKSIGNER" sign \
    --ks "$KEYSTORE_FILE" --ks-key-alias "$ANDROID_KEY_ALIAS" \
    --ks-pass "pass:$ANDROID_KEYSTORE_PASSWORD" --key-pass "pass:$ANDROID_KEY_PASSWORD" \
    --v1-signing-enabled true --v2-signing-enabled true --v3-signing-enabled true \
    --out "$SIGNED_APK" "$ALIGNED_APK"
  rm -f "$KEYSTORE_FILE"
else
  echo "==> ANDROID_KEYSTORE_BASE64 не задан — используется debug keystore..."
  DEBUG_KEYSTORE="$SCRIPT_DIR/android-debug.keystore"
  keytool -genkeypair -v -keystore "$DEBUG_KEYSTORE" -storepass android -alias androiddebugkey \
    -keypass android -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=Android Debug,O=Android,C=US"
  "$APKSIGNER" sign \
    --ks "$DEBUG_KEYSTORE" --ks-key-alias androiddebugkey \
    --ks-pass pass:android --key-pass pass:android \
    --v1-signing-enabled true --v2-signing-enabled true --v3-signing-enabled true \
    --out "$SIGNED_APK" "$ALIGNED_APK"
fi

"$APKSIGNER" verify --verbose "$SIGNED_APK"
echo ""
echo "✅  Готово: $SIGNED_APK"