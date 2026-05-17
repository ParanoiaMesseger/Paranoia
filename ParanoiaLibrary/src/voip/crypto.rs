//! Крипто-ядро VoIP: HKDF-вывод сессионных ключей, конструкция nonce, AEAD.
//!
//! Шифр: ChaCha20-Poly1305 (RFC 8439), nonce 96 бит, тег 128 бит.
//! Каждый звонок имеет свой `session_id` (16 случайных байт, передаётся в
//! сигнальном offer'е, зашифрованном dialog master key'ом). Из master key и
//! session_id HKDF-SHA256 выводит пару направленных ключей tx/rx.

use anyhow::{Result, bail};
use chacha20poly1305::{
    ChaCha20Poly1305, Key, Nonce,
    aead::{Aead, KeyInit, Payload},
};
use hkdf::Hkdf;
use sha2::Sha256;
use zeroize::{Zeroize, ZeroizeOnDrop};

pub const VOIP_KEY_LEN: usize = 32;
pub const VOIP_SESSION_ID_LEN: usize = 16;
pub const VOIP_NONCE_LEN: usize = 12;
pub const VOIP_TAG_LEN: usize = 16;

/// Тип потока внутри звонка. Значение байта попадает в nonce, поэтому
/// добавление новых вариантов в существующий звонок без согласования с
/// удалённой стороной приведёт к рассинхрону nonce'ов.
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StreamId {
    Voice = 0,
    Video = 1,
}

impl StreamId {
    pub fn as_byte(self) -> u8 {
        self as u8
    }
}

/// Кто отправитель пакета — нужно для уникальности nonce, когда обе стороны
/// используют один и тот же ключ (после HKDF tx/rx у одного — это rx/tx у
/// другого, но direction добавляет ещё один уровень разделения).
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    /// Пакет идёт от инициатора звонка к ответчику.
    InitiatorToResponder = 0,
    /// Пакет идёт от ответчика к инициатору.
    ResponderToInitiator = 1,
}

impl Direction {
    pub fn as_byte(self) -> u8 {
        self as u8
    }
}

/// Чья сторона мы в звонке.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    Initiator,
    Responder,
}

impl Role {
    /// Куда мы шлём собственные пакеты.
    pub fn tx_direction(self) -> Direction {
        match self {
            Role::Initiator => Direction::InitiatorToResponder,
            Role::Responder => Direction::ResponderToInitiator,
        }
    }

    /// Какое направление мы ожидаем у входящих.
    pub fn rx_direction(self) -> Direction {
        match self {
            Role::Initiator => Direction::ResponderToInitiator,
            Role::Responder => Direction::InitiatorToResponder,
        }
    }
}

/// HKDF info-метка для tx-ключа голосового потока.
const INFO_VOICE_TX: &[u8] = b"paranoia-voice-tx";
/// HKDF info-метка для rx-ключа голосового потока.
const INFO_VOICE_RX: &[u8] = b"paranoia-voice-rx";
/// HKDF info-метка для tx-ключа видео-потока (future).
const INFO_VIDEO_TX: &[u8] = b"paranoia-video-tx";
/// HKDF info-метка для rx-ключа видео-потока (future).
const INFO_VIDEO_RX: &[u8] = b"paranoia-video-rx";

fn hkdf_info(stream: StreamId, role_tx: bool) -> &'static [u8] {
    match (stream, role_tx) {
        (StreamId::Voice, true) => INFO_VOICE_TX,
        (StreamId::Voice, false) => INFO_VOICE_RX,
        (StreamId::Video, true) => INFO_VIDEO_TX,
        (StreamId::Video, false) => INFO_VIDEO_RX,
    }
}

/// Парные направленные ключи одной сессии звонка для одного потока (voice
/// или video). Стороны выводят зеркальные пары: tx инициатора == rx ответчика.
///
/// Ключи зануляются в памяти при drop.
#[derive(ZeroizeOnDrop)]
pub struct SessionKeys {
    tx: [u8; VOIP_KEY_LEN],
    rx: [u8; VOIP_KEY_LEN],
}

