//! Формат медиа-пакета VoIP и защита от replay.
//!
//! Layout (см. `paranoia_voip_policy.md`):
//!
//! ```text
//! 0      Version (= 0x01)         1 byte
//! 1      Stream ID                1 byte  (0 = voice, 1 = video)
//! 2      Flags                    1 byte  (bit0 = comfort noise, bit1 = frame start)
//! 3      Reserved                 1 byte  (= 0)
//! 4..12  Sequence Number          8 bytes (big-endian u64)
//! 12..16 RTP-like Timestamp       4 bytes (big-endian u32, 48000 Hz units)
//! 16..N  ChaCha20-Poly1305(opus)  (ciphertext || 16-byte tag)
//! ```
//!
//! Байты 0..16 идут в AEAD как AAD: они не шифруются, но защищены MAC'ом.

use anyhow::{Result, bail};

use super::crypto::{
    Direction, StreamId, VOIP_KEY_LEN, VOIP_TAG_LEN, aead_decrypt, aead_encrypt, build_nonce,
};

pub const VOIP_HEADER_LEN: usize = 16;
pub const VOIP_VERSION: u8 = 0x01;

/// Флаги в байте 2 заголовка.
pub mod flags {
    pub const COMFORT_NOISE: u8 = 1 << 0;
    pub const FRAME_START: u8 = 1 << 1;
    /// Маска зарезервированных битов: эти биты должны быть 0 у валидного пакета.
    pub const RESERVED_MASK: u8 = !(COMFORT_NOISE | FRAME_START);
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VoipHeader {
    pub version: u8,
    pub stream_id: StreamId,
    pub flags: u8,
    pub sequence: u64,
    pub rtp_timestamp: u32,
}

impl VoipHeader {
    pub fn new(stream: StreamId, sequence: u64, rtp_timestamp: u32, flags: u8) -> Self {
        Self {
            version: VOIP_VERSION,
            stream_id: stream,
            flags,
            sequence,
            rtp_timestamp,
        }
    }

    pub fn encode(&self) -> [u8; VOIP_HEADER_LEN] {
        let mut buf = [0u8; VOIP_HEADER_LEN];
        buf[0] = self.version;
        buf[1] = self.stream_id.as_byte();
        buf[2] = self.flags;
        buf[3] = 0; // reserved
        buf[4..12].copy_from_slice(&self.sequence.to_be_bytes());
        buf[12..16].copy_from_slice(&self.rtp_timestamp.to_be_bytes());
        buf
    }

    pub fn decode(bytes: &[u8]) -> Result<Self> {
        if bytes.len() < VOIP_HEADER_LEN {
            bail!("VoIP packet shorter than header");
        }
        let version = bytes[0];
        if version != VOIP_VERSION {
            bail!("Unsupported VoIP version: {version}");
        }
        let stream_id = match bytes[1] {
            0 => StreamId::Voice,
            1 => StreamId::Video,
            other => bail!("Unknown VoIP stream id: {other}"),
        };
        let flags = bytes[2];
        if flags & flags::RESERVED_MASK != 0 {
            bail!("Reserved VoIP flag bits set: {flags:#04x}");
        }
        if bytes[3] != 0 {
            bail!("Reserved VoIP header byte non-zero");
        }
        let mut seq_bytes = [0u8; 8];
        seq_bytes.copy_from_slice(&bytes[4..12]);
        let sequence = u64::from_be_bytes(seq_bytes);
        let mut ts_bytes = [0u8; 4];
        ts_bytes.copy_from_slice(&bytes[12..16]);
        let rtp_timestamp = u32::from_be_bytes(ts_bytes);
        Ok(Self {
            version,
            stream_id,
            flags,
            sequence,
            rtp_timestamp,
        })
    }
}

/// Запаковать opus-фрейм в шифрованный VoIP-пакет.
///
/// `direction` — направление, с которым отправитель шифрует (см. [`Role`]).
/// `key` — соответствующий tx-ключ из `SessionKeys`.
///
/// На выходе: `header(16) || ciphertext || tag(16)` готовое к `send_to`.
pub fn pack(
    header: &VoipHeader,
    key: &[u8; VOIP_KEY_LEN],
    direction: Direction,
    opus: &[u8],
) -> Result<Vec<u8>> {
    let header_bytes = header.encode();
    let nonce = build_nonce(header.stream_id, direction, header.sequence);
    let ct = aead_encrypt(key, &nonce, &header_bytes, opus)?;

    let mut out = Vec::with_capacity(VOIP_HEADER_LEN + ct.len());
    out.extend_from_slice(&header_bytes);
    out.extend_from_slice(&ct);
    Ok(out)
}

/// Распаковать входящий пакет.
///
/// `direction` — направление, которое мы ожидаем у входящих (rx-направление
/// нашей стороны). `key` — соответствующий rx-ключ.
///
/// При любом расхождении (плохой версии, перевзведённых reserved-битах,
/// неверном MAC) возвращается `Err` — вызывающий код тихо дропает пакет.
pub fn unpack(
    bytes: &[u8],
    key: &[u8; VOIP_KEY_LEN],
    direction: Direction,
) -> Result<(VoipHeader, Vec<u8>)> {
    if bytes.len() < VOIP_HEADER_LEN + VOIP_TAG_LEN {
        bail!("VoIP packet too short");
    }
    let header = VoipHeader::decode(&bytes[..VOIP_HEADER_LEN])?;
    let nonce = build_nonce(header.stream_id, direction, header.sequence);
    let plain = aead_decrypt(
        key,
        &nonce,
        &bytes[..VOIP_HEADER_LEN],
        &bytes[VOIP_HEADER_LEN..],
    )?;
    Ok((header, plain))
}

/// Sliding-window защита от replay на 64 принятых пакета.
///
/// Хранится в `CallSession` отдельно для каждого rx-потока (voice / video).
/// Удалённая сторона **обязана** монотонно увеличивать `sequence`; пропуски
/// допустимы (потери), повторы — нет.
#[derive(Debug, Clone, Copy, Default)]
pub struct ReplayWindow {
    /// Наибольший принятый seq.
    highest: u64,
    /// Битовая карта последних 64 принятых seq, где bit0 — самый свежий (highest),
    /// bit i — seq == highest - i. Нулевой бит означает «не видели».
    bitmap: u64,
    /// Видели ли мы хотя бы один пакет (отличает «не было» от seq == 0).
    seen_any: bool,
}

impl ReplayWindow {
    pub fn new() -> Self {
        Self::default()
    }

