//! UDP-транспорт голосового звонка на Tokio.
//!
//! Текущий объём (Phase 4 минимум):
//! - один `tokio::net::UdpSocket`, один известный `peer` (адрес кандидата
//!   обменивается через сигналинг — STUN/ICE подключим позже);
//! - main-loop `tokio::select!`: входящие пакеты → расшифровать → канал в Qt;
//!   исходящие фреймы из Qt → зашифровать → `send_to`;
//!   keep-alive «pingboard» раз в [`KEEPALIVE_INTERVAL`]; shutdown.
//! - STUN-пакеты различаются по magic cookie `0x2112A442` в bytes 4..8 — для них
//!   зарезервирован отдельный канал; здесь они **детектируются** и
//!   игнорируются, полная обработка ICE придёт в следующей фазе.
//! - ключи зануляются на выходе через [`SessionKeys`]'ный `Drop`.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Result, bail};
use tokio::net::UdpSocket;
use tokio::sync::{Notify, mpsc, oneshot};

use super::crypto::{Role, StreamId, StreamKeys};
use super::packet::{ReplayWindow, VoipHeader, flags as pkt_flags, pack, unpack};
use super::stun;
use super::turn::{self, Class};

/// MTU-safe верхняя граница на UDP-датаграмму. Cтавим с большим запасом —
/// 1200, потому что мобильные сети (LTE/5G + GTP/PPPoE/VPN-туннели операторов)
/// часто имеют path-MTU 1280–1400. Пакеты по 1400 байт там теряются или
/// фрагментируются (что на UDP равно дропу). 1200 байт UDP payload + 28 байт
/// IP/UDP-заголовков = 1228 байт «по проводу», влезает в IPv6 minimum MTU 1280
/// без фрагментации. На звук это не влияет (Opus-фреймы ~40–100 байт), но
/// видео-фрагменты раньше уезжали аккурат под 1400 — и не доходили через 4G.
pub const MAX_DATAGRAM: usize = 1200;
/// Период keep-alive (см. policy: 15 c).
pub const KEEPALIVE_INTERVAL: Duration = Duration::from_secs(15);
/// STUN magic cookie (RFC 8489), идущий по смещению 4..8 в каждом STUN-сообщении.
const STUN_MAGIC_COOKIE: [u8; 4] = [0x21, 0x12, 0xA4, 0x42];

/// Содержимое одного фрейма, ожидаемого декодером.
/// Для voice — это Opus-фрейм; для video — один фрагмент NAL'а (см.
/// `voip::nal::Reassembler`).
#[derive(Debug, Clone)]
pub struct InboundFrame {
    pub stream: StreamId,
    pub sequence: u64,
    pub rtp_timestamp: u32,
    pub flags: u8,
    pub opus: Vec<u8>,
}

/// Один исходящий video-пакет: уже-фрагментированный кусок NAL'а с заданным
/// `rtp_timestamp` (общим для всех фрагментов одного кадра) и `flags`
/// (FRAME_START / FRAGMENT_END_BIT). См. `voip::nal::Fragmenter`.
#[derive(Debug, Clone)]
pub struct VideoOutboundPacket {
    pub flags: u8,
    pub rtp_timestamp: u32,
    pub payload: Vec<u8>,
}

/// Параметры сессии.
///
/// Сессия всегда мультиплексирует оба потока (voice + video) по одному
/// UDP-сокету. `stream_id` в заголовке пакета разделяет их при приёме; на
/// стороне отправки голосовые и видеофреймы идут через разные mpsc-каналы
/// в [`SessionHandle`]. Видео-канал просто молчит, если камера не включена.
///
/// `peer == None` означает «слушаем, peer определится позднее» — это нужно для
/// сценария, когда мы биндим сокет до обмена сигналинговыми кандидатами и
/// потом обновляем peer через [`SessionHandle::set_peer`]. Если приходит
/// валидный зашифрованный пакет от неизвестного адреса, peer заполняется
/// автоматически (приём первого «знакомого» источника).
pub struct SessionParams {
    pub role: Role,
    pub peer: Option<SocketAddr>,
}

/// Внутренний запрос: «отправь STUN Binding Request на server и отдай
/// reflexive-адрес». Используется `SessionHandle::stun_discover`.
struct StunRequest {
    server: SocketAddr,
    reply: oneshot::Sender<Result<SocketAddr>>,
    timeout: Duration,
}

/// TURN-команды в сессию. Все TURN-пакеты идут через тот же UDP-сокет, что и
/// media/STUN, чтобы NAT видел один mapping на весь звонок.
enum TurnRequest {
    Allocate {
        server: SocketAddr,
        reply: oneshot::Sender<Result<SocketAddr>>,
        timeout: Duration,
    },
    SetPeer {
        server: SocketAddr,
        peer: SocketAddr,
        reply: oneshot::Sender<Result<()>>,
    },
}

enum TurnPending {
    Allocate {
        server: SocketAddr,
        reply: oneshot::Sender<Result<SocketAddr>>,
        deadline: tokio::time::Instant,
    },
    CreatePermission {
        deadline: tokio::time::Instant,
    },
}

#[derive(Default)]
struct TurnRoute {
    server: Option<SocketAddr>,
    relayed: Option<SocketAddr>,
    peer_relay: Option<SocketAddr>,
}