impl SessionKeys {
    /// Вывести пару сессионных ключей из dialog master key.
    ///
    /// - `master`  — общий ключ диалога (32 байта).
    /// - `session_id` — 16 байт salt'а, уникальный для каждого звонка, генерирует
    ///   инициатор и шлёт в зашифрованном сигнальном offer'е.
    /// - `stream`  — voice/video; меняет info-метку.
    /// - `role`    — кто я в этом звонке. Инициатор: tx-ключ — это «paranoia-…-tx»
    ///   от master/session_id; ответчик: tx-ключ — это «paranoia-…-rx» (то есть
    ///   tx ответчика совпадает с rx инициатора).
    pub fn derive(
        master: &[u8; VOIP_KEY_LEN],
        session_id: &[u8; VOIP_SESSION_ID_LEN],
        stream: StreamId,
        role: Role,
    ) -> Self {
        let hk = Hkdf::<Sha256>::new(Some(session_id), master);
        let (info_tx, info_rx) = match role {
            Role::Initiator => (hkdf_info(stream, true), hkdf_info(stream, false)),
            Role::Responder => (hkdf_info(stream, false), hkdf_info(stream, true)),
        };

        let mut tx = [0u8; VOIP_KEY_LEN];
        let mut rx = [0u8; VOIP_KEY_LEN];
        hk.expand(info_tx, &mut tx)
            .expect("HKDF expand failed for 32 bytes — impossible with SHA-256");
        hk.expand(info_rx, &mut rx)
            .expect("HKDF expand failed for 32 bytes — impossible with SHA-256");

        Self { tx, rx }
    }

    pub fn tx(&self) -> &[u8; VOIP_KEY_LEN] {
        &self.tx
    }

    pub fn rx(&self) -> &[u8; VOIP_KEY_LEN] {
        &self.rx
    }

    /// Явное зануление; вызывается также автоматически при drop.
    pub fn zeroize_now(&mut self) {
        self.tx.zeroize();
        self.rx.zeroize();
    }
}

/// Полный набор ключей для мультиплексированной сессии (voice + video).
///
/// Каждый поток имеет независимую пару tx/rx, выведенную из общего dialog
/// master key и session_id с разной HKDF info-меткой. Ключи в массиве
/// проиндексированы по `StreamId as usize` (Voice=0, Video=1).
pub struct StreamKeys {
    streams: [SessionKeys; 2],
}

impl StreamKeys {
    /// Вывести ключи для обоих потоков одного звонка.
    pub fn derive(
        master: &[u8; VOIP_KEY_LEN],
        session_id: &[u8; VOIP_SESSION_ID_LEN],
        role: Role,
    ) -> Self {
        Self {
            streams: [
                SessionKeys::derive(master, session_id, StreamId::Voice, role),
                SessionKeys::derive(master, session_id, StreamId::Video, role),
            ],
        }
    }

    pub fn voice(&self) -> &SessionKeys {
        &self.streams[StreamId::Voice as usize]
    }

    pub fn video(&self) -> &SessionKeys {
        &self.streams[StreamId::Video as usize]
    }

    /// Получить ключи для конкретного потока.
    pub fn for_stream(&self, s: StreamId) -> &SessionKeys {
        &self.streams[s as usize]
    }

    /// Явное зануление обоих наборов; вызывается также при drop.
    pub fn zeroize_now(&mut self) {
        for k in self.streams.iter_mut() {
            k.zeroize_now();
        }
    }
}

/// Сконструировать 96-битный nonce:
/// `[stream_id:1][direction:1][seq_be:8][0x00:2]`.
///
/// Уникальность пары (key, nonce) обеспечивается монотонным `seq`. Биты
/// stream_id и direction добавляют разделение между потоками и сторонами,
/// чтобы случайное использование одного и того же ключа в разных контекстах
/// не приводило к коллизии nonce.
pub fn build_nonce(stream: StreamId, direction: Direction, seq: u64) -> [u8; VOIP_NONCE_LEN] {
    let mut n = [0u8; VOIP_NONCE_LEN];
    n[0] = stream.as_byte();
    n[1] = direction.as_byte();
    n[2..10].copy_from_slice(&seq.to_be_bytes());
    // n[10..12] остаются нулями (padding).
    n
}

/// AEAD-шифрование одного медиа-пакета.
///
/// `aad` (additional authenticated data) — открытый заголовок пакета: он не
/// шифруется, но его целостность защищена тегом Poly1305. Возвращается
/// `ciphertext || tag` (тег уже в конце — стандартное поведение крейта
/// `chacha20poly1305`).
pub fn aead_encrypt(
    key: &[u8; VOIP_KEY_LEN],
    nonce: &[u8; VOIP_NONCE_LEN],
    aad: &[u8],
    plaintext: &[u8],
) -> Result<Vec<u8>> {
    let cipher = ChaCha20Poly1305::new(Key::from_slice(key));
    cipher
        .encrypt(
            Nonce::from_slice(nonce),
            Payload {
                msg: plaintext,
                aad,
            },
        )
        .map_err(|e| anyhow::anyhow!("AEAD encrypt failed: {e}"))
}