    /// Принять seq в окно. Возвращает `true`, если seq новый и принят;
    /// `false`, если это replay (повтор или слишком старый).
    pub fn check_and_update(&mut self, seq: u64) -> bool {
        if !self.seen_any {
            self.seen_any = true;
            self.highest = seq;
            self.bitmap = 1; // bit0 = highest
            return true;
        }

        if seq > self.highest {
            let shift = seq - self.highest;
            if shift >= 64 {
                self.bitmap = 1; // окно полностью сдвинулось, остаётся только новый highest
            } else {
                // Существующая карта смещается «вправо» (старшие → старее),
                // новый highest занимает bit0.
                self.bitmap = (self.bitmap << shift) | 1;
            }
            self.highest = seq;
            true
        } else {
            let delta = self.highest - seq;
            if delta >= 64 {
                // Слишком старый — за пределами окна.
                return false;
            }
            let mask = 1u64 << delta;
            if self.bitmap & mask != 0 {
                false // уже видели
            } else {
                self.bitmap |= mask;
                true
            }
        }
    }

    pub fn highest_seen(&self) -> Option<u64> {
        if self.seen_any { Some(self.highest) } else { None }
    }
}

#[cfg(test)]
mod tests {
    use super::super::crypto::{Role, SessionKeys};
    use super::*;

    fn master() -> [u8; 32] {
        [0x55; 32]
    }
    fn sid() -> [u8; 16] {
        [0xAA; 16]
    }

    #[test]
    fn header_roundtrip() {
        let h = VoipHeader::new(StreamId::Voice, 0x0102030405060708, 0xDEADBEEF, flags::FRAME_START);
        let bytes = h.encode();
        let back = VoipHeader::decode(&bytes).unwrap();
        assert_eq!(h, back);
    }

    #[test]
    fn decode_rejects_bad_version() {
        let mut bytes = VoipHeader::new(StreamId::Voice, 0, 0, 0).encode();
        bytes[0] = 0x02;
        assert!(VoipHeader::decode(&bytes).is_err());
    }

    #[test]
    fn decode_rejects_reserved_flag_bits() {
        let mut bytes = VoipHeader::new(StreamId::Voice, 0, 0, 0).encode();
        bytes[2] = 0b1000_0000; // зарезервированный бит
        assert!(VoipHeader::decode(&bytes).is_err());
    }

    #[test]
    fn decode_rejects_reserved_byte() {
        let mut bytes = VoipHeader::new(StreamId::Voice, 0, 0, 0).encode();
        bytes[3] = 0x01;
        assert!(VoipHeader::decode(&bytes).is_err());
    }