/// Ручка для остановки сессии и слежения за её завершением.
pub struct SessionHandle {
    shutdown: Arc<Notify>,
    /// Канал в сессию: сырые Opus-фреймы для отправки.
    outbound_tx: mpsc::Sender<Vec<u8>>,
    /// Канал в сессию: уже-фрагментированные video-пакеты (см.
    /// `voip::nal::Fragmenter`). Включается только когда есть видео-поток —
    /// для голосовых звонков канал просто не используется.
    video_outbound_tx: mpsc::Sender<VideoOutboundPacket>,
    /// Канал из сессии: расшифрованные входящие фреймы (voice + video).
    /// `Option`, чтобы можно было «забрать» receiver наружу (для FFI/Qt).
    inbound_rx: Option<mpsc::Receiver<InboundFrame>>,
    /// Канал в сессию: запрос STUN-discover через тот же UDP-сокет.
    stun_tx: mpsc::Sender<StunRequest>,
    /// Канал в сессию: TURN Allocate/route команды через тот же UDP-сокет.
    turn_tx: mpsc::Sender<TurnRequest>,
    /// Разделяемое поле адреса peer'а. Обновляется через `set_peer`. Также
    /// автозаполняется в `run_session` при auto-discovery.
    peer: Arc<Mutex<Option<SocketAddr>>>,
    /// Локальный адрес сокета (для отдачи в Qt после bind).
    local_addr: SocketAddr,
    join: tokio::task::JoinHandle<Result<()>>,
}

impl SessionHandle {
    pub async fn send_opus(&self, opus: Vec<u8>) -> Result<()> {
        self.outbound_tx
            .send(opus)
            .await
            .map_err(|_| anyhow::anyhow!("session outbound channel closed"))
    }

    /// Послать один уже-фрагментированный видеопакет. Caller отвечает за
    /// фрагментацию NAL'а через [`crate::voip::nal::Fragmenter`]: один кадр →
    /// серия `VideoOutboundPacket` с общим `rtp_timestamp` и корректными
    /// `flags` (FRAME_START у первого, без него у остальных).
    pub async fn send_video(&self, packet: VideoOutboundPacket) -> Result<()> {
        self.video_outbound_tx
            .send(packet)
            .await
            .map_err(|_| anyhow::anyhow!("session video outbound channel closed"))
    }

    pub async fn recv_frame(&mut self) -> Option<InboundFrame> {
        match self.inbound_rx.as_mut() {
            Some(rx) => rx.recv().await,
            None => None,
        }
    }

    /// Забрать receiver наружу — например, чтобы крутить его в отдельной
    /// фоновой задаче, дёргающей C-callback. После `take_inbound` метод
    /// `recv_frame` будет всегда возвращать `None`.
    pub fn take_inbound(&mut self) -> Option<mpsc::Receiver<InboundFrame>> {
        self.inbound_rx.take()
    }

    /// Клонировать sender голосового канала — пригодно для передачи в другие задачи.
    pub fn outbound_sender(&self) -> mpsc::Sender<Vec<u8>> {
        self.outbound_tx.clone()
    }

    /// Клонировать sender видео-канала.
    pub fn video_outbound_sender(&self) -> mpsc::Sender<VideoOutboundPacket> {
        self.video_outbound_tx.clone()
    }

    pub fn shutdown_notify(&self) -> Arc<Notify> {
        Arc::clone(&self.shutdown)
    }

    pub fn shutdown(&self) {
        self.shutdown.notify_waiters();
    }

    /// Установить (или обновить) адрес peer'а. Если задано — задача начнёт
    /// слать туда исходящие фреймы и keep-alive.
    pub fn set_peer(&self, addr: SocketAddr) {
        if let Ok(mut g) = self.peer.lock() {
            *g = Some(addr);
        }
    }

    pub fn peer(&self) -> Option<SocketAddr> {
        self.peer.lock().ok().and_then(|g| *g)
    }

    pub fn local_addr(&self) -> SocketAddr {
        self.local_addr
    }

    /// Послать STUN Binding Request через UDP-сокет этой сессии и дождаться
    /// XOR-MAPPED-ADDRESS от `server`. Использование того же сокета критично:
    /// NAT-mapping для другого порта почти всегда отличается.
    pub async fn stun_discover(&self, server: SocketAddr, timeout: Duration) -> Result<SocketAddr> {
        let (tx, rx) = oneshot::channel();
        let req = StunRequest {
            server,
            reply: tx,
            timeout,
        };
        if self.stun_tx.send(req).await.is_err() {
            bail!("session stun channel closed");
        }
        match rx.await {
            Ok(result) => result,
            Err(_) => bail!("session stun reply dropped"),
        }
    }

    /// Выполнить TURN Allocate через UDP-сокет этой сессии и вернуть relayed
    /// address. Дальше этот адрес отправляется peer'у через signaling как relay
    /// candidate.
    pub async fn turn_allocate(&self, server: SocketAddr, timeout: Duration) -> Result<SocketAddr> {
        let (tx, rx) = oneshot::channel();
        let req = TurnRequest::Allocate {
            server,
            reply: tx,
            timeout,
        };
        if self.turn_tx.send(req).await.is_err() {
            bail!("session turn channel closed");
        }
        match rx.await {
            Ok(result) => result,
            Err(_) => bail!("session turn reply dropped"),
        }
    }

    /// Переключить исходящие media на TURN Send Indication к `server` с
    /// `peer_relay` как XOR-PEER-ADDRESS. Входящие Data Indication будут
    /// распаковываться в том же receive-loop'е.
    pub async fn set_turn_peer(&self, server: SocketAddr, peer_relay: SocketAddr) -> Result<()> {
        let (tx, rx) = oneshot::channel();
        let req = TurnRequest::SetPeer {
            server,
            peer: peer_relay,
            reply: tx,
        };
        if self.turn_tx.send(req).await.is_err() {
            bail!("session turn channel closed");
        }
        match rx.await {
            Ok(result) => result,
            Err(_) => bail!("session turn set-peer reply dropped"),
        }
    }

    /// Дождаться завершения фоновой задачи. Возвращает результат её работы.
    pub async fn join(self) -> Result<()> {
        self.shutdown.notify_waiters();
        match self.join.await {
            Ok(res) => res,
            Err(e) => bail!("session task join failed: {e}"),
        }
    }
}

