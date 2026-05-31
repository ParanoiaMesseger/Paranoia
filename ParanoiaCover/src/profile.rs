//! Формат masking-профиля и его валидация.

use anyhow::{Result, bail};
use serde::Deserialize;
use serde_json::Value;
use std::collections::HashMap;

/// Длина симметричного cover-ключа (ChaCha20-Poly1305).
pub const COVER_KEY_LEN: usize = 32;

/// Максимум схем-вариантов на один вид пакета. Ограничивает стоимость
/// брутфорс-разворачивания на сервере (см. [`crate::unwrap`]).
pub const MAX_SCHEMAS_PER_KIND: usize = 10;

/// Профиль маскировки — «одно фейковое приложение».
#[derive(Debug, Clone, Deserialize)]
pub struct MaskingProfile {
    /// Имя профиля (для логов/UI).
    pub name: String,
    /// Версия профиля (монотонно растёт при обновлении).
    #[serde(default = "default_version")]
    pub version: u64,
    /// Симметричный cover-ключ (base64, ровно 32 байта). НЕ ключ
    /// конфиденциальности сообщений — см. модульную документацию.
    pub cover_key_b64: String,
    /// Спецификации по видам пакетов: `push`, `pull`, `map`, `notify`,
    /// `determinate`, `call_signal`, `call_poll`, их `*_resp`, а также
    /// `admin`/`corp`/`commercial` (добавляются по мере покрытия).
    pub kinds: HashMap<String, KindSpec>,
    /// Пул User-Agent (ротация на стороне транспорта). Пусто → не задаётся.
    #[serde(default)]
    pub user_agents: Vec<String>,
    /// Доп. статические заголовки запроса для правдоподобия.
    #[serde(default)]
    pub headers: HashMap<String, String>,
    /// Значение Cache-Control (например "no-store"). `None` → не задаётся.
    #[serde(default)]
    pub cache_control: Option<String>,
}

/// Спецификация одного вида пакета.
#[derive(Debug, Clone, Deserialize)]
pub struct KindSpec {
    /// HTTP-путь «фейкового» эндпоинта (начинается с '/').
    pub path: String,
    /// HTTP-метод (по умолчанию PUT — совместим с Yandex CDN).
    #[serde(default = "default_method")]
    pub method: String,
    /// Схемы-варианты (1..=[`MAX_SCHEMAS_PER_KIND`]). При отправке выбирается
    /// случайная; при разборе перебираются все.
    pub schemas: Vec<SchemaVariant>,
}

/// Один вариант маскирующей схемы.
#[derive(Debug, Clone, Deserialize)]
pub struct SchemaVariant {
    /// Скелет правдоподобного JSON. Поля-носители и опциональные поля могут уже
    /// присутствовать (тогда движок их перезапишет) или создаваться на лету.
    pub template: Value,
    /// Пути (через точку, напр. `meta.p1` или `items.0.sku`) до полей-носителей
    /// — в порядке сборки payload. Минимум один.
    pub carriers: Vec<String>,
    /// Опциональные декой-поля: включаются случайно (комбинаторный разброс форм
    /// пакетов против статистического анализа).
    #[serde(default)]
    pub optional: Vec<OptionalField>,
    /// JSON Schema (2020-12) для валидации правдоподобия (применяется в
    /// панели/деве; на проде — опционально).
    #[serde(default)]
    pub json_schema: Option<Value>,
}

/// Опциональное декой-поле.
#[derive(Debug, Clone, Deserialize)]
pub struct OptionalField {
    /// Путь (через точку) до поля.
    pub path: String,
    /// Значение, которое подставляется при включении поля.
    pub value: Value,
}

fn default_version() -> u64 {
    1
}

fn default_method() -> String {
    "PUT".to_string()
}

impl MaskingProfile {
    /// Распарсить и провалидировать профиль из JSON.
    pub fn from_json(s: &str) -> Result<Self> {
        let profile: MaskingProfile = serde_json::from_str(s)?;
        profile.validate()?;
        Ok(profile)
    }

    /// Cover-ключ как массив 32 байт.
    pub fn cover_key(&self) -> Result<[u8; COVER_KEY_LEN]> {
        let raw = crate::engine::b64_decode(&self.cover_key_b64)?;
        if raw.len() != COVER_KEY_LEN {
            bail!(
                "cover_key must be {COVER_KEY_LEN} bytes, got {}",
                raw.len()
            );
        }
        let mut key = [0u8; COVER_KEY_LEN];
        key.copy_from_slice(&raw);
        Ok(key)
    }

    /// Структурная валидация профиля (без проверки JSON Schema).
    pub fn validate(&self) -> Result<()> {
        if self.name.trim().is_empty() {
            bail!("profile name is empty");
        }
        let _ = self.cover_key()?;
        if self.kinds.is_empty() {
            bail!("profile has no kinds");
        }
        for (kind, spec) in &self.kinds {
            if !spec.path.starts_with('/') {
                bail!("kind '{kind}': path must start with '/'");
            }
            if spec.schemas.is_empty() {
                bail!("kind '{kind}': no schema variants");
            }
            if spec.schemas.len() > MAX_SCHEMAS_PER_KIND {
                bail!(
                    "kind '{kind}': {} schemas exceed limit {MAX_SCHEMAS_PER_KIND}",
                    spec.schemas.len()
                );
            }
            for (i, variant) in spec.schemas.iter().enumerate() {
                if variant.carriers.is_empty() {
                    bail!("kind '{kind}' schema #{i}: no carrier fields");
                }
            }
        }
        Ok(())
    }
}
