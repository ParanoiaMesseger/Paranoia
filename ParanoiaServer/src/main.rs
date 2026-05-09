mod config;
mod cover;
mod crypto;
mod food_delivery_cover;
mod routes;
mod store;

use crate::{
    config::Config, cover::Cover, food_delivery_cover::FoodDeliveryCover, store::PacketStore,
};
use axum::{Router, routing::post};
use std::sync::Arc;
use tracing::info;

pub struct AppState {
    pub config: Arc<tokio::sync::RwLock<Config>>,
    pub store: Arc<PacketStore>,
    pub cover: Arc<dyn Cover>,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "paranoia=debug".into()),
        )
        .init();

    let config_path =
        std::env::var("PARANOIA_CONFIG").unwrap_or_else(|_| "./configs/Paranoia.json".to_string());
    let config = Config::load(&config_path)?;
    let store_path = config.store_path.clone();
    let port = config.port;

    let state = Arc::new(AppState {
        config: Arc::new(tokio::sync::RwLock::new(config)),
        store: Arc::new(PacketStore::open(&store_path)?),
        cover: Arc::new(FoodDeliveryCover::new()),
    });

    let app = Router::new()
        .route("/reg", post(routes::reg::handle))
        .route("/push", post(routes::push::handle))
        .route("/pull", post(routes::pull::handle))
        .route("/determinate", post(routes::determinate::handle))
        .with_state(state);

    let addr = format!("0.0.0.0:{port}");
    info!("Paranoia server started at http://{addr}");
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    axum::serve(listener, app).await?;
    Ok(())
}