/// Запустить сессию звонка в фоновой Tokio-задаче.
///
/// Сессия всегда мультиплексирует voice+video по одному сокету. Если видео
/// не используется (камера выключена), соответствующий канал просто молчит.
///
/// `outbound_buffer` / `inbound_buffer` — ёмкости каналов в фреймах. Разумные
/// значения 64..256 (20 ms на фрейм → буфер ~1..5 с при заторе для voice).
/// Видео-канал имеет фиксированный буфер 128 — фрагменты одного кадра не
/// должны блокировать энкодер.
pub fn spawn_session(
    socket: UdpSocket,
    params: SessionParams,
    keys: StreamKeys,
    outbound_buffer: usize,
    inbound_buffer: usize,
) -> SessionHandle {
    let shutdown = Arc::new(Notify::new());
    let (outbound_tx, outbound_rx) = mpsc::channel::<Vec<u8>>(outbound_buffer);
    let (video_outbound_tx, video_outbound_rx) = mpsc::channel::<VideoOutboundPacket>(128);
    let (inbound_tx, inbound_rx) = mpsc::channel::<InboundFrame>(inbound_buffer);
    let (stun_tx, stun_rx) = mpsc::channel::<StunRequest>(16);
    let (turn_tx, turn_rx) = mpsc::channel::<TurnRequest>(16);
    let local_addr = socket
        .local_addr()
        .unwrap_or_else(|_| "0.0.0.0:0".parse().unwrap());
    let peer = Arc::new(Mutex::new(params.peer));
    let role = params.role;

    let shutdown_clone = Arc::clone(&shutdown);
    let peer_clone = Arc::clone(&peer);
    let join = tokio::spawn(async move {
        run_session(
            socket,
            role,
            peer_clone,
            keys,
            outbound_rx,
            video_outbound_rx,
            inbound_tx,
            stun_rx,
            turn_rx,
            shutdown_clone,
        )
        .await
    });

    SessionHandle {
        shutdown,
        outbound_tx,
        video_outbound_tx,
        inbound_rx: Some(inbound_rx),
        stun_tx,
        turn_tx,
        peer,
        local_addr,
        join,
    }
}

async fn process_media_datagram(
    data: &[u8],
    from: SocketAddr,
    peer: &Arc<Mutex<Option<SocketAddr>>>,
    keys: &StreamKeys,
    rx_dir: super::crypto::Direction,
    voice_rx_window: &mut ReplayWindow,
    video_rx_window: &mut ReplayWindow,
    inbound_tx: &mpsc::Sender<InboundFrame>,
) -> bool {
    let read_peer = |p: &Arc<Mutex<Option<SocketAddr>>>| -> Option<SocketAddr> {
        p.lock().ok().and_then(|g| *g)
    };
    let set_peer = |p: &Arc<Mutex<Option<SocketAddr>>>, addr: SocketAddr| {
        if let Ok(mut g) = p.lock() {
            *g = Some(addr);
        }
    };

    let current_peer = read_peer(peer);
    // Peek stream_id (байт 1) до AEAD: ключи разные. Невалидный stream_id или
    // короткий заголовок — unpack всё равно отвергнет.
    if data.len() < super::packet::VOIP_HEADER_LEN {
        tracing::debug!("voip packet too short to peek stream_id");
        return true;
    }
    let peeked_stream = match data[1] {
        0 => StreamId::Voice,
        1 => StreamId::Video,
        other => {
            tracing::debug!("voip unknown stream_id byte {other}");
            return true;
        }
    };
    let rx_key = keys.for_stream(peeked_stream).rx();
    match unpack(data, rx_key, rx_dir) {
        Ok((header, payload)) => {
            // Sanity: после AEAD убеждаемся, что AAD-stream совпадает с тем,
            // под который выбрали ключ.
            if header.stream_id != peeked_stream {
                tracing::debug!(
                    "voip packet AAD/peek mismatch ({:?} vs {:?})",
                    header.stream_id,
                    peeked_stream
                );
                return true;
            }
            let window = match header.stream_id {
                StreamId::Voice => voice_rx_window,
                StreamId::Video => video_rx_window,
            };
            if !window.check_and_update(header.sequence) {
                tracing::debug!(
                    "voip replay/late stream={:?} seq={} dropped",
                    header.stream_id,
                    header.sequence
                );
                return true;
            }
            if current_peer != Some(from) {
                if let Some(known) = current_peer {
                    tracing::info!(
                        "voip peer switched after authenticated packet: {known} -> {from}"
                    );
                } else {
                    tracing::info!("voip peer auto-discovered: {from}");
                }
                set_peer(peer, from);
            }
            let frame = InboundFrame {
                stream: header.stream_id,
                sequence: header.sequence,
                rtp_timestamp: header.rtp_timestamp,
                flags: header.flags,
                opus: payload,
            };
            inbound_tx.send(frame).await.is_ok()
        }
        Err(e) => {
            tracing::debug!("voip decrypt failed (stream={:?}): {e}", peeked_stream);
            true
        }
    }
}

async fn send_media_datagram(
    socket: &UdpSocket,
    turn_route: &TurnRoute,
    target: SocketAddr,
    pkt: &[u8],
) -> std::io::Result<usize> {
    if turn_route.peer_relay == Some(target) {
        if let Some(server) = turn_route.server {
            let tid = stun::fresh_transaction_id();
            let wrapped = turn::build_send_indication(tid, target, pkt);
            return socket.send_to(&wrapped, server).await;
        }
    }
    socket.send_to(pkt, target).await
}

