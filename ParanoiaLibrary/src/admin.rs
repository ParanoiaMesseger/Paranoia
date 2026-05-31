use anyhow::{Context, Result, anyhow};
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use ed25519_dalek::{SecretKey, Signature, Signer, SigningKey, VerifyingKey};
use rand::RngCore;

/// Пара ключей администратора в памяти.
pub struct AdminKeyPair {
    pub sk: SigningKey,
    pub pk: VerifyingKey,
}

impl AdminKeyPair {
    /// Сгенерировать новую пару ключей.
    pub fn generate() -> Self {
        let mut secret = SecretKey::default();
        rand::rngs::OsRng.fill_bytes(&mut secret);
        let sk = SigningKey::from_bytes(&secret);
        let pk = sk.verifying_key();
        Self { sk, pk }
    }

    /// Создать из приватного ключа в base64 (32 байта).
    pub fn from_secret_b64(sk_b64: &str) -> Result<Self> {
        let bytes = B64.decode(sk_b64).context("Bad admin secret base64")?;
        if bytes.len() != 32 {
            return Err(anyhow!(
                "Admin secret must be 32 bytes, got {}",
                bytes.len()
            ));
        }
        let mut sk_bytes = [0u8; 32];
        sk_bytes.copy_from_slice(&bytes);
        let sk = SigningKey::from_bytes(&sk_bytes);
        let pk = sk.verifying_key();
        Ok(Self { sk, pk })
    }

    /// Вернуть публичный ключ в base64 (32 байта) — это то, что кладём в server config `admin_key`.
    pub fn pubkey_b64(&self) -> String {
        let pk_bytes = self.pk.to_bytes(); // [u8; 32]
        B64.encode(pk_bytes)
    }

    /// Вернуть приватный ключ в base64 (32 байта) для хранения админом (офлайн).
    pub fn secret_b64(&self) -> String {
        let sk_bytes = self.sk.to_bytes(); // [u8; 32]
        B64.encode(sk_bytes)
    }

    /// Подписать произвольное каноническое сообщение admin-API.
    /// Используется в [`crate::admin_api`] для подписи запросов управления
    /// сервером. Возвращает base64 Ed25519-подпись (64 байта).
    pub fn sign_canonical(&self, message: &str) -> String {
        let sig: Signature = self.sk.sign(message.as_bytes());
        B64.encode(sig.to_bytes())
    }

    /// Сгенерировать admin_sig для регистрации пользователя.
    ///
    /// `username` — логин пользователя,
    /// `user_pubkey_b64` — его публичный ключ в base64 (32 байта), как отправится в поле `pub_key`.
    pub fn sign_user_registration(&self, username: &str, user_pubkey_b64: &str) -> String {
        let msg = format!("{username}{user_pubkey_b64}");
        let sig: Signature = self.sk.sign(msg.as_bytes());
        B64.encode(sig.to_bytes())
    }
}
