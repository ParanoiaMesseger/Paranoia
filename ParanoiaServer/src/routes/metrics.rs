#[cfg(feature = "metrics")]
pub mod metrics_enabled_endpoint {
    use crate::AppState;
    use axum::extract::State;
    use std::sync::Arc;
    async fn handle(State(state): State<Arc<AppState>>) -> String {
        state.metrics.render()
    }
    pub fn attach_metrics_route(app: axum::Router<Arc<AppState>>) -> axum::Router<Arc<AppState>> {
        app.route("/metrics", axum::routing::get(handle))
    }
}
#[cfg(not(feature = "metrics"))]
pub mod metrics_enabled_endpoint {
    use crate::AppState;
    use std::sync::Arc;
    pub fn attach_metrics_route(app: axum::Router<Arc<AppState>>) -> axum::Router<Arc<AppState>> {
        app
    }
}