#[allow(clippy::too_many_arguments)]
async fn run_session(
    socket: UdpSocket,
    role: Role,
    peer: Arc<Mutex<Option<SocketAddr>>>,
    mut keys: StreamKeys,
    mut outbound_rx: mpsc::Receiver<Vec<u8>>,
    mut video_outbound_rx: mpsc::Receiver<VideoOutboundPacket>,
    inbound_tx: mpsc::Sender<InboundFrame>,
    mut stun_rx: mpsc::Receiver<StunRequest>,
    mut turn_rx: mpsc::Receiver<TurnRequest>,
    shutdown: Arc<Notify>,
) -> Result<()> {
    let mut buf = vec![0u8; MAX_DATAGRAM + 512];
    // Per-stream tx state (нумерация и replay-окна независимы у voice и video,
    // потому что nonce включает stream_id — коллизий между потоками нет).
    let mut voice_tx_seq: u64 = 0;
    let mut video_tx_seq: u64 = 0;
    let mut voice_rx_window = ReplayWindow::new();
    let mut video_rx_window = ReplayWindow::new();
    let mut keepalive = tokio::time::interval(KEEPALIVE_INTERVAL);
    // Первый тик keepalive стрельнёт сразу — сожгём его (не хотим бить в peer
    // сразу при старте, кандидат может ещё прогревать NAT с другой стороны).
    keepalive.tick().await;
    let shutdown_fut = shutdown.notified();
    tokio::pin!(shutdown_fut);

    let tx_dir = role.tx_direction();
    let rx_dir = role.rx_direction();

    // in-flight STUN-запросы: tid → (server, oneshot, deadline).
    let mut stun_pending: HashMap<
        [u8; 12],
        (
            SocketAddr,
            oneshot::Sender<Result<SocketAddr>>,
            tokio::time::Instant,
        ),
    > = HashMap::new();
    let mut turn_pending: HashMap<[u8; 12], TurnPending> = HashMap::new();
    let mut turn_route = TurnRoute::default();

    // Хелпер: текущий peer (если задан).
    let read_peer = |p: &Arc<Mutex<Option<SocketAddr>>>| -> Option<SocketAddr> {
        p.lock().ok().and_then(|g| *g)
    };
    let set_peer = |p: &Arc<Mutex<Option<SocketAddr>>>, addr: SocketAddr| {
        if let Ok(mut g) = p.lock() {
            *g = Some(addr);
        }
    };

    // Периодический GC просроченных STUN-запросов.
    let mut stun_gc = tokio::time::interval(Duration::from_millis(250));
    stun_gc.tick().await; // съесть первый

    loop {
        tokio::select! {
            // Входящий пакет.
            recv = socket.recv_from(&mut buf) => {
                match recv {
                    Ok((len, from)) => {
                        let data = &buf[..len];
                        if is_stun(data) {
                            if let Ok(msg) = turn::parse(data) {
                                let tid = msg.header.transaction_id;
                                match (msg.header.method, msg.header.class) {
                                    (turn::method::BINDING, Class::Request) => {
                                        // Отвечаем Binding Success с XOR-MAPPED-ADDRESS=from.
                                        let resp = stun::build_binding_success(&tid, from);
                                        if let Err(e) = socket.send_to(&resp, from).await {
                                            tracing::debug!("stun reply to {from} failed: {e}");
                                        }
                                    }
                                    (turn::method::BINDING, Class::SuccessResponse) => {
                                        if let Some((server, reply, _deadline)) = stun_pending.remove(&tid) {
                                            match stun::parse_xor_mapped_address(data, &tid) {
                                                Some(reflexive) => {
                                                    tracing::debug!("stun reflexive {reflexive} via {server}");
                                                    let _ = reply.send(Ok(reflexive));
                                                }
                                                None => {
                                                    let _ = reply.send(Err(anyhow::anyhow!(
                                                        "stun success without XOR-MAPPED-ADDRESS"
                                                    )));
                                                }
                                            }
                                        } else {
                                            tracing::trace!("stale stun success from {from}");
                                        }
                                    }
                                    (turn::method::ALLOCATE, Class::SuccessResponse) => {
                                        if let Some(TurnPending::Allocate { server, reply, .. }) = turn_pending.remove(&tid) {
                                            if from != server {
                                                let _ = reply.send(Err(anyhow::anyhow!(
                                                    "turn allocate response from unexpected server {from}"
                                                )));
                                            } else if let Some(relayed) = msg.find_xor_address(turn::attr::XOR_RELAYED_ADDRESS) {
                                                tracing::info!("turn allocated relay {relayed} via {server}");
                                                turn_route.server = Some(server);
                                                turn_route.relayed = Some(relayed);
                                                let _ = reply.send(Ok(relayed));
                                            } else {
                                                let _ = reply.send(Err(anyhow::anyhow!(
                                                    "turn allocate success without XOR-RELAYED-ADDRESS"
                                                )));
                                            }
                                        }
                                    }
                                    (turn::method::ALLOCATE, Class::ErrorResponse) => {
                                        if let Some(TurnPending::Allocate { reply, .. }) = turn_pending.remove(&tid) {
                                            let _ = reply.send(Err(anyhow::anyhow!("turn allocate rejected")));
                                        }
                                    }
                                    (turn::method::CREATE_PERMISSION, Class::SuccessResponse) => {
                                        turn_pending.remove(&tid);
                                    }
                                    (turn::method::CREATE_PERMISSION, Class::ErrorResponse) => {
                                        turn_pending.remove(&tid);
                                        tracing::debug!("turn create-permission rejected by {from}");
                                    }
                                    (turn::method::DATA, Class::Indication) => {
                                        match turn::parse_data_indication(data) {
                                            Ok((peer_addr, payload)) => {
                                                if !process_media_datagram(
                                                    &payload,
                                                    peer_addr,
                                                    &peer,
                                                    &keys,
                                                    rx_dir,
                                                    &mut voice_rx_window,
                                                    &mut video_rx_window,
                                                    &inbound_tx,
                                                ).await {
                                                    break;
                                                }
                                            }
                                            Err(e) => tracing::debug!("turn data indication parse failed: {e}"),
                                        }
                                    }
                                    _ => {
                                        tracing::trace!(
                                            "ignored stun/turn method={} class={:?} from {from}",
                                            msg.header.method,
                                            msg.header.class
                                        );
                                    }
                                }
                            }
                            continue;
                        }
                        if !process_media_datagram(
                            data,
                            from,
                            &peer,
                            &keys,
                            rx_dir,
                            &mut voice_rx_window,
                            &mut video_rx_window,
                            &inbound_tx,
                        ).await {
                            break;
                        }
                    }
                    Err(e) => {
                        tracing::warn!("voip recv_from failed: {e}");
                    }
                }
            }

            // Исходящий Opus-фрейм из Qt.
            opus = outbound_rx.recv() => {
                match opus {
                    Some(frame) => {
                        let Some(target) = read_peer(&peer) else {
                            // Пока нет peer'а — выкидываем фрейм; нет смысла
                            // буферизовать, аудио всё равно реал-тайм.
                            tracing::trace!("voip outbound frame dropped — peer not set");
                            continue;
                        };
                        let header = VoipHeader::new(
                            StreamId::Voice,
                            voice_tx_seq,
                            (voice_tx_seq as u32).wrapping_mul(960),
                            0,
                        );
                        match pack(&header, keys.voice().tx(), tx_dir, &frame) {
                            Ok(pkt) => {
                                if pkt.len() > MAX_DATAGRAM {
                                    tracing::warn!(
                                        "voip voice packet {} > MAX_DATAGRAM {}",
                                        pkt.len(), MAX_DATAGRAM
                                    );
                                }
                                if let Err(e) = send_media_datagram(&socket, &turn_route, target, &pkt).await {
                                    tracing::warn!("voip voice send_to {} failed: {e}", target);
                                }
                                voice_tx_seq = voice_tx_seq.saturating_add(1);
                            }
                            Err(e) => tracing::warn!("voip voice pack failed: {e}"),
                        }
                    }
                    None => {
                        // Voice-канал закрыт — конец сессии.
                        break;
                    }
                }
            }

            // Исходящий уже-фрагментированный видеопакет из Qt.
            video = video_outbound_rx.recv() => {
                match video {
                    Some(pkt) => {
                        let Some(target) = read_peer(&peer) else {
                            tracing::trace!("voip video frame dropped — peer not set");
                            continue;
                        };
                        // flags из VideoOutboundPacket уже содержит FRAME_START
                        // у первого фрагмента кадра (см. nal::Fragmenter).
                        // RESERVED-биты не должны быть выставлены caller'ом.
                        let flags = pkt.flags & !pkt_flags::RESERVED_MASK;
                        let header = VoipHeader::new(
                            StreamId::Video,
                            video_tx_seq,
                            pkt.rtp_timestamp,
                            flags,
                        );
                        match pack(&header, keys.video().tx(), tx_dir, &pkt.payload) {
                            Ok(packed) => {
                                if packed.len() > MAX_DATAGRAM {
                                    tracing::warn!(
                                        "voip video packet {} > MAX_DATAGRAM {} — fragmenter mis-sized",
                                        packed.len(), MAX_DATAGRAM
                                    );
                                }
                                if let Err(e) = send_media_datagram(&socket, &turn_route, target, &packed).await {
                                    tracing::warn!("voip video send_to {} failed: {e}", target);
                                }
                                video_tx_seq = video_tx_seq.saturating_add(1);
                            }
                            Err(e) => tracing::warn!("voip video pack failed: {e}"),
                        }
                    }
                    None => {
                        // Видео-канал закрыт — не критично, продолжаем
                        // обслуживать voice. Заменим receiver на «вечный
                        // pending», чтобы select! не крутил его впустую.
                        let (_dead_tx, dead_rx) = mpsc::channel::<VideoOutboundPacket>(1);
                        video_outbound_rx = dead_rx;
                    }
                }
            }

            // Keep-alive: шлём короткий «ping» зашифрованным comfort-noise
            // фреймом через voice-канал. Только если peer уже задан.
            _ = keepalive.tick() => {
                let Some(target) = read_peer(&peer) else {
                    continue;
                };
                let header = VoipHeader::new(
                    StreamId::Voice,
                    voice_tx_seq,
                    (voice_tx_seq as u32).wrapping_mul(960),
                    super::packet::flags::COMFORT_NOISE,
                );
                if let Ok(pkt) = pack(&header, keys.voice().tx(), tx_dir, &[]) {
                    let _ = send_media_datagram(&socket, &turn_route, target, &pkt).await;
                    voice_tx_seq = voice_tx_seq.saturating_add(1);
                }
            }

            // STUN-discover запрос наружу.
            stun_req = stun_rx.recv() => {
                match stun_req {
                    Some(req) => {
                        let tid = stun::fresh_transaction_id();
                        let pkt = stun::build_binding_request(&tid);
                        match socket.send_to(&pkt, req.server).await {
                            Ok(_) => {
                                let deadline = tokio::time::Instant::now() + req.timeout;
                                stun_pending.insert(tid, (req.server, req.reply, deadline));
                            }
                            Err(e) => {
                                let _ = req.reply.send(Err(anyhow::anyhow!(
                                    "stun send_to {} failed: {e}", req.server
                                )));
                            }
                        }
                    }
                    None => {
                        // Канал закрыт — игнорируем; основной цикл живёт пока
                        // outbound / shutdown.
                    }
                }
            }

            // TURN Allocate / route commands.
            turn_req = turn_rx.recv() => {
                match turn_req {
                    Some(TurnRequest::Allocate { server, reply, timeout }) => {
                        let tid = stun::fresh_transaction_id();
                        let pkt = turn::build_initial_allocate(tid);
                        match socket.send_to(&pkt, server).await {
                            Ok(_) => {
                                let deadline = tokio::time::Instant::now() + timeout;
                                turn_pending.insert(tid, TurnPending::Allocate { server, reply, deadline });
                            }
                            Err(e) => {
                                let _ = reply.send(Err(anyhow::anyhow!(
                                    "turn allocate send_to {} failed: {e}", server
                                )));
                            }
                        }
                    }
                    Some(TurnRequest::SetPeer { server, peer: peer_relay, reply }) => {
                        if turn_route.server != Some(server) || turn_route.relayed.is_none() {
                            let _ = reply.send(Err(anyhow::anyhow!(
                                "turn peer set before successful allocation"
                            )));
                            continue;
                        }
                        turn_route.peer_relay = Some(peer_relay);
                        set_peer(&peer, peer_relay);

                        // Permission не обязателен для встроенного relay, но дешёвый
                        // запрос делает клиент ближе к RFC TURN и оставляет путь к
                        // будущему enforcement на сервере.
                        let tid = stun::fresh_transaction_id();
                        let perm = turn::build_create_permission_no_auth(tid, &[peer_relay]);
                        if socket.send_to(&perm, server).await.is_ok() {
                            let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
                            turn_pending.insert(tid, TurnPending::CreatePermission { deadline });
                        }
                        let _ = reply.send(Ok(()));
                    }
                    None => {}
                }
            }

            // GC STUN/TURN-таймаутов.
            _ = stun_gc.tick() => {
                let now = tokio::time::Instant::now();
                stun_pending.retain(|_tid, (_srv, reply_holder, deadline)| {
                    if now >= *deadline {
                        // Достанем reply через mem::replace на closed sender
                        // (можно использовать noop receiver — но проще: создадим
                        // новый pair и сразу отпустим).
                        let (tmp_tx, _tmp_rx) = oneshot::channel();
                        let real = std::mem::replace(reply_holder, tmp_tx);
                        let _ = real.send(Err(anyhow::anyhow!("stun timeout")));
                        false
                    } else {
                        true
                    }
                });
                let expired_turn: Vec<[u8; 12]> = turn_pending
                    .iter()
                    .filter_map(|(tid, pending)| {
                        let deadline = match pending {
                            TurnPending::Allocate { deadline, .. } => deadline,
                            TurnPending::CreatePermission { deadline } => deadline,
                        };
                        (now >= *deadline).then_some(*tid)
                    })
                    .collect();
                for tid in expired_turn {
                    if let Some(pending) = turn_pending.remove(&tid) {
                        if let TurnPending::Allocate { reply, .. } = pending {
                            let _ = reply.send(Err(anyhow::anyhow!("turn allocate timeout")));
                        }
                    }
                }
            }

            _ = shutdown_fut.as_mut() => {
                break;
            }
        }
    }

    // Явное зануление ключей (Drop тоже сделает, но фиксируем намерение).
    keys.zeroize_now();
    Ok(())
}

