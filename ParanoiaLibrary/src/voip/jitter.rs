//! Простой jitter buffer для голосовых потоков.
//!
//! Назначение: сглаживать скачки сетевой задержки и переупорядочивать out-of-order
//! пакеты перед декодером. Утилитарная структура — не привязана к транспорту,
//! можно использовать как на стороне получателя VoIP-сессии, так и при тестах.
//!
//! Policy: «initial delay 2–4 фрейма (40–80 ms), late-out-of-window дропается,
//! gap → PLC через NULL-фрейм у opus_decode».
//!
//! Использование:
//! ```ignore
//! let mut jb = JitterBuffer::new(JitterConfig::default());
//! for (seq, opus) in incoming {
//!     jb.push(seq, opus);
//! }
//! // Тикер 20 ms на стороне декодера:
//! match jb.pop_next() {
//!     JitterOut::Frame(opus) => opus_decode(&opus),
//!     JitterOut::Plc => opus_decode_null(),
//!     JitterOut::Wait => {} // ещё не пора отдавать
//! }
//! ```

use std::collections::BTreeMap;

/// Параметры буфера.
#[derive(Debug, Clone, Copy)]
pub struct JitterConfig {
    /// Сколько фреймов накопить, прежде чем начать выдавать (smoothing).
    /// Рекомендация: 2–4 (40–80 ms при 20-ms фреймах).
    pub initial_delay: usize,
    /// Жёсткий потолок длины очереди. При переполнении самые старые фреймы
    /// дропаются (вместе с пропуском их seq) — лучше «разрыв», чем
    /// бесконечная задержка.
    pub max_depth: usize,
}

impl Default for JitterConfig {
    fn default() -> Self {
        Self {
            initial_delay: 3,
            max_depth: 16,
        }
    }
}

/// Что отдаёт `pop_next` тикеру декодера.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum JitterOut {
    /// Готовый фрейм — отправить в `opus_decode`.
    Frame(Vec<u8>),
    /// Пропуск — отправить NULL-фрейм в `opus_decode` (PLC).
    Plc,
    /// Ещё не пора выдавать (накапливаемся / нечего отдавать). Тикер дёрнет ещё
    /// раз через свой интервал.
    Wait,
}

pub struct JitterBuffer {
    cfg: JitterConfig,
    items: BTreeMap<u64, Vec<u8>>,
    /// Следующий ожидаемый seq на выдачу. Устанавливается на первом `pop_next`,
    /// когда мы решаем «начали играть».
    expected: Option<u64>,
    /// Сколько пустых тиков подряд мы выдали PLC — если слишком долго, ресет.
    plc_streak: usize,
}

impl JitterBuffer {
    pub fn new(cfg: JitterConfig) -> Self {
        Self {
            cfg,
            items: BTreeMap::new(),
            expected: None,
            plc_streak: 0,
        }
    }

    /// Положить полученный фрейм. Дубликаты (тот же seq) — игнорируются
    /// (первый «выигрывает», ReplayWindow на уровне транспорта уже дропнет
    /// настоящий replay). Слишком старые (seq < expected, если есть) — drop.
    pub fn push(&mut self, seq: u64, opus: Vec<u8>) {
        if let Some(exp) = self.expected {
            if seq < exp {
                return; // late drop
            }
        }
        // overflow protection: если буфер уже забит, выкидываем самый старый
        if self.items.len() >= self.cfg.max_depth && !self.items.contains_key(&seq) {
            if let Some((&oldest, _)) = self.items.iter().next() {
                self.items.remove(&oldest);
            }
        }
        self.items.entry(seq).or_insert(opus);
    }

    /// Шаг на один фрейм. Возвращает действие для декодера.
    pub fn pop_next(&mut self) -> JitterOut {
        // Перед стартом ждём накопления initial_delay фреймов, чтобы сгладить
        // первоначальные out-of-order.
        if self.expected.is_none() {
            if self.items.len() < self.cfg.initial_delay {
                return JitterOut::Wait;
            }
            // Начинаем с самого раннего, что есть.
            let first = *self.items.iter().next().unwrap().0;
            self.expected = Some(first);
        }
        let exp = self.expected.unwrap();
        if let Some(frame) = self.items.remove(&exp) {
            self.expected = Some(exp + 1);
            self.plc_streak = 0;
            return JitterOut::Frame(frame);
        }
        // Нет ожидаемого: либо позже придёт (но тогда у нас должен быть запас),
        // либо реально потерян.
        let have_later = self
            .items
            .iter()
            .next()
            .map(|(&s, _)| s > exp)
            .unwrap_or(false);
        if !have_later {
            // Буфер пуст после exp — нечего проигрывать. Просим ждать (не PLC),
            // чтобы декодер не «звенел» бесконечно.
            return JitterOut::Wait;
        }
        // У нас есть более новый фрейм — значит exp реально потерян. PLC.
        self.expected = Some(exp + 1);
        self.plc_streak += 1;
        // Если PLC-стрик слишком длинный — переинициализируемся «с самого
        // раннего, что есть», чтобы не отставать от sender'а на сотни мс.
        if self.plc_streak > self.cfg.initial_delay * 4 {
            self.expected = None;
            self.plc_streak = 0;
        }
        JitterOut::Plc
    }

    /// Сбросить состояние (например, при reseed сессии).
    pub fn reset(&mut self) {
        self.items.clear();
        self.expected = None;
        self.plc_streak = 0;
    }

