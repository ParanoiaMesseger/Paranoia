//! Минимальный STUN-клиент (RFC 8489): Binding Request → XOR-MAPPED-ADDRESS.
//!
//! Поддерживается ровно то, что нужно для определения публичного IP:port —
//! ICE/TURN/short-term/long-term auth не реализованы. Это утилитарный модуль:
//! [`voip::transport`] детектирует STUN-пакеты по magic cookie и в будущем
//! сможет дёргать этот парсер для NAT keep-alive / connectivity checks.
//!
//! Поверх него экспортирована async-функция [`discover_reflexive`], которая
//! шлёт один Binding Request через переданный `UdpSocket` и читает ответ с
//! таймаутом.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::time::Duration;

use anyhow::{Result, bail};
use rand::RngCore;
use tokio::net::UdpSocket;

/// STUN magic cookie (RFC 8489), идёт по смещению 4..8 каждого сообщения.
pub const MAGIC_COOKIE: u32 = 0x2112_A442;
pub const HEADER_LEN: usize = 20;

/// Тип сообщения: Binding Request (0x0001).
pub const MSG_TYPE_BINDING_REQUEST: u16 = 0x0001;
/// Тип сообщения: Binding Success Response (0x0101).
pub const MSG_TYPE_BINDING_SUCCESS: u16 = 0x0101;
/// Тип сообщения: Binding Error Response (0x0111).
pub const MSG_TYPE_BINDING_ERROR: u16 = 0x0111;

/// Атрибут MAPPED-ADDRESS (0x0001) — историческое, не используется обычно.
pub const ATTR_MAPPED_ADDRESS: u16 = 0x0001;
/// Атрибут XOR-MAPPED-ADDRESS (0x0020) — основное, что нам нужно.
pub const ATTR_XOR_MAPPED_ADDRESS: u16 = 0x0020;

/// Сгенерировать новый transaction ID (12 случайных байт).
pub fn fresh_transaction_id() -> [u8; 12] {
    let mut id = [0u8; 12];
    rand::rngs::OsRng.fill_bytes(&mut id);
    id
}

/// Построить Binding Request без атрибутов.
pub fn build_binding_request(transaction_id: &[u8; 12]) -> [u8; HEADER_LEN] {
    let mut buf = [0u8; HEADER_LEN];
    buf[0..2].copy_from_slice(&MSG_TYPE_BINDING_REQUEST.to_be_bytes());
    buf[2..4].copy_from_slice(&0u16.to_be_bytes()); // message length (без атрибутов)
    buf[4..8].copy_from_slice(&MAGIC_COOKIE.to_be_bytes());
    buf[8..20].copy_from_slice(transaction_id);
    buf
}

/// Тип сообщения и transaction_id из заголовка STUN-пакета. Возвращает None
/// если пакет короче заголовка или magic cookie не совпадает.
pub fn parse_header(msg: &[u8]) -> Option<(u16, [u8; 12])> {
    if msg.len() < HEADER_LEN {
        return None;
    }
    let cookie = u32::from_be_bytes([msg[4], msg[5], msg[6], msg[7]]);
    if cookie != MAGIC_COOKIE {
        return None;
    }
    let msg_type = u16::from_be_bytes([msg[0], msg[1]]);
    let mut tid = [0u8; 12];
    tid.copy_from_slice(&msg[8..20]);
    Some((msg_type, tid))
}

