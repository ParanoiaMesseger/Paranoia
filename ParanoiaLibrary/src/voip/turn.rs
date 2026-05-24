//! Минимальный клиентский TURN (RFC 8656 / RFC 5389) — без полного flow.
//!
//! Этот модуль реализует **сборку и парсинг** TURN-сообщений и long-term
//! credential механизм (USERNAME/REALM/NONCE + MESSAGE-INTEGRITY). Полная
//! интеграция (Allocate → Refresh → CreatePermission → Send/Data поверх
//! сессионного UDP-сокета) — отдельная фаза, требующая расширения
//! [`super::transport`]. Здесь мы только проверяем, что формат сообщений
//! правильный и MAC сходится.
//!
//! См.:
//! - RFC 5389 (STUN base, формат сообщений и атрибутов)
//! - RFC 8489 (STUN v2, magic cookie, XOR-MAPPED-ADDRESS)
//! - RFC 8656 (TURN: Allocate / Refresh / Send / Data / CreatePermission)

use anyhow::{Result, bail};
use hmac::{Hmac, Mac};
use md5::{Digest as _, Md5};
use sha1::Sha1;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

pub const STUN_HEADER_LEN: usize = 20;
pub const MAGIC_COOKIE: u32 = 0x2112_A442;

// ── Method и Class ─────────────────────────────────────────────────────

/// STUN method (TURN заимствует часть пространства):
pub mod method {
    pub const BINDING: u16 = 0x001; // STUN
    pub const ALLOCATE: u16 = 0x003;
    pub const REFRESH: u16 = 0x004;
    pub const SEND: u16 = 0x006;
    pub const DATA: u16 = 0x007;
    pub const CREATE_PERMISSION: u16 = 0x008;
    pub const CHANNEL_BIND: u16 = 0x009;
}

/// STUN message class.
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Class {
    Request = 0b00,
    Indication = 0b01,
    SuccessResponse = 0b10,
    ErrorResponse = 0b11,
}

/// Закодировать (method, class) в 14-битный message_type RFC 5389:
/// `type = (M11..M7 << 9) | (C1 << 8) | (M6..M4 << 5) | (C0 << 4) | M3..M0`
pub fn make_message_type(method: u16, class: Class) -> u16 {
    let c = class as u16;
    let c0 = (c & 0b01) >> 0;
    let c1 = (c & 0b10) >> 1;
    let m3_0 = method & 0x000F;
    let m6_4 = (method & 0x0070) >> 4;
    let m11_7 = (method & 0x0F80) >> 7;
    (m11_7 << 9) | (c1 << 8) | (m6_4 << 5) | (c0 << 4) | m3_0
}

/// Обратное преобразование.
pub fn parse_message_type(t: u16) -> (u16, Class) {
    let c0 = (t & 0x0010) >> 4;
    let c1 = (t & 0x0100) >> 8;
    let class_bits = (c1 << 1) | c0;
    let class = match class_bits {
        0b00 => Class::Request,
        0b01 => Class::Indication,
        0b10 => Class::SuccessResponse,
        0b11 => Class::ErrorResponse,
        _ => unreachable!(),
    };
    let m3_0 = t & 0x000F;
    let m6_4 = (t & 0x00E0) >> 1;
    let m11_7 = (t & 0x3E00) >> 2;
    let method = m11_7 | m6_4 | m3_0;
    (method, class)
}

// ── Атрибуты ───────────────────────────────────────────────────────────

pub mod attr {
    pub const USERNAME: u16 = 0x0006;
    pub const MESSAGE_INTEGRITY: u16 = 0x0008;
    pub const ERROR_CODE: u16 = 0x0009;
    pub const XOR_PEER_ADDRESS: u16 = 0x0012;
    pub const DATA: u16 = 0x0013;
    pub const REALM: u16 = 0x0014;
    pub const NONCE: u16 = 0x0015;
    pub const XOR_RELAYED_ADDRESS: u16 = 0x0016;
    pub const REQUESTED_TRANSPORT: u16 = 0x0019;
    pub const XOR_MAPPED_ADDRESS: u16 = 0x0020;
    pub const LIFETIME: u16 = 0x000D;
    pub const SOFTWARE: u16 = 0x8022;
}

/// REQUESTED-TRANSPORT для UDP (TURN/RFC 8656).
pub const TRANSPORT_UDP: u8 = 17;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Attribute {
    pub typ: u16,
    pub value: Vec<u8>,
}

// ── Builder / Parser ───────────────────────────────────────────────────

