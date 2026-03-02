use std::sync::Arc;
use axum::extract::State;
use crate::AppState;

pub async fn handle(State(state): State<Arc<AppState>>) -> String {
    state.metrics.render()
}
