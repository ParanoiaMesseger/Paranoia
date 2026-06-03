//! PKCS#11 (cryptoki) — защита master-key vault аппаратным токеном.
//!
//! Master-key хранилища оборачивается RSA-OAEP на ключе, который **физически не
//! покидает токен** (`CKA_EXTRACTABLE=false`). Разблокировка требует физического
//! токена + его PIN (`C_Login`). Только под фичей `pkcs11` (панель), мобильный
//! клиент cryptoki не тянет.

use anyhow::{Result, anyhow};
use cryptoki::context::{CInitializeArgs, Pkcs11};
use cryptoki::mechanism::Mechanism;
use cryptoki::mechanism::rsa::{PkcsMgfType, PkcsOaepParams, PkcsOaepSource};
use cryptoki::mechanism::MechanismType;
use cryptoki::object::{Attribute, ObjectClass, ObjectHandle};
use cryptoki::session::{Session, UserType};
use cryptoki::types::AuthPin;

/// Фиксированный CKA_ID/метка ключа vault на токене.
const KEY_ID: &[u8] = b"paranoia-vault";
const KEY_LABEL: &[u8] = b"paranoia-vault-kek";

fn oaep() -> Mechanism<'static> {
    Mechanism::RsaPkcsOaep(PkcsOaepParams::new(
        MechanismType::SHA1,
        PkcsMgfType::MGF1_SHA1,
        PkcsOaepSource::empty(),
    ))
}

/// Открыть R/W-сессию на первом токене и залогиниться PIN'ом.
fn login(module_path: &str, pin: &str) -> Result<(Pkcs11, Session)> {
    let pkcs11 =
        Pkcs11::new(module_path).map_err(|e| anyhow!("pkcs11 load {module_path}: {e}"))?;
    pkcs11
        .initialize(CInitializeArgs::OsThreads)
        .map_err(|e| anyhow!("pkcs11 initialize: {e}"))?;
    let slot = pkcs11
        .get_slots_with_token()
        .map_err(|e| anyhow!("pkcs11 slots: {e}"))?
        .into_iter()
        .next()
        .ok_or_else(|| anyhow!("no PKCS#11 token present"))?;
    let session = pkcs11
        .open_rw_session(slot)
        .map_err(|e| anyhow!("pkcs11 open session: {e}"))?;
    session
        .login(UserType::User, Some(&AuthPin::new(pin.to_string())))
        .map_err(|e| anyhow!("pkcs11 login (wrong token PIN?): {e}"))?;
    Ok((pkcs11, session))
}

fn find_one(session: &Session, class: ObjectClass) -> Result<Option<ObjectHandle>> {
    let template = vec![Attribute::Class(class), Attribute::Id(KEY_ID.to_vec())];
    let mut found = session
        .find_objects(&template)
        .map_err(|e| anyhow!("pkcs11 find: {e}"))?;
    Ok(found.drain(..).next())
}

/// Сгенерировать на токене RSA-2048 keypair vault (приватный — неизвлекаемый).
fn generate_keypair(session: &Session) -> Result<ObjectHandle> {
    let pub_template = vec![
        Attribute::Token(true),
        Attribute::Private(false),
        Attribute::Encrypt(true),
        Attribute::ModulusBits(2048.into()),
        Attribute::PublicExponent(vec![0x01, 0x00, 0x01]),
        Attribute::Label(KEY_LABEL.to_vec()),
        Attribute::Id(KEY_ID.to_vec()),
    ];
    let priv_template = vec![
        Attribute::Token(true),
        Attribute::Private(true),
        Attribute::Sensitive(true),
        Attribute::Extractable(false),
        Attribute::Decrypt(true),
        Attribute::Label(KEY_LABEL.to_vec()),
        Attribute::Id(KEY_ID.to_vec()),
    ];
    let (public, _private) = session
        .generate_key_pair(&Mechanism::RsaPkcsKeyPairGen, &pub_template, &priv_template)
        .map_err(|e| anyhow!("pkcs11 keygen: {e}"))?;
    Ok(public)
}

/// Обернуть `master` ключом токена. Если ключа vault на токене нет — создаёт.
/// Возвращает шифртекст (для хранения в vault.json).
pub fn wrap_master(module_path: &str, pin: &str, master: &[u8]) -> Result<Vec<u8>> {
    let (_pkcs11, session) = login(module_path, pin)?;
    let public = match find_one(&session, ObjectClass::PUBLIC_KEY)? {
        Some(h) => h,
        None => generate_keypair(&session)?,
    };
    session
        .encrypt(&oaep(), public, master)
        .map_err(|e| anyhow!("pkcs11 wrap: {e}"))
}

/// Развернуть `wrapped` приватным ключом токена (на чипе). Требует токен + PIN.
pub fn unwrap_master(module_path: &str, pin: &str, wrapped: &[u8]) -> Result<Vec<u8>> {
    let (_pkcs11, session) = login(module_path, pin)?;
    let private = find_one(&session, ObjectClass::PRIVATE_KEY)?
        .ok_or_else(|| anyhow!("vault key not found on token"))?;
    session
        .decrypt(&oaep(), private, wrapped)
        .map_err(|e| anyhow!("pkcs11 unwrap: {e}"))
}

/// Проверить, что токен доступен и PIN верный (для UX перед инициализацией).
pub fn check_token(module_path: &str, pin: &str) -> Result<()> {
    let _ = login(module_path, pin)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Интеграционный тест против реального PKCS#11-модуля. Пропускается, если
    /// не заданы env PARANOIA_PKCS11_MODULE и PARANOIA_PKCS11_PIN (CI без токена).
    /// Локально: SOFTHSM2_CONF=... PARANOIA_PKCS11_MODULE=/usr/lib/softhsm/libsofthsm2.so
    /// PARANOIA_PKCS11_PIN=1234 cargo test --features pkcs11 pkcs11
    #[test]
    fn wrap_unwrap_roundtrip_on_token() {
        let (module, pin) = match (
            std::env::var("PARANOIA_PKCS11_MODULE"),
            std::env::var("PARANOIA_PKCS11_PIN"),
        ) {
            (Ok(m), Ok(p)) => (m, p),
            _ => {
                eprintln!("skipping pkcs11 token test: PARANOIA_PKCS11_MODULE/PIN not set");
                return;
            }
        };
        let master = [7u8; 32];
        let wrapped = wrap_master(&module, &pin, &master).expect("wrap");
        assert_ne!(wrapped.as_slice(), &master[..], "wrapped must differ from plaintext");
        let back = unwrap_master(&module, &pin, &wrapped).expect("unwrap");
        assert_eq!(back, master.to_vec());
    }
}
