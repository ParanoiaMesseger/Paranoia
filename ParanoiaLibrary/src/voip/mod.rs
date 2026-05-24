//! VoIP-стек: голосовые (и в будущем видео) звонки P2P поверх UDP.
//!
//! См. `paranoia_voip_policy.md` в корне репозитория.
//!
//! Этот модуль отделён от messaging-стека: другие криптографические правила
//! (per-packet AEAD), другая транспортная модель (UDP), другая поверхность FFI.
//! Здесь живёт только Rust-ядро: вывод ключей, шифрование пакетов, формат
//! заголовка. Транспорт (Tokio UdpSocket) и сигналинг — отдельными файлами.

pub mod crypto;
pub mod jitter;
pub mod nal;
pub mod packet;
pub mod signaling;
pub mod stun;
pub mod transport;
pub mod turn;
