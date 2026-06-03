mod call_signal;
mod config;
mod cover;
mod crypto;
mod food_delivery_cover;
mod nginx;
mod routes;
mod schema_cover;
mod store;
mod voip_stun;

use crate::{
    call_signal::CallSignalStore, config::Config, cover::Cover,
    food_delivery_cover::FoodDeliveryCover, schema_cover::SchemaCover, store::PacketStore,
};
use anyhow::Context;
use axum::{
    Router,
    routing::{MethodFilter, get, on, put},
};
use paranoia_cover::MaskingProfile;
use std::sync::Arc;
use tracing::info;

/// Путь и HTTP-метод для вида пакета: из профиля маскировки, иначе встроенные.
fn cover_route(
    profile: &Option<Arc<MaskingProfile>>,
    kind: &str,
    default_path: &str,
) -> (String, MethodFilter) {
    match profile.as_ref().and_then(|p| p.kinds.get(kind)) {
        Some(spec) => (spec.path.clone(), method_filter(&spec.method)),
        None => (default_path.to_string(), MethodFilter::PUT),
    }
}

fn method_filter(method: &str) -> MethodFilter {
    match method.to_ascii_uppercase().as_str() {
        "POST" => MethodFilter::POST,
        "PATCH" => MethodFilter::PATCH,
        "DELETE" => MethodFilter::DELETE,
        "GET" => MethodFilter::GET,
        _ => MethodFilter::PUT,
    }
}

pub struct AppState {
    pub config: Arc<tokio::sync::RwLock<Config>>,
    pub store: Arc<PacketStore>,
    pub cover: Arc<dyn Cover>,
    pub call_signals: Arc<CallSignalStore>,
    /// Активный masking-профиль (для cover admin/reg-трафика через шлюз). `None`
    /// → admin/reg идут плоско по фиксированным путям (как раньше).
    pub masking_profile: Option<Arc<MaskingProfile>>,
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

    // Masking-профиль из конфига (если задан) — даёт и cover-слой, и пути/методы
    // для динамического роутера.
    let masking_profile: Option<Arc<MaskingProfile>> = match config.masking_profile_path.as_deref()
    {
        Some(path) if !path.trim().is_empty() => {
            let raw = std::fs::read_to_string(path)
                .with_context(|| format!("cannot read masking profile: {path}"))?;
            let profile = MaskingProfile::from_json(&raw).context("invalid masking profile")?;
            info!(
                "masking profile '{}' v{} loaded ({} kinds)",
                profile.name,
                profile.version,
                profile.kinds.len()
            );
            Some(Arc::new(profile))
        }
        _ => None,
    };

    let cover: Arc<dyn Cover> = match &masking_profile {
        Some(profile) => Arc::new(SchemaCover::new(Arc::clone(profile))),
        None => Arc::new(FoodDeliveryCover::new()),
    };

    // Захватываем nginx-настройки до перемещения config в AppState.
    let nginx_config_path = config.nginx_config_path.clone();
    let nginx_reload_command = config.nginx_reload_command.clone();

    let state = Arc::new(AppState {
        config: Arc::new(tokio::sync::RwLock::new(config)),
        store: Arc::new(PacketStore::open(&store_path)?),
        cover,
        call_signals,
        masking_profile: masking_profile.clone(),
    });

    // Cover-эндпоинты: пути/методы из профиля (или встроенные). /reg, /arrived и
    // admin-роуты пока на фиксированных путях.
    let (push_path, push_m) = cover_route(&masking_profile, "push", "/push");
    let (pull_path, pull_m) = cover_route(&masking_profile, "pull", "/pull");
    let (map_path, map_m) = cover_route(&masking_profile, "map", "/map");
    let (notify_path, notify_m) = cover_route(&masking_profile, "notify", "/notify");
    let (det_path, det_m) = cover_route(&masking_profile, "determinate", "/determinate");
    let (sig_path, sig_m) = cover_route(&masking_profile, "call_signal", "/call/signal");
    let (poll_path, poll_m) = cover_route(&masking_profile, "call_poll", "/call/poll");

    // Синхронизируем nginx-маршрутизацию с актуальными путями (если включено).
    if let Some(ncfg) = nginx_config_path.as_deref().filter(|p| !p.trim().is_empty()) {
        let routes = vec![
            nginx::Route { path: "/reg".into(), exact: true },
            nginx::Route { path: push_path.clone(), exact: true },
            nginx::Route { path: pull_path.clone(), exact: true },
            nginx::Route { path: map_path.clone(), exact: true },
            nginx::Route { path: notify_path.clone(), exact: true },
            nginx::Route { path: det_path.clone(), exact: true },
            nginx::Route { path: "/arrived".into(), exact: true },
            nginx::Route { path: sig_path.clone(), exact: true },
            nginx::Route { path: poll_path.clone(), exact: true },
            nginx::Route { path: "/admin/".into(), exact: false },
        ];
        nginx::update(ncfg, &routes, port, nginx_reload_command.as_deref());
    }

    let mut app: Router<Arc<AppState>> = Router::new()
        .route("/reg", put(routes::reg::handle))
        .route(&push_path, on(push_m, routes::push::handle))
        .route(&pull_path, on(pull_m, routes::pull::handle))
        .route(&map_path, on(map_m, routes::map::handle))
        .route(&notify_path, on(notify_m, routes::notify::handle))
        .route(&det_path, on(det_m, routes::determinate::handle))
        .route(
            "/arrived",
            get(routes::arrived::handle_get).put(routes::arrived::handle_put),
        )
        .route(&sig_path, on(sig_m, routes::call_signal::handle))
        .route(&poll_path, on(poll_m, routes::call_poll::handle))
        .merge(routes::admin::router());

    // Cover-шлюз для admin/reg: если профиль задаёт эти виды — маскированные
    // запросы идут на профильные пути (в дополнение к плоским). Иначе ничего
    // не добавляем (плоский трафик как раньше).
    if let Some(profile) = &masking_profile {
        if let Some(spec) = profile.kinds.get("admin") {
            app = app.route(
                &spec.path,
                on(method_filter(&spec.method), routes::cover_gateway::admin_gateway),
            );
            info!("admin cover-gateway at {}", spec.path);
        }
        if let Some(spec) = profile.kinds.get("reg") {
            app = app.route(
                &spec.path,
                on(method_filter(&spec.method), routes::cover_gateway::reg_gateway),
            );
            info!("reg cover-gateway at {}", spec.path);
        }
    }

    let app = app.with_state(state);

    let addr = format!("0.0.0.0:{port}");
    info!("Paranoia server started at http://{addr}");
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    axum::serve(listener, app).await?;
    Ok(())
}
