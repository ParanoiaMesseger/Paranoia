//! Чтение профилей НАПРЯМУЮ из стора UI-клиента (vault), без export/import.
//!
//! UI-клиент хранит данные под `AppDataLocation`:
//!   vault.json                      — соль Argon2id + verifier (PIN)
//!   profiles/<profileId>/client.json — server/username/server_id/private_key
//!   profiles/<profileId>/dialogs.json — массив диалогов с keyring
//!   profiles/<profileId>/paranoia.db  — SQLCipher (сообщения; здесь НЕ трогаем)
//! client.json и dialogs.json зашифрованы vault'ом (Argon2id→HKDF→ChaCha20-Poly1305,
//! JSON c магией `PVL1`). Расшифровка — через `local_vault::decrypt_json_from_disk`
//! при разлоченном vault'е. Крипто-механизм тот же, что у UI, т.к. обе стороны
//! линкуют `paranoia_lib`.

use anyhow::{Context, Result, anyhow, bail};
use serde::Deserialize;
use std::path::Path;

// ── сырые структуры под JSON, который пишет UI (ParanoiaUiClient) ────────────
// Имена полей dialogs.json — camelCase (peerServerId/localName), keyring внутри
// snake_case (start_seq/key); start_seq UI пишет как JSON-число (double) → f64.

#[derive(Debug, Deserialize, Default)]
struct UiClientConfig {
    #[serde(default)]
    server: String,
    #[serde(default)]
    username: String,
    #[serde(default)]
    server_id: String,
    /// Ed25519 signing key, base64(32) — поле так и называется `private_key`.
    #[serde(default)]
    private_key: String,
    /// Резервные серверы (HTTP-fallback): UI пишет их в client.json как
    /// `reserve_server_urls`. Без них клиент ходит ТОЛЬКО на primary — и если
    /// тот недоступен, приём/отправка молча падают (см. TUI).
    #[serde(default)]
    reserve_server_urls: Vec<String>,
}

#[derive(Debug, Deserialize, Default)]
struct UiKeyEntry {
    #[serde(default)]
    start_seq: f64,
    #[serde(default)]
    key: String,
}

#[derive(Debug, Deserialize, Default)]
struct UiDialogRaw {
    #[serde(default)]
    peer: String,
    #[serde(default, rename = "peerServerId")]
    peer_server_id: String,
    #[serde(default)]
    keyring: Vec<UiKeyEntry>,
    #[serde(default, rename = "localName")]
    local_name: String,
}

// ── нормализованный результат для вызывающего ────────────────────────────────

pub struct UiDialog {
    pub peer: String,
    pub peer_server_id: String,
    pub local_name: String,
    /// (start_seq, key_b64) — только валидные (key непустой, start_seq ≥ 1).
    pub keyring: Vec<(u64, String)>,
}

pub struct UiProfile {
    pub server: String,
    pub username: String,
    pub server_id: String,
    pub private_key: String,
    /// Резервные серверы из client.json (HTTP-fallback). Нужны клиенту, иначе
    /// при недоступном primary приём по сети молча не работает.
    pub reserve: Vec<String>,
    pub dialogues: Vec<UiDialog>,
}

/// Разлочить vault UI-клиента под `app_data_root` его PIN'ом и вычитать все
/// (или выбранный через `selector`) профили. `selector` матчит username,
/// server_id или имя каталога профиля.
///
/// ВНИМАНИЕ: переводит ГЛОБАЛЬНЫЙ vault процесса на UI-стор (`lock` →
/// `set_app_data_root` → `unlock`). Это singleton (`local_vault::VAULT`), так что
/// после вызова активен именно UI-vault. Для нашего пути это безопасно: дальше
/// CLI-стор шифруется отдельной схемой `key_from_pin` (не через local_vault), а
/// `~/.paranoia_dialogues.json` — вообще plaintext.
pub fn read_ui_profiles(
    app_data_root: &Path,
    pin: &str,
    selector: Option<&str>,
) -> Result<Vec<UiProfile>> {
    unlock_ui_vault(app_data_root, pin)?;
    let out = list_ui_profiles(app_data_root, selector)?;
    if out.is_empty() {
        bail!(
            "в {} не найдено подходящих профилей{}",
            app_data_root.join("profiles").display(),
            selector
                .map(|s| format!(" (фильтр: {s})"))
                .unwrap_or_default()
        );
    }
    Ok(out)
}

