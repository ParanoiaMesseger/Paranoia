use anyhow::{Context, Result, anyhow, bail};
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use hkdf::Hkdf;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;
use x25519_dalek::{PublicKey, StaticSecret};

pub const EXCHANGE_VERSION: u8 = 1;
pub const EXCHANGE_TTL_SECS: i64 = 300;

const PROTOCOL: &str = "paranoia.qr-ecdh";
const ROLE_INITIATOR: &str = "initiator";
const ROLE_RESPONDER: &str = "responder";
const ECDH_ALG: &str = "X25519";
const KDF_ALG: &str = "HKDF-SHA256";
const KDF_INFO: &[u8] = b"Paranoia QR ECDH v1 session_key";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ExchangePayload {
    pub protocol: String,
    pub version: u8,
    pub role: String,
    pub exchange_id: String,
    pub initiator_id: String,
    pub responder_id: String,
    pub public_key_b64: String,
    pub expires_at_unix: i64,
    pub ecdh: String,
    pub kdf: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ExchangeState {
    pub protocol: String,
    pub version: u8,
    pub role: String,
    pub exchange_id: String,
    pub initiator_id: String,
    pub responder_id: String,
    pub private_key_b64: String,
    pub public_key_b64: String,
    pub expires_at_unix: i64,
    pub ecdh: String,
    pub kdf: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ExchangeBundle {
    pub state: ExchangeState,
    pub payload: ExchangePayload,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CompletedExchange {
    pub exchange_id: String,
    pub initiator_id: String,
    pub responder_id: String,
    pub session_key_b64: String,
    pub fingerprint: String,
}

impl CompletedExchange {
    pub fn session_key(&self) -> Result<[u8; 32]> {
        decode_key32(&self.session_key_b64, "session_key")
    }
}

pub fn create_invitation(initiator_id: &str, now_unix: i64) -> Result<ExchangeBundle> {
    validate_id("initiator_id", initiator_id)?;

    let exchange_id = Uuid::new_v4().to_string();
    let keypair = generate_x25519_keypair();
    Ok(bundle(
        ROLE_INITIATOR,
        exchange_id,
        initiator_id.to_string(),
        "".to_string(),
        keypair,
        now_unix + EXCHANGE_TTL_SECS,
    ))
}

pub fn create_response(
    invitation: &ExchangePayload,
    responder_id: &str,
    now_unix: i64,
) -> Result<ExchangeBundle> {
    validate_payload(invitation, ROLE_INITIATOR, now_unix)?;
    validate_id("responder_id", responder_id)?;
    if !invitation.responder_id.is_empty() && invitation.responder_id != responder_id {
        bail!("responder_id mismatch");
    }

    let keypair = generate_x25519_keypair();
    Ok(bundle(
        ROLE_RESPONDER,
        invitation.exchange_id.clone(),
        invitation.initiator_id.clone(),
        responder_id.to_string(),
        keypair,
        now_unix + EXCHANGE_TTL_SECS,
    ))
}

pub fn complete_exchange(
    local_state: &ExchangeState,
    peer_payload: &ExchangePayload,
    now_unix: i64,
) -> Result<CompletedExchange> {
    validate_state(local_state, now_unix)?;

    let expected_peer_role = match local_state.role.as_str() {
        ROLE_INITIATOR => ROLE_RESPONDER,
        ROLE_RESPONDER => ROLE_INITIATOR,
        _ => bail!("invalid local role"),
    };
    validate_payload(peer_payload, expected_peer_role, now_unix)?;
    validate_pair(local_state, peer_payload)?;

    let local_private =
        StaticSecret::from(decode_key32(&local_state.private_key_b64, "private_key")?);
    let expected_public = PublicKey::from(&local_private);
    if B64.encode(expected_public.as_bytes()) != local_state.public_key_b64 {
        bail!("local public key does not match private key");
    }

    let peer_public = PublicKey::from(decode_key32(&peer_payload.public_key_b64, "public_key")?);
    let shared = local_private.diffie_hellman(&peer_public);
    if shared.as_bytes().iter().all(|b| *b == 0) {
        bail!("non-contributory x25519 shared secret");
    }

    let (initiator_pub, responder_pub) = if local_state.role == ROLE_INITIATOR {
        (&local_state.public_key_b64, &peer_payload.public_key_b64)
    } else {
        (&peer_payload.public_key_b64, &local_state.public_key_b64)
    };
    // For an open invitation the initiator's state has an empty responder_id;
    // resolve it from the responder's payload so both sides hash the same value.
    let responder_id = if local_state.role == ROLE_INITIATOR {
        peer_payload.responder_id.clone()
    } else {
        local_state.responder_id.clone()
    };
    let transcript_hash = transcript_hash_b64(
        &local_state.exchange_id,
        &local_state.initiator_id,
        &responder_id,
        initiator_pub,
        responder_pub,
    )?;

    let mut session_key = [0u8; 32];
    let hk = Hkdf::<Sha256>::new(Some(&transcript_hash), shared.as_bytes());
    hk.expand(KDF_INFO, &mut session_key)
        .map_err(|_| anyhow!("hkdf output length error"))?;

    Ok(CompletedExchange {
        exchange_id: local_state.exchange_id.clone(),
        initiator_id: local_state.initiator_id.clone(),
        responder_id,
        session_key_b64: B64.encode(session_key),
        fingerprint: fingerprint_from_hash(&transcript_hash),
    })
}

pub fn payload_from_json(json: &str) -> Result<ExchangePayload> {
    let payload: ExchangePayload =
        serde_json::from_str(json).context("invalid exchange payload json")?;
    validate_static_fields(
        &payload.protocol,
        payload.version,
        &payload.ecdh,
        &payload.kdf,
    )?;
    Ok(payload)
}

pub fn state_from_json(json: &str) -> Result<ExchangeState> {
    let state: ExchangeState = serde_json::from_str(json).context("invalid exchange state json")?;
    validate_static_fields(&state.protocol, state.version, &state.ecdh, &state.kdf)?;
    Ok(state)
}

pub fn to_json<T: Serialize>(value: &T) -> Result<String> {
    serde_json::to_string(value).context("serialize exchange json")
}

pub fn reject_known_exchange_id(exchange_id: &str, known_ids: &[String]) -> Result<()> {
    if known_ids.iter().any(|known| known == exchange_id) {
        bail!("exchange_id already used");
    }
    Ok(())
}

pub fn fingerprint_for_payloads(
    initiator_payload: &ExchangePayload,
    responder_payload: &ExchangePayload,
    now_unix: i64,
) -> Result<String> {
    validate_payload(initiator_payload, ROLE_INITIATOR, now_unix)?;
    validate_payload(responder_payload, ROLE_RESPONDER, now_unix)?;
    validate_payload_pair(initiator_payload, responder_payload)?;
    let hash = transcript_hash_b64(
        &initiator_payload.exchange_id,
        &initiator_payload.initiator_id,
        &responder_payload.responder_id,
        &initiator_payload.public_key_b64,
        &responder_payload.public_key_b64,
    )?;
    Ok(fingerprint_from_hash(&hash))
}

fn bundle(
    role: &str,
    exchange_id: String,
    initiator_id: String,
    responder_id: String,
    keypair: X25519Keypair,
    expires_at_unix: i64,
) -> ExchangeBundle {
    ExchangeBundle {
        state: ExchangeState {
            protocol: PROTOCOL.to_string(),
            version: EXCHANGE_VERSION,
            role: role.to_string(),
            exchange_id: exchange_id.clone(),
            initiator_id: initiator_id.clone(),
            responder_id: responder_id.clone(),
            private_key_b64: B64.encode(keypair.private),
            public_key_b64: B64.encode(keypair.public),
            expires_at_unix,
            ecdh: ECDH_ALG.to_string(),
            kdf: KDF_ALG.to_string(),
        },
        payload: ExchangePayload {
            protocol: PROTOCOL.to_string(),
            version: EXCHANGE_VERSION,
            role: role.to_string(),
            exchange_id,
            initiator_id,
            responder_id,
            public_key_b64: B64.encode(keypair.public),
            expires_at_unix,
            ecdh: ECDH_ALG.to_string(),
            kdf: KDF_ALG.to_string(),
        },
    }
}

struct X25519Keypair {
    private: [u8; 32],
    public: [u8; 32],
}

fn generate_x25519_keypair() -> X25519Keypair {
    let mut private = [0u8; 32];
    rand::fill(&mut private);
    let secret = StaticSecret::from(private);
    let public = PublicKey::from(&secret).to_bytes();
    X25519Keypair { private, public }
}

fn validate_id(name: &str, id: &str) -> Result<()> {
    if id.is_empty() {
        bail!("{name} is empty");
    }
    Ok(())
}

fn validate_static_fields(protocol: &str, version: u8, ecdh: &str, kdf: &str) -> Result<()> {
    if protocol != PROTOCOL {
        bail!("unsupported exchange protocol");
    }
    if version != EXCHANGE_VERSION {
        bail!("unsupported exchange version");
    }
    if ecdh != ECDH_ALG || kdf != KDF_ALG {
        bail!("unsupported exchange crypto parameters");
    }
    Ok(())
}

fn validate_payload(payload: &ExchangePayload, expected_role: &str, now_unix: i64) -> Result<()> {
    validate_static_fields(
        &payload.protocol,
        payload.version,
        &payload.ecdh,
        &payload.kdf,
    )?;
    if payload.role != expected_role {
        bail!("unexpected exchange payload role");
    }
    validate_id("exchange_id", &payload.exchange_id)?;
    validate_id("initiator_id", &payload.initiator_id)?;
    // responder_id may be empty in the initiator's payload (open invitation — responder not yet known)
    if expected_role != ROLE_INITIATOR {
        validate_id("responder_id", &payload.responder_id)?;
    }
    decode_key32(&payload.public_key_b64, "public_key")?;
    validate_not_expired(payload.expires_at_unix, now_unix)
}

fn validate_state(state: &ExchangeState, now_unix: i64) -> Result<()> {
    validate_static_fields(&state.protocol, state.version, &state.ecdh, &state.kdf)?;
    if state.role != ROLE_INITIATOR && state.role != ROLE_RESPONDER {
        bail!("unexpected exchange state role");
    }
    validate_id("exchange_id", &state.exchange_id)?;
    validate_id("initiator_id", &state.initiator_id)?;
    // responder_id may be empty for the initiator (open invitation — responder not yet known)
    if state.role != ROLE_INITIATOR {
        validate_id("responder_id", &state.responder_id)?;
    }
    decode_key32(&state.private_key_b64, "private_key")?;
    decode_key32(&state.public_key_b64, "public_key")?;
    validate_not_expired(state.expires_at_unix, now_unix)
}

fn validate_not_expired(expires_at_unix: i64, now_unix: i64) -> Result<()> {
    if now_unix > expires_at_unix {
        bail!("exchange payload expired");
    }
    Ok(())
}

fn validate_pair(local_state: &ExchangeState, peer_payload: &ExchangePayload) -> Result<()> {
    if local_state.exchange_id != peer_payload.exchange_id {
        bail!("exchange_id mismatch");
    }
    if local_state.initiator_id != peer_payload.initiator_id {
        bail!("initiator_id mismatch");
    }
    // One side may have an empty responder_id (open invitation); mismatch only matters when both are set
    let local = &local_state.responder_id;
    let peer = &peer_payload.responder_id;
    if !local.is_empty() && !peer.is_empty() && local != peer {
        bail!("responder_id mismatch");
    }
    Ok(())
}

fn validate_payload_pair(
    initiator_payload: &ExchangePayload,
    responder_payload: &ExchangePayload,
) -> Result<()> {
    if initiator_payload.exchange_id != responder_payload.exchange_id {
        bail!("exchange_id mismatch");
    }
    if initiator_payload.initiator_id != responder_payload.initiator_id {
        bail!("initiator_id mismatch");
    }
    // initiator_payload.responder_id may be empty for an open invitation
    if !initiator_payload.responder_id.is_empty()
        && initiator_payload.responder_id != responder_payload.responder_id
    {
        bail!("responder_id mismatch");
    }
    Ok(())
}

fn transcript_hash_b64(
    exchange_id: &str,
    initiator_id: &str,
    responder_id: &str,
    initiator_pub_b64: &str,
    responder_pub_b64: &str,
) -> Result<[u8; 32]> {
    let initiator_pub = decode_key32(initiator_pub_b64, "initiator_public_key")?;
    let responder_pub = decode_key32(responder_pub_b64, "responder_public_key")?;
    let mut hasher = Sha256::new();
    hasher.update([EXCHANGE_VERSION]);
    hasher.update(exchange_id.as_bytes());
    hasher.update(initiator_id.as_bytes());
    hasher.update(responder_id.as_bytes());
    hasher.update(initiator_pub);
    hasher.update(responder_pub);
    Ok(hasher.finalize().into())
}

fn fingerprint_from_hash(hash: &[u8; 32]) -> String {
    let raw = ((hash[0] as u32) << 16) | ((hash[1] as u32) << 8) | hash[2] as u32;
    format!("{:06}", raw % 1_000_000)
}

fn decode_key32(encoded: &str, field: &str) -> Result<[u8; 32]> {
    let bytes = B64
        .decode(encoded)
        .with_context(|| format!("invalid {field} base64"))?;
    bytes
        .try_into()
        .map_err(|_| anyhow!("invalid {field} length"))
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_700_000_000;

    #[test]
    fn successful_exchange_derives_same_key_and_fingerprint() {
        let invitation = create_invitation("alice", NOW).expect("invitation");
        let response = create_response(&invitation.payload, "bob", NOW + 10).expect("response");

        let from_alice = complete_exchange(&invitation.state, &response.payload, NOW + 20)
            .expect("alice complete");
        let from_bob = complete_exchange(&response.state, &invitation.payload, NOW + 20)
            .expect("bob complete");

        assert_eq!(from_alice.session_key_b64, from_bob.session_key_b64);
        assert_eq!(from_alice.fingerprint, from_bob.fingerprint);
        assert_eq!(from_alice.fingerprint.len(), 6);
        assert!(from_alice.fingerprint.chars().all(|c| c.is_ascii_digit()));
    }

    #[test]
    fn expired_invitation_is_rejected() {
        let invitation = create_invitation("alice", NOW).expect("invitation");
        let err = create_response(&invitation.payload, "bob", NOW + EXCHANGE_TTL_SECS + 1)
            .unwrap_err()
            .to_string();
        assert!(err.contains("expired"));
    }

    #[test]
    fn open_invitation_accepts_any_responder() {
        // create_invitation produces an open invitation (responder_id=""); any peer may respond
        let invitation = create_invitation("alice", NOW).expect("invitation");
        let response = create_response(&invitation.payload, "mallory", NOW + 1)
            .expect("open invitation should accept any responder");
        assert_eq!(response.state.responder_id, "mallory");
    }

    #[test]
    fn known_exchange_id_is_rejected() {
        let invitation = create_invitation("alice", NOW).expect("invitation");
        let known = vec![invitation.payload.exchange_id.clone()];
        let err = reject_known_exchange_id(&invitation.payload.exchange_id, &known)
            .unwrap_err()
            .to_string();
        assert!(err.contains("already used"));
    }

    #[test]
    fn canonical_transcript_is_stable() {
        let invitation = create_invitation("alice", NOW).expect("invitation");
        let response = create_response(&invitation.payload, "bob", NOW + 1).expect("response");

        let first = fingerprint_for_payloads(&invitation.payload, &response.payload, NOW + 2)
            .expect("fingerprint");
        let second = fingerprint_for_payloads(&invitation.payload, &response.payload, NOW + 2)
            .expect("fingerprint");

        assert_eq!(first, second);
    }

    #[test]
    fn changed_ecdh_parameters_change_fingerprint() {
        let invitation = create_invitation("alice", NOW).expect("invitation");
        let response = create_response(&invitation.payload, "bob", NOW + 1).expect("response");
        let original = fingerprint_for_payloads(&invitation.payload, &response.payload, NOW + 2)
            .expect("fingerprint");

        let mut tampered_response = response.payload.clone();
        let other = create_response(&invitation.payload, "bob", NOW + 1).expect("other response");
        tampered_response.public_key_b64 = other.payload.public_key_b64;
        let tampered = fingerprint_for_payloads(&invitation.payload, &tampered_response, NOW + 2)
            .expect("tampered fingerprint");

        assert_ne!(original, tampered);
    }

    #[test]
    fn json_roundtrip_preserves_payload_and_state() {
        let invitation = create_invitation("alice", NOW).expect("invitation");
        let payload_json = to_json(&invitation.payload).expect("payload json");
        let state_json = to_json(&invitation.state).expect("state json");

        assert_eq!(
            payload_from_json(&payload_json).unwrap(),
            invitation.payload
        );
        assert_eq!(state_from_json(&state_json).unwrap(), invitation.state);
    }
}
