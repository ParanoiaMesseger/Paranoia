/// Cover интерфейс: как маскировать/размаскировать JSON.
pub trait Cover: Send + Sync + 'static {
    fn unwrap_push(
        &self,
        body: &serde_json::Value,
    ) -> anyhow::Result<crate::routes::push::PushRequest>;
    fn unwrap_pull(
        &self,
        body: &serde_json::Value,
    ) -> anyhow::Result<crate::routes::pull::PullRequest>;
    fn unwrap_map(
        &self,
        body: &serde_json::Value,
    ) -> anyhow::Result<crate::routes::map::MapRequest>;
    fn unwrap_notify(
        &self,
        body: &serde_json::Value,
    ) -> anyhow::Result<crate::routes::notify::NotifyRequest>;
    fn unwrap_determinate(
        &self,
        body: &serde_json::Value,
    ) -> anyhow::Result<crate::routes::determinate::DeterminateRequest>;
    fn unwrap_call_signal(
        &self,
        body: &serde_json::Value,
    ) -> anyhow::Result<crate::routes::call_signal::CallSignalRequest>;
    fn unwrap_call_poll(
        &self,
        body: &serde_json::Value,
    ) -> anyhow::Result<crate::routes::call_poll::CallPollRequest>;

    fn wrap_push_response(&self, resp: &crate::routes::push::ApiResponse) -> serde_json::Value;
    fn wrap_pull_response(&self, resp: &crate::routes::pull::ApiResponse) -> serde_json::Value;
    fn wrap_map_response(&self, resp: &crate::routes::map::ApiResponse) -> serde_json::Value;
    fn wrap_notify_response(&self, resp: &crate::routes::notify::ApiResponse) -> serde_json::Value;
    fn wrap_determinate_response(
        &self,
        resp: &crate::routes::determinate::ApiResponse,
    ) -> serde_json::Value;
    fn wrap_call_signal_response(
        &self,
        resp: &crate::routes::call_signal::ApiResponse,
    ) -> serde_json::Value;
    fn wrap_call_poll_response(
        &self,
        resp: &crate::routes::call_poll::ApiResponse,
    ) -> serde_json::Value;
}
