mod call_signal;
mod config;
mod cover;
mod crypto;
mod food_delivery_cover;
mod routes;
mod store;
mod voip_stun;

use crate::{
    call_signal::CallSignalStore, config::Config, cover::Cover,
    food_delivery_cover::FoodDeliveryCover, store::PacketStore,
};
use axum::{
    Router,
    routing::{get, put},
};
use std::sync::Arc;
use tracing::info;

pub struct AppState {
    pub config: Arc<tokio::sync::RwLock<Config>>,
    pub store: Arc<PacketStore>,
    pub cover: Arc<dyn Cover>,
    pub call_signals: Arc<CallSignalStore>,
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
    let stun_bind_str = config.stun_bind.clone();
    let turn_public_ip = config.turn_public_ip.clone();
    let turn_relay_port_range = config.turn_relay_port_range.clone();

    let call_signals = Arc::new(CallSignalStore::new());
    let _gc = call_signal::spawn_gc(Arc::clone(&call_signals));

    // STUN/TURN-листенер на основном домене (отдельный UDP-порт; CDN/HTTPS не
    // пропустят UDP, поэтому развязка по портам — единственный практичный
    // вариант). Падение задачи не валит HTTP-сервер.
    if let Some(bind_str) = stun_bind_str {
        match bind_str.parse::<std::net::SocketAddr>() {
            Ok(bind) => {
                let parsed_turn_public_ip = match turn_public_ip.as_deref() {
                    Some(s) if !s.trim().is_empty() => match s.parse::<std::net::IpAddr>() {
                        Ok(ip) => Some(ip),
                        Err(e) => {
                            tracing::warn!(
                                "invalid turn_public_ip {s}: {e} — using relay bind address"
                            );
                            None
                        }
                    },
                    _ => None,
                };
                let parsed_relay_port_range: Option<(u16, u16)> =
                    match turn_relay_port_range.as_deref() {
                        Some(s) if !s.trim().is_empty() => {
                            let parts: Vec<&str> = s.split('-').collect();
                            match parts.as_slice() {
                                [a, b] => match (a.trim().parse::<u16>(), b.trim().parse::<u16>()) {
                                    (Ok(start), Ok(end)) if start > 0 && start <= end => {
                                        Some((start, end))
                                    }
                                    _ => {
                                        tracing::warn!(
                                            "invalid turn_relay_port_range {s:?} — expected \"start-end\" with 1<=start<=end; using ephemeral"
                                        );
                                        None
                                    }
                                },
                                _ => {
                                    tracing::warn!(
                                        "invalid turn_relay_port_range {s:?} — expected \"start-end\"; using ephemeral"
                                    );
                                    None
                                }
                            }
                        }
                        _ => None,
                    };
                tokio::spawn(async move {
                    if let Err(e) = voip_stun::run(
                        bind,
                        parsed_turn_public_ip,
                        parsed_relay_port_range,
                    )
                    .await
                    {
                        tracing::warn!("STUN/TURN listener exited: {e}");
                    }
                });
            }
            Err(e) => tracing::warn!("invalid stun_bind {bind_str}: {e} — STUN/TURN disabled"),
        }
    } else {
        info!("STUN/TURN listener disabled by config (stun_bind = null)");
    }

    let state = Arc::new(AppState {
        config: Arc::new(tokio::sync::RwLock::new(config)),
        store: Arc::new(PacketStore::open(&store_path)?),
        cover: Arc::new(FoodDeliveryCover::new()),
        call_signals,
    });

    let app = Router::new()
        .route("/reg", put(routes::reg::handle))
        .route("/push", put(routes::push::handle))
        .route("/pull", put(routes::pull::handle))
        .route("/map", put(routes::map::handle))
        .route("/notify", put(routes::notify::handle))
        .route("/determinate", put(routes::determinate::handle))
        .route(
            "/arrived",
            get(routes::arrived::handle_get).put(routes::arrived::handle_put),
        )
        .route("/call/signal", put(routes::call_signal::handle))
        .route("/call/poll", put(routes::call_poll::handle))
        .merge(routes::admin::router())
        .with_state(state);

    let addr = format!("0.0.0.0:{port}");
    info!("Paranoia server started at http://{addr}");
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    axum::serve(listener, app).await?;
    Ok(())
}