pub struct MessageBuilder {
    typ: u16,
    transaction_id: [u8; 12],
    attrs: Vec<Attribute>,
}

impl MessageBuilder {
    pub fn new(method: u16, class: Class, transaction_id: [u8; 12]) -> Self {
        Self {
            typ: make_message_type(method, class),
            transaction_id,
            attrs: Vec::new(),
        }
    }

    pub fn push_attr(&mut self, typ: u16, value: Vec<u8>) {
        self.attrs.push(Attribute { typ, value });
    }

    pub fn push_string(&mut self, typ: u16, s: &str) {
        self.attrs.push(Attribute {
            typ,
            value: s.as_bytes().to_vec(),
        });
    }

    pub fn push_u32(&mut self, typ: u16, v: u32) {
        self.attrs.push(Attribute {
            typ,
            value: v.to_be_bytes().to_vec(),
        });
    }

    pub fn push_requested_transport_udp(&mut self) {
        let mut v = vec![0u8; 4];
        v[0] = TRANSPORT_UDP;
        self.attrs.push(Attribute {
            typ: attr::REQUESTED_TRANSPORT,
            value: v,
        });
    }

    pub fn push_xor_peer_address(&mut self, addr: SocketAddr) {
        let v = encode_xor_address(addr, &self.transaction_id);
        self.attrs.push(Attribute {
            typ: attr::XOR_PEER_ADDRESS,
            value: v,
        });
    }

    /// Финализировать сообщение без MESSAGE-INTEGRITY.
    pub fn finish(self) -> Vec<u8> {
        self.encode(None)
    }

    /// Финализировать сообщение, добавив MESSAGE-INTEGRITY в конце.
    /// `integrity_key` = `MD5(username:realm:password)` для long-term creds.
    pub fn finish_with_integrity(self, integrity_key: &[u8; 16]) -> Vec<u8> {
        self.encode(Some(integrity_key))
    }

    fn encode(self, integrity_key: Option<&[u8; 16]>) -> Vec<u8> {
        // Считаем длину «как если бы integrity уже был добавлен» — для
        // правильного header.length при вычислении HMAC.
        let mut attrs_len = 0usize;
        for a in &self.attrs {
            attrs_len += 4 + padded_len(a.value.len());
        }
        if integrity_key.is_some() {
            attrs_len += 4 + 20; // MESSAGE-INTEGRITY (header + 20-byte HMAC)
        }

        let mut buf = Vec::with_capacity(STUN_HEADER_LEN + attrs_len);
        buf.extend_from_slice(&self.typ.to_be_bytes());
        buf.extend_from_slice(&(attrs_len as u16).to_be_bytes());
        buf.extend_from_slice(&MAGIC_COOKIE.to_be_bytes());
        buf.extend_from_slice(&self.transaction_id);
        for a in &self.attrs {
            buf.extend_from_slice(&a.typ.to_be_bytes());
            buf.extend_from_slice(&(a.value.len() as u16).to_be_bytes());
            buf.extend_from_slice(&a.value);
            let pad = padded_len(a.value.len()) - a.value.len();
            buf.extend(std::iter::repeat(0u8).take(pad));
        }
        if let Some(key) = integrity_key {
            // HMAC-SHA1 над всем сообщением до MESSAGE-INTEGRITY (header.length
            // уже включает 24 байта MI). См. RFC 5389 §15.4.
            let mut mac =
                <Hmac<Sha1> as Mac>::new_from_slice(key).expect("HMAC accepts any key length");
            mac.update(&buf);
            let tag = mac.finalize().into_bytes();
            buf.extend_from_slice(&attr::MESSAGE_INTEGRITY.to_be_bytes());
            buf.extend_from_slice(&20u16.to_be_bytes());
            buf.extend_from_slice(&tag);
        }
        buf
    }
}

/// Заголовок сообщения.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Header {
    pub message_type: u16,
    pub method: u16,
    pub class: Class,
    pub message_length: u16,
    pub transaction_id: [u8; 12],
}

#[derive(Debug, Clone)]
pub struct Message {
    pub header: Header,
    pub attrs: Vec<Attribute>,
}

impl Message {
    pub fn find(&self, typ: u16) -> Option<&Attribute> {
        self.attrs.iter().find(|a| a.typ == typ)
    }

    pub fn find_string(&self, typ: u16) -> Option<String> {
        self.find(typ)
            .and_then(|a| std::str::from_utf8(&a.value).ok().map(|s| s.to_string()))
    }

