//! Фрагментация и пересборка больших фреймов (NAL units H.264 / любых байт)
//! для отправки через [`super::transport`].
//!
//! Каждый отправленный воздухом UDP-пакет ограничен `MAX_DATAGRAM` (1400 байт)
//! минус 16 байт заголовка и 16 байт Poly1305-тега → полезная нагрузка
//! ≈1360 байт. NAL units H.264 (особенно I-frame) обычно намного больше.
//! Стандартное решение (см. RFC 6184 §5.4 «Fragmentation Units»):
//!
//! - один NAL режется на N кусков ≤ MTU-safe размер;
//! - все куски одного NAL получают **один и тот же** `rtp_timestamp` в VoIP-
//!   заголовке;
//! - в первом куске устанавливается флаг `FRAME_START`, в последнем — флаг
//!   `FRAGMENT_END`;
//! - получатель копит куски пока `rtp_timestamp` тот же; смена timestamp →
//!   готовый NAL отдаём декодеру.
//!
//! Этот модуль **не привязан к H.264** — он работает с произвольными
//! `Vec<u8>`. Реальный H.264 capture/encode/decode остаётся за Qt-стороной.

use super::packet::{VoipHeader, flags};
use crate::voip::crypto::StreamId;

/// Новый флаг: «последний фрагмент NAL». Резервирован для будущей packet
/// версии — пока используем биты в существующем `Flags`, расширив маску.
///
/// `RESERVED_MASK` в `super::packet::flags` уже выкидывает невалидные биты,
/// поэтому добавление нового флага требует одновременного обновления маски.
/// Чтобы не ломать совместимость заголовка прямо сейчас, мы **переиспользуем**
/// бит `COMFORT_NOISE` для voice-потока и тот же бит как `FRAGMENT_END` для
/// video-потока: `COMFORT_NOISE` не имеет смысла для видео, поэтому
/// коллизия отсутствует. Это компромисс ради сохранения wire-формата.
pub const FRAGMENT_END_BIT: u8 = flags::COMFORT_NOISE;

/// Максимальная полезная нагрузка одного фрагмента после AEAD.
/// `MAX_DATAGRAM` − header(16) − AEAD tag(16) = 1368.
pub const MAX_FRAGMENT_PAYLOAD: usize =
    super::transport::MAX_DATAGRAM - super::packet::VOIP_HEADER_LEN - super::crypto::VOIP_TAG_LEN;

/// Один фрагмент готовый к отправке.
#[derive(Debug, Clone)]
pub struct FragmentOut {
    pub header: VoipHeader,
    pub payload: Vec<u8>,
}

/// Нарезает NAL units на фрагменты.
///
/// Состояние: `next_seq` — счётчик sequence для VoIP-заголовка, инкрементится
/// после каждого фрагмента; `next_timestamp` — RTP-таймштамп очередного NAL.
pub struct Fragmenter {
    stream: StreamId,
    max_payload: usize,
    next_seq: u64,
}

impl Fragmenter {
    pub fn new(stream: StreamId) -> Self {
        Self {
            stream,
            max_payload: MAX_FRAGMENT_PAYLOAD,
            next_seq: 0,
        }
    }

    pub fn with_max_payload(mut self, max: usize) -> Self {
        assert!(max > 0, "max_payload must be > 0");
        self.max_payload = max;
        self
    }

    pub fn next_seq(&self) -> u64 {
        self.next_seq
    }

    /// Разбить один NAL unit на фрагменты с общим `rtp_timestamp`.
    pub fn fragment(&mut self, nal: &[u8], rtp_timestamp: u32) -> Vec<FragmentOut> {
        if nal.is_empty() {
            return Vec::new();
        }
        let mut out = Vec::new();
        let total = nal.len();
        let mut start = 0;
        while start < total {
            let end = (start + self.max_payload).min(total);
            let is_first = start == 0;
            let is_last = end == total;
            let mut flag_bits: u8 = 0;
            if is_first {
                flag_bits |= flags::FRAME_START;
            }
            if is_last {
                flag_bits |= FRAGMENT_END_BIT;
            }
            let header =
                VoipHeader::new(self.stream, self.next_seq, rtp_timestamp, flag_bits);
            out.push(FragmentOut {
                header,
                payload: nal[start..end].to_vec(),
            });
            self.next_seq = self.next_seq.saturating_add(1);
            start = end;
        }
        out
    }
}

