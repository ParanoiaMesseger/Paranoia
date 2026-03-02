use serde_json::Value;
use anyhow::Result;
use crate::routes::{push::PushRequest, pull::PullRequest, determinate::DeterminateRequest};

/// Cover интерфейс: как маскировать/размаскировать JSON.
pub trait Cover: Send + Sync + 'static {
    fn unwrap_push(&self, body: &Value) -> Result<PushRequest>;
    fn unwrap_pull(&self, body: &Value) -> Result<PullRequest>;
    fn unwrap_determinate(&self, body: &Value) -> Result<DeterminateRequest>;

    fn wrap_push_response(&self, resp: &crate::routes::push::ApiResponse) -> Value;
    fn wrap_pull_response(&self, resp: &crate::routes::pull::ApiResponse) -> Value;
    fn wrap_determinate_response(&self, resp: &crate::routes::determinate::ApiResponse) -> Value;
}
