use crate::transport::{
    CallEnvelopeIn, CoreCallPoll, CoreCallSignal, CoreDeterminate, CoreMap, CoreNotify, CorePull,
    CorePush, MapResponse, RawPacket,
};
use anyhow::Result;
use serde_json::Value;

/// HTTP-маршрут для вида пакета, заданный профилем маскировки: путь + метод.
#[derive(Debug, Clone)]
pub struct CoverRoute {
    pub path: String,
    pub method: String,
}

/// Интерфейс маскарадного слоя на клиенте.
pub trait ClientCover: Send + Sync + 'static {
    /// Профильный путь/метод для вида пакета (`"push"`, `"pull"`, …). `None` →
    /// транспорт использует встроенные значения (`/push` и т.п.). По умолчанию
    /// `None` — переопределяет только schema-cover.
    fn route(&self, _kind: &str) -> Option<CoverRoute> {
        None
    }

    /// Generic-маскировка произвольного вида (напр. `blob`): запечатать `inner`
    /// по схеме вида профиля. `None` — профиль не активен или не содержит вида
    /// (транспорт шлёт запрос плоско). Переопределяет только schema-cover.
    fn wrap_kind(&self, _kind: &str, _inner: &[u8]) -> Option<Value> {
        None
    }

    /// Обратное к [`wrap_kind`]: развернуть ответ вида `kind` во внутренние байты.
    fn unwrap_kind(&self, _kind: &str, _body: &Value) -> Option<Vec<u8>> {
        None
    }

    fn wrap_push(&self, core: &CorePush) -> Result<Value>;
    fn wrap_pull(&self, core: &CorePull) -> Result<Value>;
    fn wrap_map(&self, core: &CoreMap) -> Result<Value>;
    fn wrap_notify(&self, core: &CoreNotify) -> Result<Value>;
    fn wrap_determinate(&self, core: &CoreDeterminate) -> Result<Value>;
    fn wrap_call_signal(&self, core: &CoreCallSignal) -> Result<Value>;
    fn wrap_call_poll(&self, core: &CoreCallPoll) -> Result<Value>;

    fn unwrap_pull_response(&self, body: &Value) -> Result<Vec<RawPacket>>;
    fn unwrap_map_response(&self, body: &Value) -> Result<MapResponse>;
    fn unwrap_notify_response(&self, body: &Value) -> Result<u64>;
    fn unwrap_push_response(&self, body: &Value) -> Result<()>;
    fn unwrap_determinate_response(&self, body: &Value) -> Result<()>;
    fn unwrap_call_signal_response(&self, body: &Value) -> Result<()>;
    fn unwrap_call_poll_response(&self, body: &Value) -> Result<Vec<CallEnvelopeIn>>;
}