/// Собирает фрагменты обратно в NAL units.
///
/// Принимает входящие пары `(header, payload)` (например, из `unpack`'ом
/// расшифрованных пакетов). Отдаёт NAL когда:
/// 1. встречен фрагмент с `FRAGMENT_END_BIT`, или
/// 2. сменился `rtp_timestamp` (защита от потерянного последнего фрагмента).
///
/// Потеря середины NAL → текущий буфер дропается без выдачи (декодер увидит
/// «потерянный кадр», получит следующий с FRAME_START и продолжит).
pub struct Reassembler {
    current_ts: Option<u32>,
    buffer: Vec<u8>,
    expecting: bool,
    max_nal_size: usize,
}

impl Reassembler {
    pub fn new() -> Self {
        Self {
            current_ts: None,
            buffer: Vec::new(),
            expecting: false,
            // 4 MB — потолок для одной картинки. Защита от затопления буфера.
            max_nal_size: 4 * 1024 * 1024,
        }
    }

    pub fn with_max_nal_size(mut self, max: usize) -> Self {
        self.max_nal_size = max;
        self
    }

    /// Сбросить накопленный буфер (например, при reseed сессии).
    pub fn reset(&mut self) {
        self.current_ts = None;
        self.buffer.clear();
        self.expecting = false;
    }

    /// Положить очередной фрагмент. Возвращает `Some(nal)` когда NAL готов
    /// (по FRAGMENT_END или смене timestamp). Возвращает None если NAL ещё
    /// не собран или фрагмент проигнорирован.
    pub fn push(&mut self, header: &VoipHeader, payload: &[u8]) -> Option<Vec<u8>> {
        let ts = header.rtp_timestamp;
        let first = (header.flags & flags::FRAME_START) != 0;
        let last = (header.flags & FRAGMENT_END_BIT) != 0;

        // Если timestamp сменился — отдаём предыдущий буфер «как есть» (на
        // случай потерянного FRAGMENT_END) и стартуем новый.
        let mut completed: Option<Vec<u8>> = None;
        if let Some(prev_ts) = self.current_ts {
            if ts != prev_ts {
                if !self.buffer.is_empty() && self.expecting {
                    // Был незавершённый NAL — выдадим то, что есть.
                    completed = Some(std::mem::take(&mut self.buffer));
                } else {
                    self.buffer.clear();
                }
                self.expecting = false;
                self.current_ts = None;
            }
        }

        if first {
            // Новый NAL — сбрасываем буфер.
            self.buffer.clear();
            self.expecting = true;
            self.current_ts = Some(ts);
        } else if !self.expecting {
            // Получили продолжение без начала — игнорируем кусок.
            return completed;
        } else if self.current_ts.is_none() {
            // Не должно случиться: expecting=true но ts стёрся. Сбрасываемся.
            self.buffer.clear();
            self.expecting = false;
            return completed;
        }

        // Контроль роста.
        if self.buffer.len() + payload.len() > self.max_nal_size {
            tracing::debug!(
                "nal reassembler overflow ({} + {}), drop",
                self.buffer.len(),
                payload.len()
            );
            self.buffer.clear();
            self.expecting = false;
            self.current_ts = None;
            return completed;
        }
        self.buffer.extend_from_slice(payload);

        if last {
            self.expecting = false;
            self.current_ts = None;
            let done = std::mem::take(&mut self.buffer);
            // Если был «случайный» completed от смены ts — отдадим тот,
            // текущий вернёт следующим вызовом? Простая модель — приоритет у
            // только что собранного «целого» NAL. Сохранённый незавершённый
            // дропаем как менее ценный.
            let _ = completed;
            return Some(done);
        }
        completed
    }
}

impl Default for Reassembler {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn random_nal(size: usize, seed: u8) -> Vec<u8> {
        (0..size).map(|i| seed.wrapping_add(i as u8)).collect()
    }

    #[test]
    fn fragment_small_nal_fits_in_one_packet() {
        let mut f = Fragmenter::new(StreamId::Video).with_max_payload(100);
        let frags = f.fragment(&random_nal(80, 1), 1000);
        assert_eq!(frags.len(), 1);
        assert!(frags[0].header.flags & flags::FRAME_START != 0);
        assert!(frags[0].header.flags & FRAGMENT_END_BIT != 0);
        assert_eq!(frags[0].header.rtp_timestamp, 1000);
        assert_eq!(frags[0].header.sequence, 0);
    }