/// AEAD-расшифровка одного медиа-пакета.
///
/// `ciphertext` — `body || 16-byte tag`. Если тег не сходится, возвращается
/// ошибка; вызывающая сторона должна тихо дропнуть пакет.
pub fn aead_decrypt(
    key: &[u8; VOIP_KEY_LEN],
    nonce: &[u8; VOIP_NONCE_LEN],
    aad: &[u8],
    ciphertext: &[u8],
) -> Result<Vec<u8>> {
    if ciphertext.len() < VOIP_TAG_LEN {
        bail!("VoIP ciphertext shorter than Poly1305 tag");
    }
    let cipher = ChaCha20Poly1305::new(Key::from_slice(key));
    cipher
        .decrypt(
            Nonce::from_slice(nonce),
            Payload {
                msg: ciphertext,
                aad,
            },
        )
        .map_err(|_| anyhow::anyhow!("VoIP AEAD decrypt failed"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_master() -> [u8; 32] {
        let mut m = [0u8; 32];
        for (i, b) in m.iter_mut().enumerate() {
            *b = i as u8;
        }
        m
    }

    fn sample_session_id() -> [u8; 16] {
        *b"paranoia-test-01"
    }

    #[test]
    fn initiator_tx_matches_responder_rx() {
        let master = sample_master();
        let sid = sample_session_id();
        let init = SessionKeys::derive(&master, &sid, StreamId::Voice, Role::Initiator);
        let resp = SessionKeys::derive(&master, &sid, StreamId::Voice, Role::Responder);
        assert_eq!(init.tx(), resp.rx());
        assert_eq!(init.rx(), resp.tx());
        assert_ne!(init.tx(), init.rx(), "tx and rx must differ");
    }

    #[test]
    fn voice_and_video_keys_differ() {
        let master = sample_master();
        let sid = sample_session_id();
        let voice = SessionKeys::derive(&master, &sid, StreamId::Voice, Role::Initiator);
        let video = SessionKeys::derive(&master, &sid, StreamId::Video, Role::Initiator);
        assert_ne!(voice.tx(), video.tx());
        assert_ne!(voice.rx(), video.rx());
    }

    #[test]
    fn different_session_ids_yield_different_keys() {
        let master = sample_master();
        let a = SessionKeys::derive(&master, &sample_session_id(), StreamId::Voice, Role::Initiator);
        let b = SessionKeys::derive(&master, b"paranoia-test-02", StreamId::Voice, Role::Initiator);
        assert_ne!(a.tx(), b.tx());
    }

    #[test]
    fn nonce_layout_is_stable() {
        let n = build_nonce(StreamId::Voice, Direction::InitiatorToResponder, 0x0102030405060708);
        assert_eq!(
            n,
            [0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x00, 0x00]
        );

        let n2 = build_nonce(StreamId::Video, Direction::ResponderToInitiator, 1);
        assert_eq!(
            n2,
            [0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00]
        );
    }

    #[test]
    fn aead_roundtrip_with_aad() {
        let key = [7u8; 32];
        let nonce = build_nonce(StreamId::Voice, Direction::InitiatorToResponder, 42);
        let aad = b"header-bytes";
        let pt = b"opus-audio-frame-bytes";
        let ct = aead_encrypt(&key, &nonce, aad, pt).unwrap();
        assert_eq!(ct.len(), pt.len() + VOIP_TAG_LEN);
        let back = aead_decrypt(&key, &nonce, aad, &ct).unwrap();
        assert_eq!(back, pt);
    }

    #[test]
    fn aead_fails_on_aad_mismatch() {
        let key = [7u8; 32];
        let nonce = build_nonce(StreamId::Voice, Direction::InitiatorToResponder, 42);
        let ct = aead_encrypt(&key, &nonce, b"aad-A", b"payload").unwrap();
        assert!(aead_decrypt(&key, &nonce, b"aad-B", &ct).is_err());
    }

    #[test]
    fn aead_fails_on_ciphertext_tamper() {
        let key = [7u8; 32];
        let nonce = build_nonce(StreamId::Voice, Direction::InitiatorToResponder, 42);
        let mut ct = aead_encrypt(&key, &nonce, b"aad", b"payload").unwrap();
        ct[0] ^= 0x01;
        assert!(aead_decrypt(&key, &nonce, b"aad", &ct).is_err());
    }

    #[test]
    fn aead_fails_on_wrong_nonce() {
        let key = [7u8; 32];
        let n1 = build_nonce(StreamId::Voice, Direction::InitiatorToResponder, 1);
        let n2 = build_nonce(StreamId::Voice, Direction::InitiatorToResponder, 2);
        let ct = aead_encrypt(&key, &n1, b"aad", b"payload").unwrap();
        assert!(aead_decrypt(&key, &n2, b"aad", &ct).is_err());
    }

    #[test]
    fn zeroize_on_drop_clears_memory() {
        // Косвенная проверка: после явного zeroize_now ключи занулены.
        let mut keys = SessionKeys::derive(
            &sample_master(),
            &sample_session_id(),
            StreamId::Voice,
            Role::Initiator,
        );
        assert!(keys.tx().iter().any(|&b| b != 0));
        keys.zeroize_now();
        assert!(keys.tx().iter().all(|&b| b == 0));
        assert!(keys.rx().iter().all(|&b| b == 0));
    }
}
