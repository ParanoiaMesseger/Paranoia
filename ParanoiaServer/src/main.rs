mod config;
mod crypto;
mod metrics;
mod routes;
mod store;
mod cover;

use std::sync::Arc;
use axum::{Router, routing::post};
use tracing::info;
use crate::{
    config::Config,
    metrics::Metrics,
    store::PacketStore,
    cover::Cover,
};

pub struct AppState {
    pub config: Arc<tokio::sync::RwLock<Config>>,
    pub store:  Arc<PacketStore>,
    pub metrics: Arc<Metrics>,
    pub cover:   Arc<dyn Cover>,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "paranoia=debug".into()),
        )
        .init();

    let config_path = "./configs/Paranoia.json";
    let config = Config::load(config_path)?;
    let store_path = config.store_path.clone();
    let port = config.port;

    let state = Arc::new(AppState {
        config:  Arc::new(tokio::sync::RwLock::new(config)),
        store:   Arc::new(PacketStore::open(&store_path)?),
        metrics: Arc::new(Metrics::new()),
         cover:   Arc::new(FoodDeliveryCover::new()),
    });

    let app = Router::new()
        .route("/reg",         post(routes::reg::handle))
        .route("/push",        post(routes::push::handle))
        .route("/pull",        post(routes::pull::handle))
        .route("/determinate", post(routes::determinate::handle))
        .route("/metrics",     axum::routing::get(routes::metrics::handle))
        .with_state(state);

    let addr = format!("0.0.0.0:{port}");
    info!("Paranoia server started at http://{addr}");
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    axum::serve(listener, app).await?;
    Ok(())
}
