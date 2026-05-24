use crate::transport::{
    CallEnvelopeIn, CoreCallPoll, CoreCallSignal, CoreDeterminate, CoreMap, CoreNotify, CorePull,
    CorePush, MapResponse, RawPacket,
};
use anyhow::Result;
use serde_json::Value;

/// Интерфейс маскарадного слоя на клиенте.
pub trait ClientCover: Send + Sync + 'static {
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
