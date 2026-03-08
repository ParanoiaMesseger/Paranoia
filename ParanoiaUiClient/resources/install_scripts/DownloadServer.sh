echo "Загрузка paranoia-server"
sudo -n true

GITLAB_HOST="https://github.com"
PROJECT_PATH="ParanoiaMesseger/Paranoia"
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

# --- Получение последнего тега релиза через GitLab API ---
PROJECT_ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$PROJECT_PATH', safe=''))")
API_URL="${GITLAB_HOST}/api/v4/projects/${PROJECT_ENCODED}/releases"

echo "Fetching latest release..."
RELEASE_JSON=$(curl -fsSL "$API_URL")

LATEST_TAG=$(echo "$RELEASE_JSON" | grep -o '"tag_name":"[^"]*"' | head -1 | cut -d'"' -f4)

if [ -z "$LATEST_TAG" ]; then
    echo "Failed to fetch latest release tag" >&2
    exit 1
fi

echo "Latest release: $LATEST_TAG"

# --- Формирование URL скачивания ---
# GitLab хранит артефакты релиза по следующему пути:
DOWNLOAD_URL="${GITLAB_HOST}/${PROJECT_PATH}/-/releases/${LATEST_TAG}/downloads/${ASSET_NAME}"

echo "Downloading from: $DOWNLOAD_URL"

TMP_FILE=$(mktemp)
trap 'rm -f "$TMP_FILE"' EXIT

HTTP_CODE=$(curl -fsSL -w "%{http_code}" -o "$TMP_FILE" "$DOWNLOAD_URL")

if [ "$HTTP_CODE" != "200" ]; then
    echo "Download failed (HTTP $HTTP_CODE)" >&2

    # Фолбэк: поискать ссылку в links релиза
    echo "Trying release links API..."
    LINKS_URL="${GITLAB_HOST}/api/v4/projects/${PROJECT_ENCODED}/releases/${LATEST_TAG}/assets/links"
    ASSET_URL=$(curl -fsSL "$LINKS_URL" | grep -o '"url":"[^"]*'"$ASSET_NAME"'[^"]*"' | head -1 | cut -d'"' -f4)

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