/// Построить Binding Success Response с одним атрибутом XOR-MAPPED-ADDRESS,
/// указывающим на `mapped` (адрес отправителя запроса).
pub fn build_binding_success(transaction_id: &[u8; 12], mapped: SocketAddr) -> Vec<u8> {
    let cookie_bytes = MAGIC_COOKIE.to_be_bytes();
    let xor_port = mapped.port() ^ ((MAGIC_COOKIE >> 16) as u16);

    let attr_value: Vec<u8> = match mapped.ip() {
        IpAddr::V4(v4) => {
            let mut v = Vec::with_capacity(8);
            v.push(0x00); // reserved
            v.push(0x01); // family v4
            v.extend_from_slice(&xor_port.to_be_bytes());
            let octets = v4.octets();
            for i in 0..4 {
                v.push(octets[i] ^ cookie_bytes[i]);
            }
            v
        }
        IpAddr::V6(v6) => {
            let mut v = Vec::with_capacity(20);
            v.push(0x00);
            v.push(0x02); // family v6
            v.extend_from_slice(&xor_port.to_be_bytes());
            let octets = v6.octets();
            // xor с cookie(4) || tid(12) = 16 байт
            let mut key = [0u8; 16];
            key[..4].copy_from_slice(&cookie_bytes);
            key[4..].copy_from_slice(transaction_id);
            for i in 0..16 {
                v.push(octets[i] ^ key[i]);
            }
            v
        }
    };

    let attr_total = 4 + attr_value.len(); // тип(2)+длина(2)+тело
    let msg_len = attr_total as u16;
    let mut msg = Vec::with_capacity(HEADER_LEN + attr_total);
    msg.extend_from_slice(&MSG_TYPE_BINDING_SUCCESS.to_be_bytes());
    msg.extend_from_slice(&msg_len.to_be_bytes());
    msg.extend_from_slice(&cookie_bytes);
    msg.extend_from_slice(transaction_id);
    msg.extend_from_slice(&ATTR_XOR_MAPPED_ADDRESS.to_be_bytes());
    msg.extend_from_slice(&(attr_value.len() as u16).to_be_bytes());
    msg.extend_from_slice(&attr_value);
    msg
}

/// Разобрать XOR-MAPPED-ADDRESS из тела сообщения. Возвращает Some(adress)
/// или None если атрибут не найден / тип не Binding Success / транзакция не
/// совпала / парсинг провалился.
pub fn parse_xor_mapped_address(
    msg: &[u8],
    expected_transaction_id: &[u8; 12],
) -> Option<SocketAddr> {
    if msg.len() < HEADER_LEN {
        return None;
    }
    let msg_type = u16::from_be_bytes([msg[0], msg[1]]);
    if msg_type != MSG_TYPE_BINDING_SUCCESS {
        return None;
    }
    let length = u16::from_be_bytes([msg[2], msg[3]]) as usize;
    if length + HEADER_LEN > msg.len() {
        return None;
    }
    let cookie = u32::from_be_bytes([msg[4], msg[5], msg[6], msg[7]]);
    if cookie != MAGIC_COOKIE {
        return None;
    }
    if &msg[8..20] != expected_transaction_id {
        return None;
    }

    // Перебираем TLV-атрибуты.
    let mut pos = HEADER_LEN;
    while pos + 4 <= HEADER_LEN + length {
        let attr_type = u16::from_be_bytes([msg[pos], msg[pos + 1]]);
        let attr_len = u16::from_be_bytes([msg[pos + 2], msg[pos + 3]]) as usize;
        let value_start = pos + 4;
        if value_start + attr_len > msg.len() {
            return None;
        }
        if attr_type == ATTR_XOR_MAPPED_ADDRESS {
            return parse_xor_mapped_value(&msg[value_start..value_start + attr_len], &msg[4..20]);
        }
        // Атрибуты пэдятся до 4 байт.
        let padded = (attr_len + 3) & !3;
        pos = value_start + padded;
    }
    None
}

/// Внутренний парсер тела атрибута XOR-MAPPED-ADDRESS.
/// `cookie_and_tid` — 16 байт `[MAGIC_COOKIE (4) | transaction_id (12)]`.
fn parse_xor_mapped_value(value: &[u8], cookie_and_tid: &[u8]) -> Option<SocketAddr> {
    if value.len() < 4 {
        return None;
    }
    // value[0] = 0 reserved, value[1] = family, value[2..4] = xor-port, value[4..] = xor-address
    let family = value[1];
    let xor_port = u16::from_be_bytes([value[2], value[3]]);
    let port = xor_port ^ ((MAGIC_COOKIE >> 16) as u16);
    match family {
        0x01 => {
            // IPv4
            if value.len() < 8 {
                return None;
            }
            let mut bytes = [0u8; 4];
            for i in 0..4 {
                bytes[i] = value[4 + i] ^ cookie_and_tid[i];
            }
            Some(SocketAddr::new(IpAddr::V4(Ipv4Addr::from(bytes)), port))
        }
        0x02 => {
            // IPv6: xor с (cookie || transaction_id) = 16 байт.
            if value.len() < 20 {
                return None;
            }
            let mut bytes = [0u8; 16];
            for i in 0..16 {
                bytes[i] = value[4 + i] ^ cookie_and_tid[i];
            }
            Some(SocketAddr::new(IpAddr::V6(Ipv6Addr::from(bytes)), port))
        }
        _ => None,
    }
}