/// Разлочить vault UI-клиента под `app_data_root` его PIN'ом (без чтения профилей).
/// Делает то же переключение глобального vault, что и [`read_ui_profiles`].
pub fn unlock_ui_vault(app_data_root: &Path, pin: &str) -> Result<()> {
    use paranoia_lib::local_vault;

    if !app_data_root.exists() {
        bail!("каталог UI-стора не найден: {}", app_data_root.display());
    }

    // Переключить активный vault на UI-стор.
    local_vault::lock();
    local_vault::vault::set_app_data_root(app_data_root.to_path_buf());
    match local_vault::status().context("vault status (UI store)")? {
        local_vault::VaultStatus::NotInitialized => bail!(
            "под {} нет vault.json — это точно AppData каталог UI-клиента?",
            app_data_root.display()
        ),
        local_vault::VaultStatus::Locked => local_vault::unlock(pin)
            .map_err(|e| anyhow!("не удалось разлочить UI-vault ({e}) — неверный PIN UI-клиента?"))?,
        // После lock() сюда не попадём, но на всякий случай — уже разлочен, ок.
        local_vault::VaultStatus::Unlocked => {}
    }
    Ok(())
}

/// Прочитать профили под УЖЕ разлоченным UI-vault. Пустой список — НЕ ошибка
/// (свежий стор без профилей: после регистрации появятся). `selector` фильтрует
/// по username / server_id / имени каталога.
pub fn list_ui_profiles(app_data_root: &Path, selector: Option<&str>) -> Result<Vec<UiProfile>> {
    use paranoia_lib::local_vault;

    let profiles_dir = app_data_root.join("profiles");
    if !profiles_dir.is_dir() {
        return Ok(Vec::new());
    }

    let mut out = Vec::new();
    for entry in std::fs::read_dir(&profiles_dir)
        .with_context(|| format!("read_dir {}", profiles_dir.display()))?
    {
        let entry = entry?;
        if !entry.file_type()?.is_dir() {
            continue;
        }
        let dir = entry.path();
        let client_path = dir.join("client.json");
        if !client_path.exists() {
            continue;
        }

        let client_bytes = local_vault::decrypt_json_from_disk(&client_path)
            .with_context(|| format!("decrypt {}", client_path.display()))?;
        let client: UiClientConfig = serde_json::from_slice(&client_bytes)
            .with_context(|| format!("parse {}", client_path.display()))?;
        if client.private_key.trim().is_empty() {
            continue; // профиль без signing key — нечего синхронизировать.
        }

        // Фильтр по селектору (username / server_id / имя каталога).
        if let Some(sel) = selector {
            let dir_name = entry.file_name();
            let dir_name = dir_name.to_string_lossy();
            if client.username != sel && client.server_id != sel && dir_name != sel {
                continue;
            }
        }

        // dialogs.json может отсутствовать (нет ни одного диалога).
        let dialogs_path = dir.join("dialogs.json");
        let dialogues = if dialogs_path.exists() {
            let bytes = local_vault::decrypt_json_from_disk(&dialogs_path)
                .with_context(|| format!("decrypt {}", dialogs_path.display()))?;
            let raw: Vec<UiDialogRaw> = serde_json::from_slice(&bytes)
                .with_context(|| format!("parse {}", dialogs_path.display()))?;
            raw.into_iter()
                .map(|d| UiDialog {
                    peer: d.peer,
                    peer_server_id: d.peer_server_id,
                    local_name: d.local_name,
                    keyring: d
                        .keyring
                        .into_iter()
                        .filter(|k| !k.key.trim().is_empty() && k.start_seq >= 1.0)
                        .map(|k| (k.start_seq as u64, k.key))
                        .collect(),
                })
                .collect()
        } else {
            Vec::new()
        };

        out.push(UiProfile {
            server: client.server,
            username: client.username,
            server_id: client.server_id,
            private_key: client.private_key,
            reserve: client.reserve_server_urls,
            dialogues,
        });
    }

    Ok(out)
}

// ── запись: device-key + создание профиля (для TUI «добавить профиль») ────────

#[derive(Debug, Deserialize, Default)]
struct UiDeviceKey {
    #[serde(default)]
    private_key_b64: String,
}

