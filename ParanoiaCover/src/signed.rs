//! Подписанный masking-профиль для раздачи.
//!
//! Профиль подписывается **extended-ключом** (офлайн в панели) и
//! распространяется: ручными архивами (Private) или подписанным API-каналом
//! (Commercial/Corporate). Клиент применяет профиль ТОЛЬКО после проверки
//! подписи **доверенным ключом** (сконфигурированным заранее) — иначе цензор/
//! MITM мог бы подсунуть вредоносный профиль (downgrade/деанонимизация).
//! См. security-tradeoffs §7.

use crate::profile::MaskingProfile;
use anyhow::{Result, anyhow};
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use serde::{Deserialize, Serialize};

/// Конверт раздачи: сырой JSON профиля + подпись над его байтами.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignedProfile {
    /// Ровно те байты профиля, над которыми сделана подпись.
    pub profile_json: String,
    /// Ed25519-подпись над `profile_json` (base64).
    pub sig_b64: String,
}

impl SignedProfile {
    pub fn from_json(s: &str) -> Result<Self> {
        serde_json::from_str(s).map_err(|e| anyhow!("bad signed-profile json: {e}"))
    }
    pub fn to_json(&self) -> String {
        serde_json::to_string(self).expect("SignedProfile serializes")
    }
}

/// Подписать профиль extended-ключом (32-байтный Ed25519 seed). Профиль
/// предварительно валидируется (не подписываем некорректный).
pub fn sign_profile(profile_json: &str, signing_seed: &[u8; 32]) -> Result<SignedProfile> {
    MaskingProfile::from_json(profile_json)?; // validate
    let sk = SigningKey::from_bytes(signing_seed);
    let sig = sk.sign(profile_json.as_bytes());
    Ok(SignedProfile {
        profile_json: profile_json.to_string(),
        sig_b64: B64.encode(sig.to_bytes()),
    })
}

/// Проверить подпись конверта ДОВЕРЕННЫМ ключом и распарсить профиль.
/// Доверенный ключ задаётся заранее (не берётся из конверта).
pub fn verify_profile(
    signed: &SignedProfile,
    trusted_pubkey: &[u8; 32],
) -> Result<MaskingProfile> {
    let vk = VerifyingKey::from_bytes(trusted_pubkey)
        .map_err(|e| anyhow!("bad trusted pubkey: {e}"))?;
    let sig_bytes = B64
        .decode(signed.sig_b64.trim())
        .map_err(|e| anyhow!("bad sig b64: {e}"))?;
    let sig = Signature::from_slice(&sig_bytes).map_err(|e| anyhow!("bad sig: {e}"))?;
    vk.verify(signed.profile_json.as_bytes(), &sig)
        .map_err(|_| anyhow!("profile signature invalid"))?;
    MaskingProfile::from_json(&signed.profile_json)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::b64_encode;

    fn sample_profile() -> String {
        let key = b64_encode(&[0u8; 32]);
        format!(
            r#"{{"name":"t","cover_key_b64":"{key}","kinds":{{"push":{{"path":"/p","schemas":[{{"template":{{"d":""}},"carriers":["d"]}}]}}}}}}"#
        )
    }

    #[test]
    fn sign_then_verify_roundtrips() {
        let seed = [9u8; 32];
        let pubkey = SigningKey::from_bytes(&seed).verifying_key().to_bytes();
        let signed = sign_profile(&sample_profile(), &seed).unwrap();
        let profile = verify_profile(&signed, &pubkey).unwrap();
        assert_eq!(profile.name, "t");
        // round-trip через JSON-конверт
        let envelope = signed.to_json();
        let parsed = SignedProfile::from_json(&envelope).unwrap();
        assert!(verify_profile(&parsed, &pubkey).is_ok());
    }

    #[test]
    fn wrong_trusted_key_rejected() {
        let signed = sign_profile(&sample_profile(), &[9u8; 32]).unwrap();
        let other_pub = SigningKey::from_bytes(&[1u8; 32]).verifying_key().to_bytes();
        assert!(verify_profile(&signed, &other_pub).is_err());
    }

    #[test]
    fn tampered_profile_rejected() {
        let seed = [9u8; 32];
        let pubkey = SigningKey::from_bytes(&seed).verifying_key().to_bytes();
        let mut signed = sign_profile(&sample_profile(), &seed).unwrap();
        // Подменяем профиль после подписи → проверка должна провалиться.
        signed.profile_json = signed.profile_json.replace("\"name\":\"t\"", "\"name\":\"evil\"");
        assert!(verify_profile(&signed, &pubkey).is_err());
    }

    #[test]
    fn signing_rejects_invalid_profile() {
        assert!(sign_profile("{not a profile}", &[9u8; 32]).is_err());
    }
}
