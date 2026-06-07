echo "Загрузка paranoia-server"
sudo -n true

GITHUB_REPO="ParanoiaMesseger/Paranoia"
BINARY_NAME="paranoia"
INSTALL_DIR="/opt/Paranoia/"

# --- Определение архитектуры ---
detect_arch() {
    local machine
    machine=$(uname -m)
    case "$machine" in
        x86_64)             echo "amd64" ;;
        aarch64 | arm64)    echo "arm64" ;;
        armv7l | armhf)     echo "armhf" ;;
        *)
            echo "Unsupported architecture: $machine" >&2
            exit 1
            ;;
    esac
}

ARCH=$(detect_arch)
ASSET_NAME="${BINARY_NAME}-${ARCH}"

echo "Detected architecture: $ARCH"
echo "Looking for asset: $ASSET_NAME"

# --- Получение последнего релиза через GitHub API ---
API_URL="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"

echo "Fetching latest release..."
RELEASE_JSON=$(curl -fsSL -H "Accept: application/vnd.github+json" "$API_URL")

# JSON парсим через python3 (GitHub ставит пробел после ':', grep ненадёжен).
LATEST_TAG=$(printf '%s' "$RELEASE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tag_name',''))")

if [ -z "$LATEST_TAG" ]; then
    echo "Failed to fetch latest release tag" >&2
    exit 1
fi

echo "Latest release: $LATEST_TAG"

# --- Формирование URL скачивания ---
# GitHub отдаёт ассеты по предсказуемому пути releases/download/<tag>/<asset>.
DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/${LATEST_TAG}/${ASSET_NAME}"

echo "Downloading from: $DOWNLOAD_URL"

TMP_FILE=$(mktemp)
trap 'rm -f "$TMP_FILE"' EXIT

HTTP_CODE=$(curl -fsSL -w "%{http_code}" -o "$TMP_FILE" "$DOWNLOAD_URL")

if [ "$HTTP_CODE" != "200" ]; then
    echo "Download failed (HTTP $HTTP_CODE)" >&2

    # Фолбэк: найти browser_download_url нужного ассета в JSON релиза.
    echo "Trying release assets API..."
    ASSET_URL=$(printf '%s' "$RELEASE_JSON" | python3 -c "
import json,sys
rel=json.load(sys.stdin)
name='$ASSET_NAME'
for a in rel.get('assets',[]):
    if name in a.get('name',''):
        print(a.get('browser_download_url','')); break
")

    if [ -z "$ASSET_URL" ]; then
        echo "Asset '$ASSET_NAME' not found in release $LATEST_TAG" >&2
        exit 1
    fi

    echo "Found asset URL: $ASSET_URL"
    curl -fsSL -o "$TMP_FILE" "$ASSET_URL"
fi

# --- Установка ---
sudo chmod +x "$TMP_FILE"

if [ -w "$INSTALL_DIR" ]; then
    mv "$TMP_FILE" "${INSTALL_DIR}/${BINARY_NAME}"
else
    sudo mv "$TMP_FILE" "${INSTALL_DIR}/${BINARY_NAME}"
fi

echo "Installed: ${INSTALL_DIR}/${BINARY_NAME}"
${INSTALL_DIR}/${BINARY_NAME} --version 2>/dev/null || true