    pub fn find_xor_address(&self, typ: u16) -> Option<SocketAddr> {
        let a = self.find(typ)?;
        decode_xor_address(&a.value, &self.header.transaction_id)
    }

    pub fn find_lifetime(&self) -> Option<u32> {
        let a = self.find(attr::LIFETIME)?;
        if a.value.len() != 4 {
            return None;
        }
        Some(u32::from_be_bytes([
            a.value[0], a.value[1], a.value[2], a.value[3],
        ]))
    }
}

pub fn parse(buf: &[u8]) -> Result<Message> {
    if buf.len() < STUN_HEADER_LEN {
        bail!("turn parse: too short");
    }
    let typ = u16::from_be_bytes([buf[0], buf[1]]);
    let len = u16::from_be_bytes([buf[2], buf[3]]) as usize;
    let cookie = u32::from_be_bytes([buf[4], buf[5], buf[6], buf[7]]);
    if cookie != MAGIC_COOKIE {
        bail!("turn parse: bad magic cookie");
    }
    if STUN_HEADER_LEN + len > buf.len() {
        bail!("turn parse: length overflow");
    }
    let mut tid = [0u8; 12];
    tid.copy_from_slice(&buf[8..20]);
    let (method, class) = parse_message_type(typ);

    let mut attrs = Vec::new();
    let mut pos = STUN_HEADER_LEN;
    let end = STUN_HEADER_LEN + len;
    while pos + 4 <= end {
        let a_typ = u16::from_be_bytes([buf[pos], buf[pos + 1]]);
        let a_len = u16::from_be_bytes([buf[pos + 2], buf[pos + 3]]) as usize;
        let val_start = pos + 4;
        if val_start + a_len > end {
            bail!("turn parse: attr length overflow");
        }
        let value = buf[val_start..val_start + a_len].to_vec();
        attrs.push(Attribute { typ: a_typ, value });
        pos = val_start + padded_len(a_len);
    }

    Ok(Message {
        header: Header {
            message_type: typ,
            method,
            class,
            message_length: len as u16,
            transaction_id: tid,
        },
        attrs,
    })
}

/// Проверить MESSAGE-INTEGRITY на распарсенном сообщении.
/// Принимает сырые байты сообщения (как пришли по сети).
pub fn verify_message_integrity(raw: &[u8], integrity_key: &[u8; 16]) -> Result<bool> {
    let msg = parse(raw)?;
    let mi = match msg.find(attr::MESSAGE_INTEGRITY) {
        Some(a) => a,
        None => return Ok(false),
    };
    if mi.value.len() != 20 {
        return Ok(false);
    }
    // Нужно найти offset MESSAGE-INTEGRITY в `raw`. Идём по атрибутам пока не
    // упрёмся в MI.
    let mut pos = STUN_HEADER_LEN;
    let end = STUN_HEADER_LEN + msg.header.message_length as usize;
    let mut mi_offset = None;
    while pos + 4 <= end {
        let a_typ = u16::from_be_bytes([raw[pos], raw[pos + 1]]);
        let a_len = u16::from_be_bytes([raw[pos + 2], raw[pos + 3]]) as usize;
        if a_typ == attr::MESSAGE_INTEGRITY {
            mi_offset = Some(pos);
            break;
        }
        pos += 4 + padded_len(a_len);
    }
    let mi_offset = match mi_offset {
        Some(o) => o,
        None => return Ok(false),
    };
    // Header.length должен включать MI; по RFC. Но что приходит — то и считаем.
    let mut mac =
        <Hmac<Sha1> as Mac>::new_from_slice(integrity_key).expect("HMAC accepts any key length");
    mac.update(&raw[..mi_offset]);
    let expected = mac.finalize().into_bytes();
    Ok(expected.as_slice() == mi.value.as_slice())
}

/// Вычислить long-term integrity key:
/// `key = MD5( username ":" realm ":" password )`.
pub fn derive_long_term_key(username: &str, realm: &str, password: &str) -> [u8; 16] {
    let mut h = Md5::new();
    h.update(username.as_bytes());
    h.update(b":");
    h.update(realm.as_bytes());
    h.update(b":");
    h.update(password.as_bytes());
    let out = h.finalize();
    let mut key = [0u8; 16];
    key.copy_from_slice(&out);
    key
}

// ── XOR-address кодек ──────────────────────────────────────────────────