    pub fn depth(&self) -> usize {
        self.items.len()
    }

    pub fn expected_seq(&self) -> Option<u64> {
        self.expected
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn f(n: u8) -> Vec<u8> {
        vec![n]
    }

    #[test]
    fn waits_until_initial_delay_reached() {
        let mut jb = JitterBuffer::new(JitterConfig {
            initial_delay: 3,
            max_depth: 8,
        });
        assert_eq!(jb.pop_next(), JitterOut::Wait);
        jb.push(10, f(1));
        assert_eq!(jb.pop_next(), JitterOut::Wait);
        jb.push(11, f(2));
        assert_eq!(jb.pop_next(), JitterOut::Wait);
        jb.push(12, f(3));
        // теперь готовы выдавать
        assert_eq!(jb.pop_next(), JitterOut::Frame(f(1)));
        assert_eq!(jb.pop_next(), JitterOut::Frame(f(2)));
        assert_eq!(jb.pop_next(), JitterOut::Frame(f(3)));
        // больше ничего нет — Wait, не PLC
        assert_eq!(jb.pop_next(), JitterOut::Wait);
    }

    #[test]
    fn reorders_out_of_order_within_delay() {
        let mut jb = JitterBuffer::new(JitterConfig {
            initial_delay: 3,
            max_depth: 8,
        });
        // приходят 12, 10, 11 — в неправильном порядке
        jb.push(12, f(3));
        jb.push(10, f(1));
        jb.push(11, f(2));
        assert_eq!(jb.pop_next(), JitterOut::Frame(f(1)));
        assert_eq!(jb.pop_next(), JitterOut::Frame(f(2)));
        assert_eq!(jb.pop_next(), JitterOut::Frame(f(3)));
    }

    #[test]
    fn gap_yields_plc_when_we_have_future() {
        let mut jb = JitterBuffer::new(JitterConfig {
            initial_delay: 2,
            max_depth: 8,
        });
        jb.push(5, f(1));
        jb.push(7, f(3));
        // initial_delay=2 удовлетворено
        assert_eq!(jb.pop_next(), JitterOut::Frame(f(1)));
        // exp=6, его нет, но есть 7 → PLC
        assert_eq!(jb.pop_next(), JitterOut::Plc);
        // exp=7
        assert_eq!(jb.pop_next(), JitterOut::Frame(f(3)));
    }

    #[test]
    fn late_after_started_is_dropped() {
        let mut jb = JitterBuffer::new(JitterConfig {
            initial_delay: 2,
            max_depth: 8,
        });
        jb.push(10, f(1));
        jb.push(11, f(2));
        assert_eq!(jb.pop_next(), JitterOut::Frame(f(1)));
        // 9 приходит поздно — выбрасываем
        jb.push(9, f(99));
        assert_eq!(jb.pop_next(), JitterOut::Frame(f(2)));
        // ничего больше — Wait
        assert_eq!(jb.pop_next(), JitterOut::Wait);
    }

    #[test]
    fn duplicate_seq_ignored() {
        let mut jb = JitterBuffer::new(JitterConfig {
            initial_delay: 1,
            max_depth: 8,
        });
        jb.push(5, f(1));
        jb.push(5, f(2)); // дубль — игнор
        assert_eq!(jb.pop_next(), JitterOut::Frame(f(1)));
        assert_eq!(jb.pop_next(), JitterOut::Wait);
    }

    #[test]
    fn overflow_drops_oldest() {
        let cfg = JitterConfig {
            initial_delay: 1,
            max_depth: 4,
        };
        let mut jb = JitterBuffer::new(cfg);
        for s in 0..6u64 {
            jb.push(s, vec![s as u8]);
        }
        // буфер ёмкостью 4, последние 4 элемента: 2,3,4,5
        assert_eq!(jb.depth(), 4);
        assert_eq!(jb.pop_next(), JitterOut::Frame(vec![2]));
        assert_eq!(jb.pop_next(), JitterOut::Frame(vec![3]));
    }

    #[test]
    fn long_plc_streak_resyncs() {
        let cfg = JitterConfig {
            initial_delay: 1,
            max_depth: 16,
        };
        let mut jb = JitterBuffer::new(cfg);
        jb.push(100, f(1));
        assert_eq!(jb.pop_next(), JitterOut::Frame(f(1))); // exp=101
        // вдруг приходит seq 200 — большой пробел
        jb.push(200, f(2));
        // несколько PLC, пока plc_streak не сорвёт expected
        for _ in 0..(cfg.initial_delay * 4 + 1) {
            assert_eq!(jb.pop_next(), JitterOut::Plc);
        }
        // resync произошёл — expected стал None, на следующем pop'е перезапустится с 200
        // (initial_delay=1, items.len()=1, OK)
        assert_eq!(jb.pop_next(), JitterOut::Frame(f(2)));
    }

    #[test]
    fn reset_clears_state() {
        let mut jb = JitterBuffer::new(JitterConfig::default());
        jb.push(5, f(1));
        jb.push(6, f(2));
        jb.push(7, f(3));
        let _ = jb.pop_next();
        jb.reset();
        assert_eq!(jb.depth(), 0);
        assert_eq!(jb.expected_seq(), None);
        assert_eq!(jb.pop_next(), JitterOut::Wait);
    }
}
