//! Минимальный STUN/TURN UDP-listener для VoIP.
//!
//! STUN-часть отвечает на `Binding Request` через `XOR-MAPPED-ADDRESS`. TURN-
//! часть реализует lightweight relay для клиентов Paranoia: `Allocate`,
//! `Refresh`, `CreatePermission`, `Send Indication` и `Data Indication` без
//! long-term credentials. Media остаётся E2E-зашифрованной на клиенте, сервер
//! ретранслирует только ciphertext.

use std::{
    collections::HashMap,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use anyhow::Context;
use tokio::{
    net::UdpSocket,
    sync::{Mutex, Notify},
    time::Instant,
};
use tracing::{debug, info, trace, warn};

pub const MAGIC_COOKIE: u32 = 0x2112_A442;
const HEADER_LEN: usize = 20;
const MAX_UDP_PACKET: usize = 2048;
const TURN_LIFETIME_SECONDS: u32 = 600;

const METHOD_BINDING: u16 = 0x001;
const METHOD_ALLOCATE: u16 = 0x003;
const METHOD_REFRESH: u16 = 0x004;
const METHOD_SEND: u16 = 0x006;
const METHOD_DATA: u16 = 0x007;
const METHOD_CREATE_PERMISSION: u16 = 0x008;

const MSG_TYPE_BINDING_REQUEST: u16 = 0x0001;
const MSG_TYPE_BINDING_SUCCESS: u16 = 0x0101;

const ATTR_ERROR_CODE: u16 = 0x0009;
const ATTR_LIFETIME: u16 = 0x000D;
const ATTR_XOR_PEER_ADDRESS: u16 = 0x0012;
const ATTR_DATA: u16 = 0x0013;
const ATTR_XOR_RELAYED_ADDRESS: u16 = 0x0016;
const ATTR_REQUESTED_TRANSPORT: u16 = 0x0019;
const ATTR_XOR_MAPPED_ADDRESS: u16 = 0x0020;
const ATTR_SOFTWARE: u16 = 0x8022;
const TRANSPORT_UDP: u8 = 17;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Class {
    Request,
    Indication,
    SuccessResponse,
    ErrorResponse,
}

#[derive(Debug, Clone)]
struct Attribute {
    typ: u16,
    value: Vec<u8>,
}

#[derive(Debug, Clone)]
struct Message {
    method: u16,
    class: Class,
    tid: [u8; 12],
    attrs: Vec<Attribute>,
}

impl Message {
    fn find(&self, typ: u16) -> Option<&[u8]> {
        self.attrs
            .iter()
            .find(|a| a.typ == typ)
            .map(|a| a.value.as_slice())
    }
}

#[derive(Clone)]
struct Allocation {
    relay_socket: Arc<UdpSocket>,
    relayed_addr: SocketAddr,
    expires_at: Instant,
    shutdown: Arc<Notify>,
}

type Allocations = Arc<Mutex<HashMap<SocketAddr, Allocation>>>;

fn padded_len(len: usize) -> usize {
    (len + 3) & !3
}

fn make_message_type(method: u16, class: Class) -> u16 {
    let c = match class {
        Class::Request => 0b00,
        Class::Indication => 0b01,
        Class::SuccessResponse => 0b10,
        Class::ErrorResponse => 0b11,
    };
    let c0 = c & 0b01;
    let c1 = (c & 0b10) >> 1;
    let m3_0 = method & 0x000F;
    let m6_4 = (method & 0x0070) >> 4;
    let m11_7 = (method & 0x0F80) >> 7;
    (m11_7 << 9) | (c1 << 8) | (m6_4 << 5) | (c0 << 4) | m3_0
}

fn parse_message_type(t: u16) -> (u16, Class) {
    let c0 = (t & 0x0010) >> 4;
    let c1 = (t & 0x0100) >> 8;
    let class = match (c1 << 1) | c0 {
        0b00 => Class::Request,
        0b01 => Class::Indication,
        0b10 => Class::SuccessResponse,
        0b11 => Class::ErrorResponse,
        _ => unreachable!(),
    };
    let m3_0 = t & 0x000F;
    let m6_4 = (t & 0x00E0) >> 1;
    let m11_7 = (t & 0x3E00) >> 2;
    (m11_7 | m6_4 | m3_0, class)
}

/// Проверка заголовка STUN/TURN-сообщения. Возвращает `(message_type,
/// transaction_id)` либо `None`, если формат не соответствует.
fn parse_header(msg: &[u8]) -> Option<(u16, [u8; 12])> {
    if msg.len() < HEADER_LEN {
        return None;
    }
    let cookie = u32::from_be_bytes(msg[4..8].try_into().ok()?);
    if cookie != MAGIC_COOKIE {
        return None;
    }
    let msg_type = u16::from_be_bytes([msg[0], msg[1]]);
    let length = u16::from_be_bytes([msg[2], msg[3]]) as usize;
    if msg.len() < HEADER_LEN + length {
        return None;
    }
    // Старшие два бита должны быть нули (STUN message).
    if msg[0] & 0xC0 != 0 {
        return None;
    }
    let mut tid = [0u8; 12];
    tid.copy_from_slice(&msg[8..20]);
    Some((msg_type, tid))
}

fn parse_message(msg: &[u8]) -> Option<Message> {
    let (message_type, tid) = parse_header(msg)?;
    let (method, class) = parse_message_type(message_type);
    let length = u16::from_be_bytes([msg[2], msg[3]]) as usize;
    let end = HEADER_LEN + length;
    let mut pos = HEADER_LEN;
    let mut attrs = Vec::new();
    while pos + 4 <= end {
        let typ = u16::from_be_bytes([msg[pos], msg[pos + 1]]);
        let len = u16::from_be_bytes([msg[pos + 2], msg[pos + 3]]) as usize;
        let value_start = pos + 4;
        if value_start + len > end {
            return None;
        }
        attrs.push(Attribute {
            typ,
            value: msg[value_start..value_start + len].to_vec(),
        });
        pos = value_start + padded_len(len);
    }
    Some(Message {
        method,
        class,
        tid,
        attrs,
    })
}

fn build_message(method: u16, class: Class, tid: &[u8; 12], attrs: &[(u16, Vec<u8>)]) -> Vec<u8> {
    let attrs_len: usize = attrs
        .iter()
        .map(|(_, value)| 4 + padded_len(value.len()))
        .sum();
    let mut out = Vec::with_capacity(HEADER_LEN + attrs_len);
    out.extend_from_slice(&make_message_type(method, class).to_be_bytes());
    out.extend_from_slice(&(attrs_len as u16).to_be_bytes());
    out.extend_from_slice(&MAGIC_COOKIE.to_be_bytes());
    out.extend_from_slice(tid);
    for (typ, value) in attrs {
        out.extend_from_slice(&typ.to_be_bytes());
        out.extend_from_slice(&(value.len() as u16).to_be_bytes());
        out.extend_from_slice(value);
        out.extend(std::iter::repeat(0u8).take(padded_len(value.len()) - value.len()));
    }
    out
}

fn encode_xor_address(addr: SocketAddr, tid: &[u8; 12]) -> Vec<u8> {
    let cookie = MAGIC_COOKIE.to_be_bytes();
    let port_xor = addr.port() ^ ((MAGIC_COOKIE >> 16) as u16);
    match addr.ip() {
        IpAddr::V4(v4) => {
            let octets = v4.octets();
            let mut v = Vec::with_capacity(8);
            v.push(0);
            v.push(0x01);
            v.extend_from_slice(&port_xor.to_be_bytes());
            for i in 0..4 {
                v.push(octets[i] ^ cookie[i]);
            }
            v
        }
        IpAddr::V6(v6) => {
            let octets = v6.octets();
            let mut key = [0u8; 16];
            key[..4].copy_from_slice(&cookie);
            key[4..].copy_from_slice(tid);
            let mut v = Vec::with_capacity(20);
            v.push(0);
            v.push(0x02);
            v.extend_from_slice(&port_xor.to_be_bytes());
            for i in 0..16 {
                v.push(octets[i] ^ key[i]);
            }
            v
        }
    }
}

fn decode_xor_address(value: &[u8], tid: &[u8; 12]) -> Option<SocketAddr> {
    if value.len() < 4 {
        return None;
    }
    let family = value[1];
    let port = u16::from_be_bytes([value[2], value[3]]) ^ ((MAGIC_COOKIE >> 16) as u16);
    let cookie = MAGIC_COOKIE.to_be_bytes();
    match family {
        0x01 => {
            if value.len() < 8 {
                return None;
            }
            let mut octets = [0u8; 4];
            for i in 0..4 {
                octets[i] = value[4 + i] ^ cookie[i];
            }
            Some(SocketAddr::new(IpAddr::V4(Ipv4Addr::from(octets)), port))
        }
        0x02 => {
            if value.len() < 20 {
                return None;
            }
            let mut key = [0u8; 16];
            key[..4].copy_from_slice(&cookie);
            key[4..].copy_from_slice(tid);
            let mut octets = [0u8; 16];
            for i in 0..16 {
                octets[i] = value[4 + i] ^ key[i];
            }
            Some(SocketAddr::new(IpAddr::V6(Ipv6Addr::from(octets)), port))
        }
        _ => None,
    }
}

fn build_binding_success(tid: &[u8; 12], mapped: SocketAddr) -> Vec<u8> {
    build_message(
        METHOD_BINDING,
        Class::SuccessResponse,
        tid,
        &[(ATTR_XOR_MAPPED_ADDRESS, encode_xor_address(mapped, tid))],
    )
}

fn build_success(method: u16, tid: &[u8; 12], attrs: &[(u16, Vec<u8>)]) -> Vec<u8> {
    build_message(method, Class::SuccessResponse, tid, attrs)
}

fn build_error(method: u16, tid: &[u8; 12], code: u16, reason: &str) -> Vec<u8> {
    let class = (code / 100) as u8;
    let number = (code % 100) as u8;
    let mut value = vec![0, 0, class, number];
    value.extend_from_slice(reason.as_bytes());
    build_message(
        method,
        Class::ErrorResponse,
        tid,
        &[
            (ATTR_ERROR_CODE, value),
            (ATTR_SOFTWARE, b"Paranoia TURN".to_vec()),
        ],
    )
}

fn build_data_indication(peer: SocketAddr, data: &[u8]) -> Vec<u8> {
    let tid = pseudo_transaction_id();
    build_message(
        METHOD_DATA,
        Class::Indication,
        &tid,
        &[
            (ATTR_XOR_PEER_ADDRESS, encode_xor_address(peer, &tid)),
            (ATTR_DATA, data.to_vec()),
        ],
    )
}

fn pseudo_transaction_id() -> [u8; 12] {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let bytes = nanos.to_be_bytes();
    let mut tid = [0u8; 12];
    tid.copy_from_slice(&bytes[4..16]);
    tid
}

fn parse_lifetime(msg: &Message) -> u32 {
    msg.find(ATTR_LIFETIME)
        .and_then(|v| (v.len() == 4).then(|| u32::from_be_bytes([v[0], v[1], v[2], v[3]])))
        .unwrap_or(TURN_LIFETIME_SECONDS)
}

fn relay_bind_addr(control_bind: SocketAddr, client: SocketAddr) -> SocketAddr {
    let ip = match (client.ip(), control_bind.ip()) {
        (IpAddr::V4(_), IpAddr::V4(bind_ip)) if !bind_ip.is_unspecified() => IpAddr::V4(bind_ip),
        (IpAddr::V4(_), _) => IpAddr::V4(Ipv4Addr::UNSPECIFIED),
        (IpAddr::V6(_), IpAddr::V6(bind_ip)) if !bind_ip.is_unspecified() => IpAddr::V6(bind_ip),
        (IpAddr::V6(_), _) => IpAddr::V6(Ipv6Addr::UNSPECIFIED),
    };
    SocketAddr::new(ip, 0)
}

fn public_addr(local: SocketAddr, public_ip: Option<IpAddr>) -> SocketAddr {
    public_ip
        .map(|ip| SocketAddr::new(ip, local.port()))
        .unwrap_or(local)
}

async fn relay_loop(
    relay_socket: Arc<UdpSocket>,
    control_socket: Arc<UdpSocket>,
    client: SocketAddr,
    shutdown: Arc<Notify>,
) {
    let mut buf = vec![0u8; MAX_UDP_PACKET];
    loop {
        tokio::select! {
            recv = relay_socket.recv_from(&mut buf) => {
                match recv {
                    Ok((len, peer)) => {
                        let indication = build_data_indication(peer, &buf[..len]);
                        if let Err(e) = control_socket.send_to(&indication, client).await {
                            debug!("TURN relay data to {client} failed: {e}");
                        }
                    }
                    Err(e) => {
                        debug!("TURN relay recv failed: {e}");
                        break;
                    }
                }
            }
            _ = shutdown.notified() => break,
        }
    }
}

async fn get_or_create_allocation(
    socket: Arc<UdpSocket>,
    allocations: Allocations,
    control_bind: SocketAddr,
    public_ip: Option<IpAddr>,
    client: SocketAddr,
) -> anyhow::Result<Allocation> {
    let now = Instant::now();
    {
        let mut guard = allocations.lock().await;
        if let Some(existing) = guard.get_mut(&client) {
            if existing.expires_at > now {
                existing.expires_at = now + Duration::from_secs(TURN_LIFETIME_SECONDS as u64);
                return Ok(existing.clone());
            }
            let expired = guard.remove(&client).expect("checked existing");
            expired.shutdown.notify_waiters();
        }
    }

    let relay_socket = Arc::new(UdpSocket::bind(relay_bind_addr(control_bind, client)).await?);
    let local = relay_socket.local_addr()?;
    let relayed_addr = public_addr(local, public_ip);
    let shutdown = Arc::new(Notify::new());
    tokio::spawn(relay_loop(
        Arc::clone(&relay_socket),
        socket,
        client,
        Arc::clone(&shutdown),
    ));
    let allocation = Allocation {
        relay_socket,
        relayed_addr,
        expires_at: now + Duration::from_secs(TURN_LIFETIME_SECONDS as u64),
        shutdown,
    };
    allocations.lock().await.insert(client, allocation.clone());
    info!("TURN allocated {relayed_addr} for {client}");
    Ok(allocation)
}

async fn handle_allocate(
    socket: Arc<UdpSocket>,
    allocations: Allocations,
    bind: SocketAddr,
    public_ip: Option<IpAddr>,
    from: SocketAddr,
    msg: &Message,
) {
    let requested_udp = msg
        .find(ATTR_REQUESTED_TRANSPORT)
        .is_some_and(|v| v.len() == 4 && v[0] == TRANSPORT_UDP);
    if !requested_udp {
        let resp = build_error(METHOD_ALLOCATE, &msg.tid, 400, "Bad Request");
        let _ = socket.send_to(&resp, from).await;
        return;
    }
    match get_or_create_allocation(Arc::clone(&socket), allocations, bind, public_ip, from).await {
        Ok(allocation) => {
            let attrs = [
                (
                    ATTR_XOR_RELAYED_ADDRESS,
                    encode_xor_address(allocation.relayed_addr, &msg.tid),
                ),
                (ATTR_XOR_MAPPED_ADDRESS, encode_xor_address(from, &msg.tid)),
                (ATTR_LIFETIME, TURN_LIFETIME_SECONDS.to_be_bytes().to_vec()),
                (ATTR_SOFTWARE, b"Paranoia TURN".to_vec()),
            ];
            let resp = build_success(METHOD_ALLOCATE, &msg.tid, &attrs);
            let _ = socket.send_to(&resp, from).await;
        }
        Err(e) => {
            warn!("TURN allocation for {from} failed: {e}");
            let resp = build_error(METHOD_ALLOCATE, &msg.tid, 508, "Insufficient Capacity");
            let _ = socket.send_to(&resp, from).await;
        }
    }
}

async fn handle_refresh(
    socket: Arc<UdpSocket>,
    allocations: Allocations,
    from: SocketAddr,
    msg: &Message,
) {
    let lifetime = parse_lifetime(msg);
    let mut guard = allocations.lock().await;
    if lifetime == 0 {
        if let Some(allocation) = guard.remove(&from) {
            allocation.shutdown.notify_waiters();
        }
    } else if let Some(allocation) = guard.get_mut(&from) {
        allocation.expires_at = Instant::now() + Duration::from_secs(lifetime as u64);
    }
    drop(guard);
    let attrs = [(ATTR_LIFETIME, lifetime.to_be_bytes().to_vec())];
    let resp = build_success(METHOD_REFRESH, &msg.tid, &attrs);
    let _ = socket.send_to(&resp, from).await;
}

async fn handle_create_permission(socket: Arc<UdpSocket>, from: SocketAddr, msg: &Message) {
    let resp = build_success(METHOD_CREATE_PERMISSION, &msg.tid, &[]);
    let _ = socket.send_to(&resp, from).await;
}

async fn handle_send(socket: Arc<UdpSocket>, allocations: Allocations, from: SocketAddr, msg: &Message) {
    let Some(peer) = msg
        .find(ATTR_XOR_PEER_ADDRESS)
        .and_then(|v| decode_xor_address(v, &msg.tid))
    else {
        trace!("TURN Send from {from} without XOR-PEER-ADDRESS");
        return;
    };
    let Some(data) = msg.find(ATTR_DATA) else {
        trace!("TURN Send from {from} without DATA");
        return;
    };
    let (relay_socket, source_relay, local_destination) = {
        let mut guard = allocations.lock().await;
        let (relay_socket, source_relay) = {
            let Some(allocation) = guard.get_mut(&from) else {
                trace!("TURN Send from {from} without allocation");
                return;
            };
            allocation.expires_at = Instant::now() + Duration::from_secs(TURN_LIFETIME_SECONDS as u64);
            (Arc::clone(&allocation.relay_socket), allocation.relayed_addr)
        };
        let local_destination = guard
            .iter()
            .find_map(|(client, allocation)| (allocation.relayed_addr == peer).then_some(*client));
        (relay_socket, source_relay, local_destination)
    };
    if let Some(destination_client) = local_destination {
        let indication = build_data_indication(source_relay, data);
        if let Err(e) = socket.send_to(&indication, destination_client).await {
            debug!("TURN local relay to {destination_client} failed: {e}");
        }
        return;
    }
    if let Err(e) = relay_socket.send_to(data, peer).await {
        debug!("TURN Send relay to {peer} failed: {e}");
    }
}

async fn spawn_gc(allocations: Allocations) {
    let mut interval = tokio::time::interval(Duration::from_secs(30));
    loop {
        interval.tick().await;
        let now = Instant::now();
        let mut expired = Vec::new();
        {
            let guard = allocations.lock().await;
            for (client, allocation) in guard.iter() {
                if allocation.expires_at <= now {
                    expired.push(*client);
                }
            }
        }
        if expired.is_empty() {
            continue;
        }
        let mut guard = allocations.lock().await;
        for client in expired {
            if let Some(allocation) = guard.remove(&client) {
                allocation.shutdown.notify_waiters();
                info!("TURN allocation expired for {client}");
            }
        }
    }
}

/// Слушать STUN/TURN-запросы на `bind`. `turn_public_ip` нужен, если listener
/// биндим на `0.0.0.0`, а клиентам надо отдать публичный IP в relayed address.
pub async fn run(bind: SocketAddr, turn_public_ip: Option<IpAddr>) -> anyhow::Result<()> {
    let socket = Arc::new(
        UdpSocket::bind(bind)
            .await
            .with_context(|| format!("STUN/TURN bind on {bind}"))?,
    );
    let local = socket.local_addr().unwrap_or(bind);
    info!("Paranoia STUN/TURN listening on udp://{local}");
    if let Some(ip) = turn_public_ip {
        info!("Paranoia TURN public relay IP: {ip}");
    }

    let allocations: Allocations = Arc::new(Mutex::new(HashMap::new()));
    tokio::spawn(spawn_gc(Arc::clone(&allocations)));

    let mut buf = vec![0u8; MAX_UDP_PACKET];
    loop {
        let (len, from) = match socket.recv_from(&mut buf).await {
            Ok(v) => v,
            Err(e) => {
                warn!("STUN/TURN recv_from failed: {e}");
                continue;
            }
        };
        let data = &buf[..len];
        let Some(msg) = parse_message(data) else {
            trace!("STUN/TURN: dropping non-STUN packet from {from} ({len} bytes)");
            continue;
        };
        match (msg.method, msg.class) {
            (METHOD_BINDING, Class::Request) => {
                let resp = build_binding_success(&msg.tid, from);
                match socket.send_to(&resp, from).await {
                    Ok(_) => trace!("STUN: reflected {from}"),
                    Err(e) => debug!("STUN: send to {from} failed: {e}"),
                }
            }
            (METHOD_ALLOCATE, Class::Request) => {
                handle_allocate(
                    Arc::clone(&socket),
                    Arc::clone(&allocations),
                    local,
                    turn_public_ip,
                    from,
                    &msg,
                )
                .await;
            }
            (METHOD_REFRESH, Class::Request) => {
                handle_refresh(Arc::clone(&socket), Arc::clone(&allocations), from, &msg).await;
            }
            (METHOD_CREATE_PERMISSION, Class::Request) => {
                handle_create_permission(Arc::clone(&socket), from, &msg).await;
            }
            (METHOD_SEND, Class::Indication) => {
                handle_send(Arc::clone(&socket), Arc::clone(&allocations), from, &msg).await;
            }
            _ => debug!(
                "STUN/TURN: ignoring method={} class={:?} from {from}",
                msg.method, msg.class
            ),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{Ipv4Addr, SocketAddrV4};

    #[test]
    fn build_and_parse_roundtrip_ipv4() {
        let tid = [
            0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc,
        ];
        let from = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::new(203, 0, 113, 7), 51234));
        let resp = build_binding_success(&tid, from);
        assert!(resp.len() >= HEADER_LEN + 4 + 8);
        let (msg_type, parsed_tid) = parse_header(&resp).expect("valid header");
        assert_eq!(msg_type, MSG_TYPE_BINDING_SUCCESS);
        assert_eq!(parsed_tid, tid);
        let len = u16::from_be_bytes([resp[2], resp[3]]);
        assert_eq!(len as usize, 4 + 8);
    }

    #[test]
    fn parse_header_rejects_bad_cookie() {
        let mut msg = [0u8; HEADER_LEN];
        msg[0..2].copy_from_slice(&MSG_TYPE_BINDING_REQUEST.to_be_bytes());
        msg[4..8].copy_from_slice(&0xDEADBEEFu32.to_be_bytes());
        assert!(parse_header(&msg).is_none());
    }

    #[test]
    fn parse_header_rejects_high_bits() {
        let mut msg = [0u8; HEADER_LEN];
        msg[0] = 0x80;
        msg[4..8].copy_from_slice(&MAGIC_COOKIE.to_be_bytes());
        assert!(parse_header(&msg).is_none());
    }

    #[test]
    fn allocate_request_parses_requested_transport() {
        let tid = [0x44; 12];
        let raw = build_message(
            METHOD_ALLOCATE,
            Class::Request,
            &tid,
            &[(ATTR_REQUESTED_TRANSPORT, vec![TRANSPORT_UDP, 0, 0, 0])],
        );
        let msg = parse_message(&raw).expect("parse allocate");
        assert_eq!(msg.method, METHOD_ALLOCATE);
        assert_eq!(msg.class, Class::Request);
        assert_eq!(msg.tid, tid);
        assert!(
            msg.find(ATTR_REQUESTED_TRANSPORT)
                .is_some_and(|v| v == [TRANSPORT_UDP, 0, 0, 0])
        );
    }

    #[test]
    fn data_indication_roundtrip() {
        let peer: SocketAddr = "198.51.100.10:4444".parse().unwrap();
        let payload = b"encrypted-media";
        let raw = build_data_indication(peer, payload);
        let msg = parse_message(&raw).expect("parse data");
        assert_eq!(msg.method, METHOD_DATA);
        assert_eq!(msg.class, Class::Indication);
        assert_eq!(
            msg.find(ATTR_XOR_PEER_ADDRESS)
                .and_then(|v| decode_xor_address(v, &msg.tid)),
            Some(peer)
        );
        assert_eq!(msg.find(ATTR_DATA), Some(payload.as_slice()));
    }
}