/// ECIES-приватный ключ устройства UI (32 байта) из `device_key.json`.
/// Vault должен быть уже разлочен (см. [`unlock_ui_vault`]). Нужен для импорта
/// зашифрованных экспортов (они адресованы device-pubkey этого устройства).
pub fn ui_device_priv(app_data_root: &Path) -> Result<[u8; 32]> {
    use paranoia_lib::local_vault;
    let path = app_data_root.join("device_key.json");
    if !path.exists() {
        bail!(
            "{} не найден — запусти UI-клиент хотя бы раз (он создаёт device-ключ)",
            path.display()
        );
    }
    let bytes = local_vault::decrypt_json_from_disk(&path)
        .with_context(|| format!("decrypt {}", path.display()))?;
    let dk: UiDeviceKey = serde_json::from_slice(&bytes)
        .with_context(|| format!("parse {}", path.display()))?;
    crate::validate_b64_32(&dk.private_key_b64, "device private key")
}

/// Публичный device-ключ UI-стора (base64) — на него адресуют экспорт.
pub fn ui_device_pubkey_b64(app_data_root: &Path) -> Result<String> {
    use base64::{Engine, engine::general_purpose::STANDARD as B64};
    let priv_b = ui_device_priv(app_data_root)?;
    let pubk = paranoia_lib::export::pubkey_from_private_key(&priv_b);
    Ok(B64.encode(pubk))
}

/// Новый/импортируемый диалог для записи в `dialogs.json`.
pub struct NewDialog {
    pub peer: String,
    pub peer_server_id: String,
    pub local_name: String,
    pub keyring: Vec<(u64, String)>,
}

/// Создать (или дополнить) профиль в UI-сторе: пишет `profiles/<pid>/client.json`
/// и при наличии диалогов — `dialogs.json`, в том же зашифрованном vault-формате,
/// что и UI-клиент. Vault должен быть разлочен. Возвращает profileId.
///
/// Диалоги мёржатся по `peerServerId` (существующие не дублируются). `paranoia.db`
/// создаётся лениво при первом использовании клиентом.
pub fn create_profile(
    app_data_root: &Path,
    server_url: &str,
    username: &str,
    private_key_b64: &str,
    server_id: &str,
    dialogs: &[NewDialog],
) -> Result<String> {
    use paranoia_lib::local_vault;

    let pid = crate::dialogue_store::profile_id(server_url, server_id);
    let dir = app_data_root.join("profiles").join(&pid);
    std::fs::create_dir_all(&dir)
        .with_context(|| format!("create_dir_all {}", dir.display()))?;

    let client = serde_json::json!({
        "server": server_url,
        "username": username,
        "server_id": server_id,
        "private_key": private_key_b64,
    });
    let client_bytes = serde_json::to_vec(&client).context("serialize client.json")?;
    local_vault::encrypt_json_to_disk(&dir.join("client.json"), &client_bytes)
        .context("write client.json")?;

    if !dialogs.is_empty() {
        let dpath = dir.join("dialogs.json");
        let mut arr: Vec<serde_json::Value> = if dpath.exists() {
            let b = local_vault::decrypt_json_from_disk(&dpath)
                .with_context(|| format!("decrypt {}", dpath.display()))?;
            serde_json::from_slice(&b).unwrap_or_default()
        } else {
            Vec::new()
        };
        for d in dialogs {
            if d.peer_server_id.trim().is_empty() {
                continue;
            }
            let exists = arr.iter().any(|v| {
                v.get("peerServerId").and_then(|x| x.as_str()) == Some(d.peer_server_id.as_str())
            });
            if exists {
                continue;
            }
            let keyring: Vec<serde_json::Value> = d
                .keyring
                .iter()
                .map(|(s, k)| serde_json::json!({ "start_seq": s, "key": k }))
                .collect();
            arr.push(serde_json::json!({
                "peer": d.peer,
                "peerServerId": d.peer_server_id,
                "localName": d.local_name,
                "keyring": keyring,
            }));
        }
        let b = serde_json::to_vec(&arr).context("serialize dialogs.json")?;
        local_vault::encrypt_json_to_disk(&dpath, &b).context("write dialogs.json")?;
    }

    Ok(pid)
}
