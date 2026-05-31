//! Общий движок schema-cover для Paranoia.
//!
//! Маскирует протокольные сообщения под произвольный «легитимный» JSON-API,
//! описанный masking-профилем. Один и тот же код используют клиент
//! (`ParanoiaLibrary`) и сервер (`ParanoiaServer`) — формат конверта побайтово
//! совместим, ручная синхронизация не нужна.
//!
//! Модель:
//! - **Профиль** ([`MaskingProfile`]) описывает «фейковое приложение»: для
//!   каждого вида пакета (`push`, `pull`, … и ответы) — путь, HTTP-метод и до
//!   [`profile::MAX_SCHEMAS_PER_KIND`] схем-вариантов. Плюс пул User-Agent,
//!   заголовки, Cache-Control и симметричный cover-ключ.
//! - **wrap** ([`wrap`]) берёт «внутренние» байты (сериализованное ядро
//!   сообщения), запечатывает их AEAD (ChaCha20-Poly1305) на cover-ключе,
//!   режет шифртекст по полям-носителям случайно выбранной схемы и заполняет
//!   декой-структуру (с опциональными полями и случайным порядком ключей).
//! - **unwrap** ([`unwrap`]) перебирает схемы вида, собирает поля-носители и
//!   подтверждает верную схему **AEAD-тегом** (без ковертных идентификаторов).
//!
//! Замечание по безопасности: cover-ключ — НЕ ключ конфиденциальности
//! сообщений (содержимое защищено отдельным E2E-шифрованием). Его роль —
//! сделать поля-носители неотличимыми от случайных данных и развязать
//! неоднозначность при брутфорс-разворачивании. Компрометация cover-ключа
//! позволяет структурно размаскировать трафик, но не прочитать его.

pub mod core;
pub mod engine;
#[cfg(feature = "schema-gen")]
pub mod schema_gen;
pub mod profile;
pub mod signed;
#[cfg(feature = "validation")]
pub mod validate;

pub use engine::{b64_decode, b64_encode, unwrap, wrap, wrap_auto};
#[cfg(feature = "schema-gen")]
pub use schema_gen::{generate_random_path, generate_random_schema};
pub use profile::{KindSpec, MaskingProfile, OptionalField, SchemaVariant};
pub use signed::{SignedProfile, sign_profile, verify_profile};
