//! Маскировка HTTP-конверта (Фаза 0 плана маскировки).
//!
//! Тело сообщений маскирует cover-слой ([`crate::client_cover`]); этот модуль
//! отвечает за то, чтобы сам HTTP-запрос не выдавал Paranoia на уровне
//! транспорта: метод, `User-Agent`, схема заголовка `Authorization`,
//! `Cache-Control`. Значения настраиваемы, чтобы подстраиваться под требования
//! конкретных CDN (например, набор разрешённых методов).
//!
//! В будущем (Фаза 1) поглощается полноценным Masking Profile, который добавит
//! поверх этого ещё и подмену путей и schema-cover тела.

use crate::crypto;
use reqwest::Method;
use std::collections::HashMap;

/// Настройки маскировки HTTP-конверта. Дёшево клонируется.
#[derive(Clone, Debug)]
pub struct HttpMasking {
    /// Метод для «пишущих» эндпоинтов по умолчанию. Намеренно НЕ POST — часть
    /// CDN (в частности Yandex CDN) не пропускает POST; PUT проходит. Для CDN,
    /// где допустим POST, переопределяется через профиль.
    pub default_method: Method,
    /// Точечное переопределение метода для конкретного пути (например "/push").
    pub method_overrides: HashMap<String, Method>,
    /// Пул `User-Agent`; ротация по кругу на каждый запрос. Пусто → заголовок не
    /// ставится (тогда reqwest подставит свой дефолт — нежелательно).
    pub user_agents: Vec<String>,
    /// Значение `Cache-Control`, добавляемое к каждому запросу. `None` → не
    /// добавляется. По умолчанию `no-store` — чтобы промежуточные кеши/CDN не
    /// отдавали клиенту чужой/устаревший ответ.
    pub cache_control: Option<String>,
    /// Схема в заголовке `Authorization` (для `/arrived`). Пустая строка →
    /// токен отправляется без префикса-схемы.
    pub auth_scheme: String,
}

impl Default for HttpMasking {
    fn default() -> Self {
        Self {
            default_method: Method::PUT,
            method_overrides: HashMap::new(),
            user_agents: vec![
                // Нейтральный распространённый UA — не выдаёт ни Paranoia, ни
                // reqwest. Профиль может расширить пул для разнообразия.
                "Mozilla/5.0 (Linux; Android 14; SM-G991B) AppleWebKit/537.36 \
                 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36"
                    .to_string(),
            ],
            cache_control: Some("no-store".to_string()),
            // Стандартная схема bearer-токена — выглядит как обычный API-клиент.
            auth_scheme: "Bearer".to_string(),
        }
    }
}

impl HttpMasking {
    /// Метод HTTP для данного пути.
    pub fn method_for(&self, path: &str) -> Method {
        self.method_overrides
            .get(path)
            .cloned()
            .unwrap_or_else(|| self.default_method.clone())
    }

    /// User-Agent по индексу ротации (`None`, если пул пуст).
    pub fn user_agent(&self, rotation: usize) -> Option<&str> {
        if self.user_agents.is_empty() {
            None
        } else {
            Some(self.user_agents[rotation % self.user_agents.len()].as_str())
        }
    }

    /// Значение заголовка `Authorization` для `/arrived`.
    ///
    /// Токен `username:sig_b64` оборачивается в base64 → получается непрозрачный
    /// bearer-подобный токен без распознаваемой структуры. Сервер снимает любую
    /// схему-префикс и разворачивает обратно
    /// ([`crate::transport`] ↔ серверный `routes::arrived`).
    pub fn arrived_auth_value(&self, username: &str, sig_b64: &str) -> String {
        let token = crypto::encode_b64(format!("{username}:{sig_b64}").as_bytes());
        if self.auth_scheme.is_empty() {
            token
        } else {
            format!("{} {token}", self.auth_scheme)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_masking_does_not_leak_paranoia() {
        let m = HttpMasking::default();
        let value = m.arrived_auth_value("alice", "c2lnbmF0dXJl");
        // Заголовок не должен содержать слово-маркер продукта.
        assert!(!value.contains("Paranoia"));
        assert!(value.starts_with("Bearer "));
    }

    #[test]
    fn arrived_token_roundtrips() {
        let m = HttpMasking::default();
        let value = m.arrived_auth_value("alice", "c2ln");
        // Повторяем серверный разбор: снять схему → base64-decode → split ':'.
        let token_b64 = value.rsplit(' ').next().unwrap();
        let decoded = String::from_utf8(crypto::decode_b64(token_b64).unwrap()).unwrap();
        assert_eq!(decoded, "alice:c2ln");
    }

    #[test]
    fn method_override_takes_precedence() {
        let mut m = HttpMasking::default();
        assert_eq!(m.method_for("/push"), Method::PUT);
        m.method_overrides
            .insert("/push".to_string(), Method::POST);
        assert_eq!(m.method_for("/push"), Method::POST);
        assert_eq!(m.method_for("/pull"), Method::PUT);
    }

    #[test]
    fn user_agent_rotates_and_handles_empty() {
        let mut m = HttpMasking::default();
        m.user_agents = vec!["a".to_string(), "b".to_string()];
        assert_eq!(m.user_agent(0), Some("a"));
        assert_eq!(m.user_agent(1), Some("b"));
        assert_eq!(m.user_agent(2), Some("a"));
        m.user_agents.clear();
        assert_eq!(m.user_agent(0), None);
    }
}