/// Проверить, является ли датаграмма STUN-сообщением (RFC 8489).
///
/// STUN-сообщение начинается с двух zero-битов и содержит magic cookie
/// `0x2112A442` по смещению 4..8.
pub fn is_stun(pkt: &[u8]) -> bool {
    pkt.len() >= 20 && (pkt[0] & 0b1100_0000) == 0 && pkt[4..8] == STUN_MAGIC_COOKIE
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::voip::crypto::{Role, StreamId, StreamKeys};

    fn master() -> [u8; 32] {
        [0xAB; 32]
    }
    fn sid() -> [u8; 16] {
        [0xCD; 16]
    }

    #[test]
    fn stun_magic_detected() {
        let mut pkt = vec![0u8; 20];
        pkt[4..8].copy_from_slice(&STUN_MAGIC_COOKIE);
        assert!(is_stun(&pkt));
        pkt[0] = 0b1100_0000; // первые два бита не нулевые — не STUN
        assert!(!is_stun(&pkt));
    }

    #[test]
    fn voip_packet_not_stun() {
        // version=0x01 в первом байте VoipHeader — старшие биты не нулевые? Нет,
        // 0x01 = 0000_0001, биты 6..7 равны 0. Но magic cookie не совпадёт.
        let pkt = [0x01u8; 32];
        assert!(!is_stun(&pkt));
    }

    /// Loopback end-to-end: два сокета на localhost, две сессии (инициатор и
    /// ответчик), обмен зашифрованными Opus-фреймами в обе стороны.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn loopback_session_round_trip() {
        let s_init = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let s_resp = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let addr_init = s_init.local_addr().unwrap();
        let addr_resp = s_resp.local_addr().unwrap();

        let keys_init = StreamKeys::derive(&master(), &sid(), Role::Initiator);
        let keys_resp = StreamKeys::derive(&master(), &sid(), Role::Responder);

        let mut h_init = spawn_session(
            s_init,
            SessionParams {
                role: Role::Initiator,
                peer: Some(addr_resp),
            },
            keys_init,
            16,
            16,
        );
        let mut h_resp = spawn_session(
            s_resp,
            SessionParams {
                role: Role::Responder,
                peer: Some(addr_init),
            },
            keys_resp,
            16,
            16,
        );

        // Инициатор шлёт три «фрейма», ответчик принимает.
        for i in 0..3u8 {
            h_init.send_opus(vec![i, i + 1, i + 2]).await.unwrap();
        }
        // И один обратный фрейм.
        h_resp.send_opus(vec![0xFF, 0xEE]).await.unwrap();

        // Принимаем у ответчика.
        let mut received_at_resp = Vec::new();
        for _ in 0..3 {
            let frame = tokio::time::timeout(Duration::from_secs(1), h_resp.recv_frame())
                .await
                .expect("timed out waiting on responder")
                .expect("session closed unexpectedly");
            received_at_resp.push(frame.opus);
        }
        assert_eq!(
            received_at_resp,
            vec![vec![0, 1, 2], vec![1, 2, 3], vec![2, 3, 4]]
        );

        // И у инициатора — обратный фрейм.
        let back = tokio::time::timeout(Duration::from_secs(1), h_init.recv_frame())
            .await
            .expect("timed out waiting on initiator")
            .expect("session closed unexpectedly");
        assert_eq!(back.opus, vec![0xFF, 0xEE]);

        // Закрываем.
        h_init.shutdown();
        h_resp.shutdown();
        // join'ы — сессии должны корректно завершаться.
        h_init.join().await.unwrap();
        h_resp.join().await.unwrap();
    }

    /// Перепутаны ключи: пакеты не должны расшифровываться.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn loopback_rejects_wrong_keys() {
        let s_init = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let s_resp = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let addr_init = s_init.local_addr().unwrap();
        let addr_resp = s_resp.local_addr().unwrap();

        let keys_init = StreamKeys::derive(&master(), &sid(), Role::Initiator);
        // У ответчика — ключи от другого session_id.
        let other_sid = [0xEE; 16];
        let keys_resp = StreamKeys::derive(&master(), &other_sid, Role::Responder);

        let h_init = spawn_session(
            s_init,
            SessionParams {
                role: Role::Initiator,
                peer: Some(addr_resp),
            },
            keys_init,
            16,
            16,
        );
        let mut h_resp = spawn_session(
            s_resp,
            SessionParams {
                role: Role::Responder,
                peer: Some(addr_init),
            },
            keys_resp,
            16,
            16,
        );
        h_init.send_opus(vec![1, 2, 3]).await.unwrap();

        // Получатель не должен получить фрейм — таймаут ожидаем.
        let res = tokio::time::timeout(Duration::from_millis(300), h_resp.recv_frame()).await;
        assert!(res.is_err(), "responder must NOT decrypt with wrong keys");

        h_init.shutdown();
        h_resp.shutdown();
        h_init.join().await.unwrap();
        h_resp.join().await.unwrap();
    }

    /// Сессия стартует без peer'а; peer задаётся через `set_peer` уже после
    /// bind'а. После этого обмен фреймами должен работать.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn deferred_peer_via_set_peer() {
        let s_init = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let s_resp = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let addr_init = s_init.local_addr().unwrap();
        let addr_resp = s_resp.local_addr().unwrap();

        let keys_init = StreamKeys::derive(&master(), &sid(), Role::Initiator);
        let keys_resp = StreamKeys::derive(&master(), &sid(), Role::Responder);

        let h_init = spawn_session(
            s_init,
            SessionParams {
                role: Role::Initiator,
                peer: None,
            },
            keys_init,
            16,
            16,
        );
        let mut h_resp = spawn_session(
            s_resp,
            SessionParams {
                role: Role::Responder,
                peer: None,
            },
            keys_resp,
            16,
            16,
        );

        // Сообщим обеим сторонам peer'ов после bind.
        h_init.set_peer(addr_resp);
        h_resp.set_peer(addr_init);

        h_init.send_opus(vec![10, 20, 30]).await.unwrap();
        let frame = tokio::time::timeout(Duration::from_secs(1), h_resp.recv_frame())
            .await
            .expect("timed out")
            .expect("session closed");
        assert_eq!(frame.opus, vec![10, 20, 30]);

        // local_addr читается.
        assert!(h_init.local_addr().port() > 0);

        h_init.shutdown();
        h_resp.shutdown();
        h_init.join().await.unwrap();
        h_resp.join().await.unwrap();
    }

    /// Сессия может ответить на входящий STUN Binding Request: ответ Binding
    /// Success с XOR-MAPPED-ADDRESS = адресу запрашивающего. Это позволяет
    /// peer'у проверить связность через нашу сессию.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn session_responds_to_stun_binding_request() {
        use super::super::stun::{
            build_binding_request, fresh_transaction_id, parse_xor_mapped_address,
        };

        let s_session = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let session_addr = s_session.local_addr().unwrap();

        let keys = StreamKeys::derive(&master(), &sid(), Role::Initiator);
        let h = spawn_session(
            s_session,
            SessionParams {
                role: Role::Initiator,
                peer: None,
            },
            keys,
            16,
            16,
        );

        // Эмулируем «peer» — отдельный UDP-сокет, шлёт Binding Request в сессию.
        let prober = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let prober_addr = prober.local_addr().unwrap();
        let tid = fresh_transaction_id();
        let req = build_binding_request(&tid);
        prober.send_to(&req, session_addr).await.unwrap();

        let mut buf = vec![0u8; 1500];
        let (len, from) = tokio::time::timeout(Duration::from_secs(1), prober.recv_from(&mut buf))
            .await
            .expect("session should reply to stun")
            .unwrap();
        assert_eq!(from, session_addr);
        let mapped = parse_xor_mapped_address(&buf[..len], &tid).expect("xor-mapped");
        assert_eq!(mapped, prober_addr);

        h.shutdown();
        h.join().await.unwrap();
    }

    /// `SessionHandle::stun_discover` посылает Binding Request через сокет
    /// сессии и возвращает reflexive-адрес из ответа стороннего «STUN-server»'а.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn session_stun_discover_returns_reflexive() {
        use super::super::stun::{
            ATTR_XOR_MAPPED_ADDRESS, MAGIC_COOKIE, build_binding_success, parse_header,
        };
        let _ = (ATTR_XOR_MAPPED_ADDRESS, MAGIC_COOKIE); // shut warnings

        let server_sock = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let server_addr = server_sock.local_addr().unwrap();
        let server_task = tokio::spawn(async move {
            let mut buf = vec![0u8; 1500];
            let (len, from) = server_sock.recv_from(&mut buf).await.unwrap();
            if let Some((_mt, tid)) = parse_header(&buf[..len]) {
                let resp = build_binding_success(&tid, from);
                server_sock.send_to(&resp, from).await.unwrap();
            }
        });

        let session_sock = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let session_local = session_sock.local_addr().unwrap();
        let keys = StreamKeys::derive(&master(), &sid(), Role::Initiator);
        let h = spawn_session(
            session_sock,
            SessionParams {
                role: Role::Initiator,
                peer: None,
            },
            keys,
            16,
            16,
        );

        let reflexive = h
            .stun_discover(server_addr, Duration::from_secs(2))
            .await
            .expect("stun discover");
        assert_eq!(reflexive, session_local);

        server_task.await.unwrap();
        h.shutdown();
        h.join().await.unwrap();
    }

    /// Ответчик стартует без peer'а — первый валидный пакет от инициатора
    /// автоматически фиксирует peer (auto-discovery), и обратные пакеты идут
    /// туда же.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn responder_auto_discovers_peer() {
        let s_init = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let s_resp = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let addr_resp = s_resp.local_addr().unwrap();

        let keys_init = StreamKeys::derive(&master(), &sid(), Role::Initiator);
        let keys_resp = StreamKeys::derive(&master(), &sid(), Role::Responder);

        let mut h_init = spawn_session(
            s_init,
            SessionParams {
                role: Role::Initiator,
                peer: Some(addr_resp),
            },
            keys_init,
            16,
            16,
        );
        let mut h_resp = spawn_session(
            s_resp,
            SessionParams {
                role: Role::Responder,
                peer: None, // auto-discover
            },
            keys_resp,
            16,
            16,
        );

        h_init.send_opus(vec![7, 7, 7]).await.unwrap();
        let frame = tokio::time::timeout(Duration::from_secs(1), h_resp.recv_frame())
            .await
            .expect("timed out")
            .expect("session closed");
        assert_eq!(frame.opus, vec![7, 7, 7]);
        // Теперь peer ответчика автоматически зафиксирован.
        assert!(h_resp.peer().is_some());

        // Обратный фрейм должен дойти.
        h_resp.send_opus(vec![9, 9]).await.unwrap();
        let back = tokio::time::timeout(Duration::from_secs(1), h_init.recv_frame())
            .await
            .expect("timed out")
            .expect("session closed");
        assert_eq!(back.opus, vec![9, 9]);

        h_init.shutdown();
        h_resp.shutdown();
        h_init.join().await.unwrap();
        h_resp.join().await.unwrap();
    }

    /// Мультиплекс: voice и video идут по одному сокету, разводятся по
    /// stream_id. Обе стороны получают свои фреймы с правильными tag'ами.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn voice_and_video_multiplex_round_trip() {
        use super::super::packet::flags::FRAME_START;

        let s_init = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let s_resp = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let addr_init = s_init.local_addr().unwrap();
        let addr_resp = s_resp.local_addr().unwrap();

        let keys_init = StreamKeys::derive(&master(), &sid(), Role::Initiator);
        let keys_resp = StreamKeys::derive(&master(), &sid(), Role::Responder);

        let h_init = spawn_session(
            s_init,
            SessionParams {
                role: Role::Initiator,
                peer: Some(addr_resp),
            },
            keys_init,
            16,
            32,
        );
        let mut h_resp = spawn_session(
            s_resp,
            SessionParams {
                role: Role::Responder,
                peer: Some(addr_init),
            },
            keys_resp,
            16,
            32,
        );

        // Голосовой фрейм.
        h_init.send_opus(vec![1, 2, 3]).await.unwrap();
        // Видеокадр из двух фрагментов: первый с FRAME_START.
        h_init
            .send_video(VideoOutboundPacket {
                flags: FRAME_START,
                rtp_timestamp: 9000,
                payload: vec![0xAA, 0xBB],
            })
            .await
            .unwrap();
        h_init
            .send_video(VideoOutboundPacket {
                flags: 0,
                rtp_timestamp: 9000,
                payload: vec![0xCC, 0xDD, 0xEE],
            })
            .await
            .unwrap();

        // На стороне ответчика принимаем оба потока и разводим по StreamId.
        let mut voice = Vec::new();
        let mut video = Vec::new();
        for _ in 0..3 {
            let f = tokio::time::timeout(Duration::from_secs(1), h_resp.recv_frame())
                .await
                .expect("timeout")
                .expect("closed");
            match f.stream {
                StreamId::Voice => voice.push(f),
                StreamId::Video => video.push(f),
            }
        }
        assert_eq!(voice.len(), 1);
        assert_eq!(voice[0].opus, vec![1, 2, 3]);
        assert_eq!(video.len(), 2);
        // Фрагменты пришли в порядке отправки (per-stream seq 0,1).
        assert_eq!(video[0].sequence, 0);
        assert_eq!(video[1].sequence, 1);
        assert_eq!(video[0].rtp_timestamp, 9000);
        assert_eq!(video[1].rtp_timestamp, 9000);
        assert_eq!(video[0].flags & FRAME_START, FRAME_START);
        assert_eq!(video[1].flags & FRAME_START, 0);
        assert_eq!(video[0].opus, vec![0xAA, 0xBB]);
        assert_eq!(video[1].opus, vec![0xCC, 0xDD, 0xEE]);

        h_init.shutdown();
        h_resp.shutdown();
        h_init.join().await.unwrap();
        h_resp.join().await.unwrap();
    }
}