/// Послать Binding Request на заданный STUN-сервер через уже-связанный сокет
/// и дождаться ответа. На stale-пакеты с другим transaction_id не реагируем
/// (читаем дальше, пока не получим наш). `timeout` — общий таймаут операции.
pub async fn discover_reflexive(
    socket: &UdpSocket,
    server: SocketAddr,
    timeout: Duration,
) -> Result<SocketAddr> {
    let tid = fresh_transaction_id();
    let req = build_binding_request(&tid);
    socket.send_to(&req, server).await?;

    let deadline = tokio::time::Instant::now() + timeout;
    let mut buf = vec![0u8; 1500];
    loop {
        let now = tokio::time::Instant::now();
        if now >= deadline {
            bail!("STUN timeout");
        }
        let remaining = deadline - now;
        let recv = tokio::time::timeout(remaining, socket.recv_from(&mut buf)).await;
        match recv {
            Err(_) => bail!("STUN timeout"),
            Ok(Err(e)) => bail!("STUN recv error: {e}"),
            Ok(Ok((len, from))) => {
                // Не сверяем `from`:
                // (1) сервера часто отвечают с отдельного binding'а — порт != 3478;
                // (2) при NAT64 (LTE IPv6-only) запрос идёт на v4-mapped
                //     64:ff9b::/96, ответ возвращается IPv6-маппингом,
                //     отличающимся от IPv4 server.
                // От подмены защищает transaction_id в parse_xor_mapped_address.
                let _ = from;
                if let Some(addr) = parse_xor_mapped_address(&buf[..len], &tid) {
                    return Ok(addr);
                }
                // Игнорируем не наш ответ; ждём дальше до таймаута.
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_binding_request_header_layout() {
        let tid = [0u8; 12];
        let req = build_binding_request(&tid);
        assert_eq!(&req[0..2], &[0x00, 0x01]);
        assert_eq!(&req[2..4], &[0x00, 0x00]);
        assert_eq!(&req[4..8], &[0x21, 0x12, 0xA4, 0x42]);
        assert_eq!(&req[8..20], &tid);
    }

    #[test]
    fn parse_xor_mapped_v4_roundtrip() {
        // Сконструируем валидный Binding Success с XOR-MAPPED-ADDRESS IPv4
        // (203.0.113.1:50000) и убедимся, что парсим обратно.
        let tid = [0xAA; 12];
        let port: u16 = 50000;
        let ip = Ipv4Addr::new(203, 0, 113, 1);
        let xor_port = port ^ ((MAGIC_COOKIE >> 16) as u16);
        let cookie_bytes = MAGIC_COOKIE.to_be_bytes();
        let mut xor_ip = ip.octets();
        for i in 0..4 {
            xor_ip[i] ^= cookie_bytes[i];
        }
        let attr_value = {
            let mut v = Vec::with_capacity(8);
            v.push(0x00); // reserved
            v.push(0x01); // family v4
            v.extend_from_slice(&xor_port.to_be_bytes());
            v.extend_from_slice(&xor_ip);
            v
        };
        let mut msg = Vec::new();
        msg.extend_from_slice(&MSG_TYPE_BINDING_SUCCESS.to_be_bytes());
        msg.extend_from_slice(&((4 + attr_value.len()) as u16).to_be_bytes());
        msg.extend_from_slice(&MAGIC_COOKIE.to_be_bytes());
        msg.extend_from_slice(&tid);
        msg.extend_from_slice(&ATTR_XOR_MAPPED_ADDRESS.to_be_bytes());
        msg.extend_from_slice(&(attr_value.len() as u16).to_be_bytes());
        msg.extend_from_slice(&attr_value);

        let parsed = parse_xor_mapped_address(&msg, &tid).expect("must parse");
        assert_eq!(parsed, SocketAddr::new(IpAddr::V4(ip), port));
    }

    #[test]
    fn parse_ignores_wrong_transaction() {
        let tid = [0xAA; 12];
        let other = [0xBB; 12];
        let msg = build_binding_request(&tid).to_vec();
        // Подменим тип на success, чтобы проверить tid-сверку, а не тип.
        let mut response = msg;
        response[0..2].copy_from_slice(&MSG_TYPE_BINDING_SUCCESS.to_be_bytes());
        assert!(parse_xor_mapped_address(&response, &other).is_none());
    }

    #[test]
    fn build_success_roundtrip_through_parse() {
        let tid = [0x33; 12];
        let mapped: SocketAddr = "198.51.100.7:55555".parse().unwrap();
        let resp = build_binding_success(&tid, mapped);
        let parsed = parse_xor_mapped_address(&resp, &tid).expect("parse");
        assert_eq!(parsed, mapped);
    }

    #[test]
    fn parse_header_extracts_type_and_tid() {
        let tid = [0xAB; 12];
        let req = build_binding_request(&tid);
        let (mt, t) = parse_header(&req).unwrap();
        assert_eq!(mt, MSG_TYPE_BINDING_REQUEST);
        assert_eq!(t, tid);
    }

    #[test]
    fn parse_header_rejects_wrong_cookie() {
        let mut req = build_binding_request(&[0u8; 12]);
        req[4] ^= 0xFF;
        assert!(parse_header(&req).is_none());
    }

    #[test]
    fn parse_rejects_error_response() {
        let tid = [0xAA; 12];
        let mut msg = build_binding_request(&tid).to_vec();
        msg[0..2].copy_from_slice(&MSG_TYPE_BINDING_ERROR.to_be_bytes());
        assert!(parse_xor_mapped_address(&msg, &tid).is_none());
    }

    /// Полный round-trip через локальный «STUN-сервер»: одна Tokio-задача
    /// слушает UDP и отвечает Binding Success, вторая зовёт discover.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn discover_reflexive_local_loopback() {
        let server_sock = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let server_addr = server_sock.local_addr().unwrap();

        // «STUN-сервер»: получает Binding Request → отвечает Binding Success
        // с XOR-MAPPED-ADDRESS == адресу клиента.
        let server_task = tokio::spawn(async move {
            let mut buf = vec![0u8; 1500];
            let (len, from) = server_sock.recv_from(&mut buf).await.unwrap();
            if len < HEADER_LEN {
                return;
            }
            let tid = {
                let mut t = [0u8; 12];
                t.copy_from_slice(&buf[8..20]);
                t
            };
            // Соберём XOR-MAPPED-ADDRESS на основании from.
            let from_ip = match from.ip() {
                IpAddr::V4(v) => v.octets(),
                _ => return,
            };
            let xor_port = from.port() ^ ((MAGIC_COOKIE >> 16) as u16);
            let cookie = MAGIC_COOKIE.to_be_bytes();
            let mut xor_ip = from_ip;
            for i in 0..4 {
                xor_ip[i] ^= cookie[i];
            }
            let attr_value = {
                let mut v = Vec::with_capacity(8);
                v.push(0x00);
                v.push(0x01);
                v.extend_from_slice(&xor_port.to_be_bytes());
                v.extend_from_slice(&xor_ip);
                v
            };
            let mut resp = Vec::new();
            resp.extend_from_slice(&MSG_TYPE_BINDING_SUCCESS.to_be_bytes());
            resp.extend_from_slice(&((4 + attr_value.len()) as u16).to_be_bytes());
            resp.extend_from_slice(&MAGIC_COOKIE.to_be_bytes());
            resp.extend_from_slice(&tid);
            resp.extend_from_slice(&ATTR_XOR_MAPPED_ADDRESS.to_be_bytes());
            resp.extend_from_slice(&(attr_value.len() as u16).to_be_bytes());
            resp.extend_from_slice(&attr_value);
            server_sock.send_to(&resp, from).await.unwrap();
        });

        let client = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let client_addr = client.local_addr().unwrap();
        let reflexive = discover_reflexive(&client, server_addr, Duration::from_secs(2))
            .await
            .expect("discover must succeed");
        assert_eq!(reflexive, client_addr);
        server_task.await.unwrap();
    }
}
