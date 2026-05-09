use crate::transport::{CoreDeterminate, CorePull, CorePush, RawPacket};
use anyhow::Result;
use serde_json::Value;

/// Интерфейс маскарадного слоя на клиенте.
pub trait ClientCover: Send + Sync + 'static {
    fn wrap_push(&self, core: &CorePush) -> Result<Value>;
    fn wrap_pull(&self, core: &CorePull) -> Result<Value>;
    fn wrap_determinate(&self, core: &CoreDeterminate) -> Result<Value>;

    fn unwrap_pull_response(&self, body: &Value) -> Result<Vec<RawPacket>>;
    fn unwrap_push_response(&self, body: &Value) -> Result<()>;
    fn unwrap_determinate_response(&self, body: &Value) -> Result<()>;
}
