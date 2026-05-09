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
    fn unwrap_determinate(
        &self,
        body: &serde_json::Value,
    ) -> anyhow::Result<crate::routes::determinate::DeterminateRequest>;

    fn wrap_push_response(&self, resp: &crate::routes::push::ApiResponse) -> serde_json::Value;
    fn wrap_pull_response(&self, resp: &crate::routes::pull::ApiResponse) -> serde_json::Value;
    fn wrap_determinate_response(
        &self,
        resp: &crate::routes::determinate::ApiResponse,
    ) -> serde_json::Value;
}