    #[test]
    fn pack_unpack_roundtrip_between_peers() {
        let init = SessionKeys::derive(&master(), &sid(), StreamId::Voice, Role::Initiator);
        let resp = SessionKeys::derive(&master(), &sid(), StreamId::Voice, Role::Responder);

        let header = VoipHeader::new(StreamId::Voice, 1, 0, 0);
        let opus = b"fake-opus-frame";

        let pkt = pack(&header, init.tx(), Role::Initiator.tx_direction(), opus).unwrap();
        let (hdr, plain) = unpack(&pkt, resp.rx(), Role::Responder.rx_direction()).unwrap();
        assert_eq!(hdr, header);
        assert_eq!(plain, opus);
    }

    #[test]
    fn unpack_rejects_header_tamper() {
        let init = SessionKeys::derive(&master(), &sid(), StreamId::Voice, Role::Initiator);
        let resp = SessionKeys::derive(&master(), &sid(), StreamId::Voice, Role::Responder);

        let header = VoipHeader::new(StreamId::Voice, 7, 0, 0);
        let mut pkt = pack(&header, init.tx(), Role::Initiator.tx_direction(), b"x").unwrap();
        // Меняем RTP timestamp в заголовке — MAC должен разъехаться.
        pkt[12] ^= 0xFF;
        assert!(unpack(&pkt, resp.rx(), Role::Responder.rx_direction()).is_err());
    }

    #[test]
    fn unpack_rejects_ciphertext_tamper() {
        let init = SessionKeys::derive(&master(), &sid(), StreamId::Voice, Role::Initiator);
        let resp = SessionKeys::derive(&master(), &sid(), StreamId::Voice, Role::Responder);

        let header = VoipHeader::new(StreamId::Voice, 7, 0, 0);
        let mut pkt = pack(&header, init.tx(), Role::Initiator.tx_direction(), b"opus").unwrap();
        let last = pkt.len() - 1;
        pkt[last] ^= 0x01;
        assert!(unpack(&pkt, resp.rx(), Role::Responder.rx_direction()).is_err());
    }

    #[test]
    fn unpack_rejects_wrong_direction() {
        let init = SessionKeys::derive(&master(), &sid(), StreamId::Voice, Role::Initiator);
        let resp = SessionKeys::derive(&master(), &sid(), StreamId::Voice, Role::Responder);

        let header = VoipHeader::new(StreamId::Voice, 1, 0, 0);
        let pkt = pack(&header, init.tx(), Role::Initiator.tx_direction(), b"opus").unwrap();
        // Пакет летит I->R; пытаемся распаковать «как будто» он R->I —
        // direction-байт в nonce не сойдётся, MAC не пройдёт.
        assert!(unpack(&pkt, resp.rx(), Direction::ResponderToInitiator).is_err());
    }

    #[test]
    fn replay_window_accepts_monotonic() {
        let mut w = ReplayWindow::new();
        for s in 1..=200u64 {
            assert!(w.check_and_update(s), "seq {s} should be accepted");
        }
        assert_eq!(w.highest_seen(), Some(200));
    }

    #[test]
    fn replay_window_rejects_repeat() {
        let mut w = ReplayWindow::new();
        assert!(w.check_and_update(10));
        assert!(!w.check_and_update(10));
    }

    #[test]
    fn replay_window_accepts_out_of_order_in_window() {
        let mut w = ReplayWindow::new();
        assert!(w.check_and_update(100));
        assert!(w.check_and_update(98));
        assert!(w.check_and_update(99));
        assert!(!w.check_and_update(98), "repeat must be rejected");
    }

    #[test]
    fn replay_window_rejects_too_old() {
        let mut w = ReplayWindow::new();
        assert!(w.check_and_update(100));
        // 100 - 64 = 36 уже на границе; всё что <= 36 вне окна.
        assert!(!w.check_and_update(36));
        assert!(!w.check_and_update(0));
    }

    #[test]
    fn replay_window_big_jump_clears_old() {
        let mut w = ReplayWindow::new();
        assert!(w.check_and_update(1));
        assert!(w.check_and_update(2));
        assert!(w.check_and_update(1_000_000));
        // Старые ушли далеко за окно — должны быть отвергнуты как слишком старые.
        assert!(!w.check_and_update(2));
        assert!(!w.check_and_update(1));
    }

    #[test]
    fn replay_window_first_seq_can_be_zero() {
        let mut w = ReplayWindow::new();
        assert!(w.check_and_update(0));
        assert!(!w.check_and_update(0));
        assert!(w.check_and_update(1));
    }
}