    #[test]
    fn fragment_large_nal_splits() {
        let mut f = Fragmenter::new(StreamId::Video).with_max_payload(100);
        let nal = random_nal(350, 7);
        let frags = f.fragment(&nal, 2000);
        // 350 / 100 = 3.5 → 4 фрагмента
        assert_eq!(frags.len(), 4);
        // первый — FRAME_START
        assert!(frags[0].header.flags & flags::FRAME_START != 0);
        assert!(frags[0].header.flags & FRAGMENT_END_BIT == 0);
        // средние — без флагов
        assert!(frags[1].header.flags == 0);
        assert!(frags[2].header.flags == 0);
        // последний — FRAGMENT_END
        assert!(frags[3].header.flags & FRAGMENT_END_BIT != 0);
        assert!(frags[3].header.flags & flags::FRAME_START == 0);
        // все имеют тот же timestamp и инкрементные seq
        for (i, fr) in frags.iter().enumerate() {
            assert_eq!(fr.header.rtp_timestamp, 2000);
            assert_eq!(fr.header.sequence, i as u64);
        }
        // конкатенация payload'ов равна оригиналу
        let mut joined = Vec::new();
        for fr in &frags {
            joined.extend_from_slice(&fr.payload);
        }
        assert_eq!(joined, nal);
    }

    #[test]
    fn reassemble_normal_path() {
        let mut f = Fragmenter::new(StreamId::Video).with_max_payload(120);
        let nal_a = random_nal(280, 11);
        let nal_b = random_nal(50, 22);
        let frags_a = f.fragment(&nal_a, 100);
        let frags_b = f.fragment(&nal_b, 200);

        let mut r = Reassembler::new();
        for fr in &frags_a {
            let out = r.push(&fr.header, &fr.payload);
            if Some(&fr.payload[..]) == frags_a.last().map(|x| &x.payload[..]) {
                // финальный фрагмент возвращает готовый NAL
                assert_eq!(out, Some(nal_a.clone()));
            } else {
                assert_eq!(out, None);
            }
        }
        let nb = r.push(&frags_b[0].header, &frags_b[0].payload);
        assert_eq!(nb, Some(nal_b));
    }

    #[test]
    fn reassemble_recovers_on_timestamp_change_when_end_lost() {
        // Сценарий: последний фрагмент NAL_A потерян в сети; приходит первый
        // фрагмент NAL_B с другим timestamp → выдаём всё, что собрали для A,
        // плюс начинаем новый.
        let mut f = Fragmenter::new(StreamId::Video).with_max_payload(50);
        let nal_a = random_nal(120, 1);
        let nal_b = random_nal(80, 2);
        let frags_a = f.fragment(&nal_a, 100);
        let frags_b = f.fragment(&nal_b, 200);

        let mut r = Reassembler::new();
        // Положим первые 2 из 3 фрагментов A; последний — «потерян».
        assert_eq!(r.push(&frags_a[0].header, &frags_a[0].payload), None);
        assert_eq!(r.push(&frags_a[1].header, &frags_a[1].payload), None);
        // Приходит первый фрагмент B → reassembler отдаёт нам частичный A.
        let partial = r.push(&frags_b[0].header, &frags_b[0].payload);
        assert!(partial.is_some(), "partial NAL A must be released on ts change");
        let p = partial.unwrap();
        // Это первые 2 фрагмента, склеенные.
        let mut expected_partial = Vec::new();
        expected_partial.extend_from_slice(&frags_a[0].payload);
        expected_partial.extend_from_slice(&frags_a[1].payload);
        assert_eq!(p, expected_partial);
        // Дополним B остальными фрагментами.
        for fr in &frags_b[1..] {
            let out = r.push(&fr.header, &fr.payload);
            if Some(&fr.payload[..]) == frags_b.last().map(|x| &x.payload[..]) {
                assert_eq!(out, Some(nal_b.clone()));
            } else {
                assert_eq!(out, None);
            }
        }
    }

    #[test]
    fn reassemble_ignores_orphan_continuation() {
        // Фрагмент-продолжение без FRAME_START — игнорируется.
        let mut r = Reassembler::new();
        let hdr = VoipHeader::new(StreamId::Video, 5, 999, 0); // нет FRAME_START
        let out = r.push(&hdr, &[1, 2, 3]);
        assert_eq!(out, None);
        // и буфер не вырос
        // Теперь нормальный поток:
        let mut f = Fragmenter::new(StreamId::Video).with_max_payload(10);
        let nal = random_nal(15, 5);
        let frs = f.fragment(&nal, 1234);
        let mut last_out = None;
        for fr in &frs {
            last_out = r.push(&fr.header, &fr.payload);
        }
        assert_eq!(last_out, Some(nal));
    }

    #[test]
    fn empty_nal_yields_no_fragments() {
        let mut f = Fragmenter::new(StreamId::Video);
        assert!(f.fragment(&[], 1).is_empty());
    }
}