fn encode_xor_address(addr: SocketAddr, tid: &[u8; 12]) -> Vec<u8> {
    let cookie = MAGIC_COOKIE.to_be_bytes();
    let xor_port = addr.port() ^ ((MAGIC_COOKIE >> 16) as u16);
    match addr.ip() {
        IpAddr::V4(v4) => {
            let mut v = Vec::with_capacity(8);
            v.push(0x00); // reserved
            v.push(0x01); // family v4
            v.extend_from_slice(&xor_port.to_be_bytes());
            let oct = v4.octets();
            for i in 0..4 {
                v.push(oct[i] ^ cookie[i]);
            }
            v
        }
        IpAddr::V6(v6) => {
            let mut v = Vec::with_capacity(20);
            v.push(0x00);
            v.push(0x02);
            v.extend_from_slice(&xor_port.to_be_bytes());
            let oct = v6.octets();
            let mut key = [0u8; 16];
            key[..4].copy_from_slice(&cookie);
            key[4..].copy_from_slice(tid);
            for i in 0..16 {
                v.push(oct[i] ^ key[i]);
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
    let xor_port = u16::from_be_bytes([value[2], value[3]]);
    let port = xor_port ^ ((MAGIC_COOKIE >> 16) as u16);
    let cookie = MAGIC_COOKIE.to_be_bytes();
    match family {
        0x01 => {
            if value.len() < 8 {
                return None;
            }
            let mut bytes = [0u8; 4];
            for i in 0..4 {
                bytes[i] = value[4 + i] ^ cookie[i];
            }
            Some(SocketAddr::new(IpAddr::V4(Ipv4Addr::from(bytes)), port))
        }
        0x02 => {
            if value.len() < 20 {
                return None;
            }
            let mut bytes = [0u8; 16];
            let mut key = [0u8; 16];
            key[..4].copy_from_slice(&cookie);
            key[4..].copy_from_slice(tid);
            for i in 0..16 {
                bytes[i] = value[4 + i] ^ key[i];
            }
            Some(SocketAddr::new(IpAddr::V6(Ipv6Addr::from(bytes)), port))
        }
        _ => None,
    }
}

fn padded_len(len: usize) -> usize {
    (len + 3) & !3
}

// ── Высокоуровневые helpers ────────────────────────────────────────────

/// Собрать initial Allocate Request (без auth) — сервер ответит 401 с REALM/NONCE.
pub fn build_initial_allocate(transaction_id: [u8; 12]) -> Vec<u8> {
    let mut b = MessageBuilder::new(method::ALLOCATE, Class::Request, transaction_id);
    b.push_requested_transport_udp();
    b.finish()
}

/// Собрать authenticated Allocate Request с USERNAME/REALM/NONCE + MI.
pub fn build_allocate_with_auth(
    transaction_id: [u8; 12],
    username: &str,
    realm: &str,
    nonce: &str,
    integrity_key: &[u8; 16],
    lifetime_seconds: u32,
) -> Vec<u8> {
    let mut b = MessageBuilder::new(method::ALLOCATE, Class::Request, transaction_id);
    b.push_requested_transport_udp();
    b.push_u32(attr::LIFETIME, lifetime_seconds);
    b.push_string(attr::USERNAME, username);
    b.push_string(attr::REALM, realm);
    b.push_string(attr::NONCE, nonce);
    b.finish_with_integrity(integrity_key)
}

/// Собрать CreatePermission Request для разрешения отправки данных peer'у.
pub fn build_create_permission(
    transaction_id: [u8; 12],
    peers: &[SocketAddr],
    username: &str,
    realm: &str,
    nonce: &str,
    integrity_key: &[u8; 16],
) -> Vec<u8> {
    let mut b = MessageBuilder::new(method::CREATE_PERMISSION, Class::Request, transaction_id);
    for p in peers {
        b.push_xor_peer_address(*p);
    }
    b.push_string(attr::USERNAME, username);
    b.push_string(attr::REALM, realm);
    b.push_string(attr::NONCE, nonce);
    b.finish_with_integrity(integrity_key)
}

/// Собрать CreatePermission Request без long-term auth. Используется с
/// встроенным Paranoia TURN-режимом, который работает как приватный relay рядом
/// с сервером приложения и не требует RFC long-term credentials.
pub fn build_create_permission_no_auth(transaction_id: [u8; 12], peers: &[SocketAddr]) -> Vec<u8> {
    let mut b = MessageBuilder::new(method::CREATE_PERMISSION, Class::Request, transaction_id);
    for p in peers {
        b.push_xor_peer_address(*p);
    }
    b.finish()
}

/// Собрать Refresh Request для продления allocation lifetime.
/// `lifetime_seconds = 0` — explicit close allocation (RFC 8656 §7.2).
/// Без auth (для встроенного Paranoia TURN). Сервер ответит Refresh Success
/// с актуальным LIFETIME, который нужно использовать для следующего refresh.
pub fn build_refresh_no_auth(transaction_id: [u8; 12], lifetime_seconds: u32) -> Vec<u8> {
    let mut b = MessageBuilder::new(method::REFRESH, Class::Request, transaction_id);
    b.push_u32(attr::LIFETIME, lifetime_seconds);
    b.finish()
}

/// Собрать Send Indication: пакет с DATA, обёрнутый для отправки через TURN.
/// Indications не имеют MESSAGE-INTEGRITY (RFC 8656 §11).
pub fn build_send_indication(transaction_id: [u8; 12], peer: SocketAddr, data: &[u8]) -> Vec<u8> {
    let mut b = MessageBuilder::new(method::SEND, Class::Indication, transaction_id);
    b.push_xor_peer_address(peer);
    b.push_attr(attr::DATA, data.to_vec());
    b.finish()
}

/// Распаковать Data Indication, возвращая `(peer, data)`.
pub fn parse_data_indication(buf: &[u8]) -> Result<(SocketAddr, Vec<u8>)> {
    let msg = parse(buf)?;
    if msg.header.method != method::DATA || msg.header.class != Class::Indication {
        bail!("not a Data Indication");
    }
    let peer = msg
        .find_xor_address(attr::XOR_PEER_ADDRESS)
        .ok_or_else(|| anyhow::anyhow!("Data Indication missing XOR-PEER-ADDRESS"))?;
    let data = msg
        .find(attr::DATA)
        .map(|a| a.value.clone())
        .ok_or_else(|| anyhow::anyhow!("Data Indication missing DATA"))?;
    Ok((peer, data))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn message_type_roundtrip_allocate_request() {
        let t = make_message_type(method::ALLOCATE, Class::Request);
        // ALLOCATE Request = 0x0003
        assert_eq!(t, 0x0003);
        let (m, c) = parse_message_type(t);
        assert_eq!(m, method::ALLOCATE);
        assert_eq!(c, Class::Request);
    }

    #[test]
    fn message_type_roundtrip_allocate_success() {
        let t = make_message_type(method::ALLOCATE, Class::SuccessResponse);
        assert_eq!(t, 0x0103);
        let (m, c) = parse_message_type(t);
        assert_eq!(m, method::ALLOCATE);
        assert_eq!(c, Class::SuccessResponse);
    }

    #[test]
    fn message_type_roundtrip_send_indication() {
        let t = make_message_type(method::SEND, Class::Indication);
        assert_eq!(t, 0x0016);
        let (m, c) = parse_message_type(t);
        assert_eq!(m, method::SEND);
        assert_eq!(c, Class::Indication);
    }

    #[test]
    fn message_type_roundtrip_data_indication() {
        let t = make_message_type(method::DATA, Class::Indication);
        assert_eq!(t, 0x0017);
        let (m, c) = parse_message_type(t);
        assert_eq!(m, method::DATA);
        assert_eq!(c, Class::Indication);
    }

    #[test]
    fn message_type_roundtrip_create_permission() {
        let t = make_message_type(method::CREATE_PERMISSION, Class::Request);
        assert_eq!(t, 0x0008);
        let (m, c) = parse_message_type(t);
        assert_eq!(m, method::CREATE_PERMISSION);
        assert_eq!(c, Class::Request);
    }

    #[test]
    fn initial_allocate_request_layout() {
        let raw = build_initial_allocate([0xAA; 12]);
        let m = parse(&raw).unwrap();
        assert_eq!(m.header.method, method::ALLOCATE);
        assert_eq!(m.header.class, Class::Request);
        assert_eq!(m.header.transaction_id, [0xAA; 12]);
        let rt = m.find(attr::REQUESTED_TRANSPORT).unwrap();
        assert_eq!(rt.value[0], TRANSPORT_UDP);
    }

    #[test]
    fn auth_allocate_with_message_integrity_verifies() {
        let key = derive_long_term_key("alice", "paranoia.example", "s3cret");
        let raw = build_allocate_with_auth(
            [0x33; 12],
            "alice",
            "paranoia.example",
            "deadbeef-nonce",
            &key,
            600,
        );
        // Должны парситься без проблем.
        let m = parse(&raw).expect("parse");
        assert_eq!(m.header.method, method::ALLOCATE);
        assert_eq!(m.find_string(attr::USERNAME).as_deref(), Some("alice"));
        assert_eq!(
            m.find_string(attr::REALM).as_deref(),
            Some("paranoia.example")
        );
        assert_eq!(
            m.find_string(attr::NONCE).as_deref(),
            Some("deadbeef-nonce")
        );
        assert_eq!(m.find_lifetime(), Some(600));
        assert_eq!(
            m.find(attr::MESSAGE_INTEGRITY).map(|a| a.value.len()),
            Some(20)
        );
        // MAC должен сходиться.
        assert!(verify_message_integrity(&raw, &key).unwrap());
    }

    #[test]
    fn message_integrity_breaks_on_tamper() {
        let key = derive_long_term_key("alice", "r", "p");
        let mut raw = build_allocate_with_auth([0x77; 12], "alice", "r", "n", &key, 600);
        // Поломаем NONCE.
        let pos = raw.iter().position(|&b| b == b'n').unwrap();
        raw[pos] ^= 0xFF;
        assert!(!verify_message_integrity(&raw, &key).unwrap());
    }

    #[test]
    fn create_permission_carries_peers() {
        let key = derive_long_term_key("u", "r", "p");
        let peers = [
            "203.0.113.5:5000".parse::<SocketAddr>().unwrap(),
            "198.51.100.7:6000".parse::<SocketAddr>().unwrap(),
        ];
        let raw = build_create_permission([0x11; 12], &peers, "u", "r", "n", &key);
        let m = parse(&raw).unwrap();
        assert_eq!(m.header.method, method::CREATE_PERMISSION);
        let xpas: Vec<SocketAddr> = m
            .attrs
            .iter()
            .filter(|a| a.typ == attr::XOR_PEER_ADDRESS)
            .filter_map(|a| decode_xor_address(&a.value, &m.header.transaction_id))
            .collect();
        assert_eq!(xpas, peers);
        assert!(verify_message_integrity(&raw, &key).unwrap());
    }

    #[test]
    fn create_permission_no_auth_carries_peer() {
        let peer = "203.0.113.5:5000".parse::<SocketAddr>().unwrap();
        let raw = build_create_permission_no_auth([0x21; 12], &[peer]);
        let m = parse(&raw).unwrap();
        assert_eq!(m.header.method, method::CREATE_PERMISSION);
        assert_eq!(m.header.class, Class::Request);
        assert!(m.find(attr::MESSAGE_INTEGRITY).is_none());
        assert_eq!(m.find_xor_address(attr::XOR_PEER_ADDRESS), Some(peer));
    }

    #[test]
    fn send_data_indications_roundtrip() {
        let tid = [0x55; 12];
        let peer: SocketAddr = "192.0.2.42:12345".parse().unwrap();
        let payload = b"opus-encrypted-bytes";

        let send = build_send_indication(tid, peer, payload);
        let parsed_send = parse(&send).unwrap();
        assert_eq!(parsed_send.header.method, method::SEND);
        assert_eq!(parsed_send.header.class, Class::Indication);
        assert!(parsed_send.find(attr::MESSAGE_INTEGRITY).is_none());

        // Изобразим, что сервер пересоберёт DataIndication с тем же payload.
        let mut b = MessageBuilder::new(method::DATA, Class::Indication, tid);
        b.push_xor_peer_address(peer);
        b.push_attr(attr::DATA, payload.to_vec());
        let data_ind = b.finish();

        let (back_peer, back_data) = parse_data_indication(&data_ind).unwrap();
        assert_eq!(back_peer, peer);
        assert_eq!(back_data, payload);
    }

    #[test]
    fn xor_address_v4_roundtrip() {
        let tid = [0xCC; 12];
        let addr: SocketAddr = "1.2.3.4:5060".parse().unwrap();
        let v = encode_xor_address(addr, &tid);
        let back = decode_xor_address(&v, &tid).unwrap();
        assert_eq!(back, addr);
    }

    #[test]
    fn xor_address_v6_roundtrip() {
        let tid = [0x12; 12];
        let addr: SocketAddr = "[2001:db8::1]:443".parse().unwrap();
        let v = encode_xor_address(addr, &tid);
        let back = decode_xor_address(&v, &tid).unwrap();
        assert_eq!(back, addr);
    }

    #[test]
    fn parse_rejects_bad_cookie() {
        let mut raw = build_initial_allocate([0u8; 12]);
        raw[4] ^= 0xFF;
        assert!(parse(&raw).is_err());
    }
}
