//! Клиентский cover на основе [`MaskingProfile`] (schema-cover).
//!
//! Альтернатива [`crate::client_cover_food::FoodDeliveryClientCover`]: вместо
//! захардкоженной food-маски маскирует трафик под профиль, загруженный в
//! рантайме. Тело каждого запроса — это inner-core ([`paranoia_cover::core`]),
//! запечатанный AEAD и разложенный по полям-носителям схемы профиля. Ответы
//! сервера разворачиваются тем же движком по схемам вида `*_resp`.

use crate::client_cover::{ClientCover, CoverRoute};
use crate::crypto::{decode_b64, encode_b64};
use crate::transport::{
    CallEnvelopeIn, CoreCallPoll, CoreCallSignal, CoreDeterminate, CoreMap, CoreNotify, CorePull,
    CorePush, MapResponse, RawPacket,
};
use anyhow::{Result, anyhow, bail};
use paranoia_cover::MaskingProfile;
use paranoia_cover::core::{
    CallPollCore, CallPollRespCore, CallSignalCore, DeterminateCore, MapCore, MapRespCore,
    NotifyCore, NotifyRespCore, PullCore, PullRespCore, PushCore, PushRespCore, SimpleRespCore,
    kind,
};
use serde::Serialize;
use serde_json::Value;
use std::sync::Arc;

pub struct SchemaClientCover {
    profile: Arc<MaskingProfile>,
}

impl SchemaClientCover {
    pub fn new(profile: Arc<MaskingProfile>) -> Self {
        Self { profile }
    }

    /// Доступ к профилю (для транспорта: путь/метод/UA/заголовки вида пакета).
    pub fn profile(&self) -> &MaskingProfile {
        &self.profile
    }

    fn wrap_core<T: Serialize>(&self, kind: &str, core: &T) -> Result<Value> {
        let inner = serde_json::to_vec(core)?;
        let mut rng = rand::thread_rng();
        paranoia_cover::wrap(&self.profile, kind, &inner, &mut rng)
    }

    fn unwrap_core<T: serde::de::DeserializeOwned>(&self, kind: &str, body: &Value) -> Result<T> {
        let inner = paranoia_cover::unwrap(&self.profile, kind, body)?;
        Ok(serde_json::from_slice(&inner)?)
    }
}

impl ClientCover for SchemaClientCover {
    fn route(&self, kind: &str) -> Option<CoverRoute> {
        let spec = self.profile.kinds.get(kind)?;
        Some(CoverRoute {
            path: spec.path.clone(),
            method: spec.method.clone(),
        })
    }

    fn wrap_kind(&self, kind: &str, inner: &[u8]) -> Option<Value> {
        // Только если профиль реально содержит этот вид — иначе пусть транспорт
        // шлёт плоско (None).
        self.profile.kinds.get(kind)?;
        let mut rng = rand::thread_rng();
        paranoia_cover::wrap(&self.profile, kind, inner, &mut rng).ok()
    }

    fn unwrap_kind(&self, kind: &str, body: &Value) -> Option<Vec<u8>> {
        paranoia_cover::unwrap(&self.profile, kind, body).ok()
    }

    fn wrap_push(&self, core: &CorePush) -> Result<Value> {
        self.wrap_core(
            kind::PUSH,
            &PushCore {
                sender: core.sender.clone(),
                recver: core.recver.clone(),
                seq: core.seq,
                payload: encode_b64(&core.payload),
                sig: encode_b64(&core.sig),
            },
        )
    }

    fn wrap_pull(&self, core: &CorePull) -> Result<Value> {
        self.wrap_core(
            kind::PULL,
            &PullCore {
                sender: core.sender.clone(),
                recver: core.recver.clone(),
                after_seq: core.after_seq,
                to_seq: core.to_seq,
                sig: encode_b64(&core.sig),
            },
        )
    }

    fn wrap_map(&self, core: &CoreMap) -> Result<Value> {
        self.wrap_core(
            kind::MAP,
            &MapCore {
                sender: core.sender.clone(),
                recver: core.recver.clone(),
                after_seq: core.after_seq,
                to_seq: core.to_seq,
                sig: encode_b64(&core.sig),
            },
        )
    }

    fn wrap_notify(&self, core: &CoreNotify) -> Result<Value> {
        self.wrap_core(
            kind::NOTIFY,
            &NotifyCore {
                sender: core.sender.clone(),
                partner: core.partner.clone(),
                seq: core.seq,
                sig: encode_b64(&core.sig),
            },
        )
    }

    fn wrap_determinate(&self, core: &CoreDeterminate) -> Result<Value> {
        self.wrap_core(
            kind::DETERMINATE,
            &DeterminateCore {
                sender: core.sender.clone(),
                recver: core.recver.clone(),
                from_seq: core.from_seq,
                to_seq: core.to_seq,
                sig: encode_b64(&core.sig),
            },
        )
    }

    fn wrap_call_signal(&self, core: &CoreCallSignal) -> Result<Value> {
        self.wrap_core(
            kind::CALL_SIGNAL,
            &CallSignalCore {
                sender: core.sender.clone(),
                recver: core.recver.clone(),
                kind: core.kind,
                payload: encode_b64(&core.payload),
                ts_ms: core.ts_ms,
                sig: encode_b64(&core.sig),
            },
        )
    }

    fn wrap_call_poll(&self, core: &CoreCallPoll) -> Result<Value> {
        self.wrap_core(
            kind::CALL_POLL,
            &CallPollCore {
                user: core.user.clone(),
                nonce: core.nonce,
                long_poll_ms: core.long_poll_ms,
                sig: encode_b64(&core.sig),
            },
        )
    }

    fn unwrap_pull_response(&self, body: &Value) -> Result<Vec<RawPacket>> {
        let resp: PullRespCore = self.unwrap_core(kind::PULL_RESP, body)?;
        if !resp.ok {
            bail!("Pull failed: {}", resp.message);
        }
        resp.packets
            .into_iter()
            .map(|p| {
                Ok(RawPacket {
                    seq: p.seq,
                    payload: decode_b64(&p.payload)?,
                })
            })
            .collect()
    }

    fn unwrap_map_response(&self, body: &Value) -> Result<MapResponse> {
        let resp: MapRespCore = self.unwrap_core(kind::MAP_RESP, body)?;
        if !resp.ok {
            bail!("Map failed: {}", resp.message);
        }
        Ok(MapResponse {
            runs: resp.runs,
            last_seq: resp.last_seq,
            truncated: resp.truncated,
        })
    }

    fn unwrap_notify_response(&self, body: &Value) -> Result<u64> {
        let resp: NotifyRespCore = self.unwrap_core(kind::NOTIFY_RESP, body)?;
        if !resp.ok {
            bail!("Notify failed: {}", resp.message);
        }
        Ok(resp.n)
    }

    fn unwrap_push_response(&self, body: &Value) -> Result<()> {
        let resp: PushRespCore = self.unwrap_core(kind::PUSH_RESP, body)?;
        if resp.ok {
            return Ok(());
        }
        // Сохраняем те же коды ошибок, что и food-cover — на них завязана логика
        // диалога (anti-dup, ресинхронизация seq).
        let msg = resp.message.to_ascii_lowercase();
        Err(anyhow!(if msg.contains("duplicate") {
            "duplicate_seq".to_string()
        } else if msg.contains("invalid seq") || msg.contains("expected seq") {
            "invalid_seq".to_string()
        } else {
            format!("Push failed: {}", resp.message)
        }))
    }

    fn unwrap_determinate_response(&self, body: &Value) -> Result<()> {
        let resp: SimpleRespCore = self.unwrap_core(kind::DETERMINATE_RESP, body)?;
        if !resp.ok {
            bail!("Determinate failed: {}", resp.message);
        }
        Ok(())
    }

    fn unwrap_call_signal_response(&self, body: &Value) -> Result<()> {
        let resp: SimpleRespCore = self.unwrap_core(kind::CALL_SIGNAL_RESP, body)?;
        if !resp.ok {
            bail!("CallSignal failed: {}", resp.message);
        }
        Ok(())
    }

    fn unwrap_call_poll_response(&self, body: &Value) -> Result<Vec<CallEnvelopeIn>> {
        let resp: CallPollRespCore = self.unwrap_core(kind::CALL_POLL_RESP, body)?;
        if !resp.ok {
            bail!("CallPoll failed: {}", resp.message);
        }
        resp.items
            .into_iter()
            .map(|e| {
                Ok(CallEnvelopeIn {
                    sender: e.sender,
                    kind: e.kind,
                    payload: decode_b64(&e.payload)?,
                    ts_ms: e.ts_ms,
                })
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use paranoia_cover::core::{EnvelopeCore, PacketCore};

    /// Профиль с одной схемой на каждый из нужных видов (по одному
    /// полю-носителю). cover_key = 32 нуля.
    fn test_profile() -> Arc<MaskingProfile> {
        let key = paranoia_cover::b64_encode(&[0u8; 32]);
        let mut kinds = String::new();
        for k in [
            "push", "pull", "map", "notify", "determinate", "call_signal", "call_poll",
            "push_resp", "pull_resp", "map_resp", "notify_resp", "determinate_resp",
            "call_signal_resp", "call_poll_resp",
        ] {
            if !kinds.is_empty() {
                kinds.push(',');
            }
            kinds.push_str(&format!(
                r#""{k}":{{"path":"/{k}","schemas":[{{"template":{{"d":""}},"carriers":["d"]}}]}}"#
            ));
        }
        let json = format!(r#"{{"name":"t","cover_key_b64":"{key}","kinds":{{{kinds}}}}}"#);
        Arc::new(MaskingProfile::from_json(&json).unwrap())
    }

    #[test]
    fn route_comes_from_profile() {
        let cover = SchemaClientCover::new(test_profile());
        let r = cover.route(kind::PUSH).expect("push route");
        assert_eq!(r.path, "/push");
        assert_eq!(r.method, "PUT");
        assert!(cover.route("nonexistent").is_none());
    }

    #[test]
    fn wrap_push_is_recoverable_as_core() {
        let cover = SchemaClientCover::new(test_profile());
        let core = CorePush {
            sender: "alice".into(),
            recver: "bob".into(),
            seq: 42,
            payload: vec![1, 2, 3],
            sig: vec![9, 9],
        };
        let body = cover.wrap_push(&core).unwrap();
        let inner = paranoia_cover::unwrap(cover.profile(), kind::PUSH, &body).unwrap();
        let got: PushCore = serde_json::from_slice(&inner).unwrap();
        assert_eq!(got.sender, "alice");
        assert_eq!(got.recver, "bob");
        assert_eq!(got.seq, 42);
        assert_eq!(got.payload, encode_b64(&[1, 2, 3]));
    }

    #[test]
    fn push_response_roundtrip_and_error_codes() {
        let cover = SchemaClientCover::new(test_profile());

        // Успех.
        let ok_body = paranoia_cover::wrap_auto(
            cover.profile(),
            kind::PUSH_RESP,
            &serde_json::to_vec(&PushRespCore { ok: true, message: String::new() }).unwrap(),
        )
        .unwrap();
        assert!(cover.unwrap_push_response(&ok_body).is_ok());

        // Ошибка duplicate → код "duplicate_seq".
        let dup_body = paranoia_cover::wrap_auto(
            cover.profile(),
            kind::PUSH_RESP,
            &serde_json::to_vec(&PushRespCore {
                ok: false,
                message: "Duplicate seq".into(),
            })
            .unwrap(),
        )
        .unwrap();
        let err = cover.unwrap_push_response(&dup_body).unwrap_err().to_string();
        assert_eq!(err, "duplicate_seq");
    }

    #[test]
    fn pull_and_call_poll_responses_decode() {
        let cover = SchemaClientCover::new(test_profile());

        let pull_body = paranoia_cover::wrap_auto(
            cover.profile(),
            kind::PULL_RESP,
            &serde_json::to_vec(&PullRespCore {
                ok: true,
                packets: vec![PacketCore { seq: 5, payload: encode_b64(&[7, 7]) }],
                message: String::new(),
            })
            .unwrap(),
        )
        .unwrap();
        let packets = cover.unwrap_pull_response(&pull_body).unwrap();
        assert_eq!(packets.len(), 1);
        assert_eq!(packets[0].seq, 5);
        assert_eq!(packets[0].payload, vec![7, 7]);

        let poll_body = paranoia_cover::wrap_auto(
            cover.profile(),
            kind::CALL_POLL_RESP,
            &serde_json::to_vec(&CallPollRespCore {
                ok: true,
                items: vec![EnvelopeCore {
                    sender: "x".into(),
                    kind: 2,
                    payload: encode_b64(&[1]),
                    ts_ms: 123,
                }],
                message: String::new(),
            })
            .unwrap(),
        )
        .unwrap();
        let envs = cover.unwrap_call_poll_response(&poll_body).unwrap();
        assert_eq!(envs.len(), 1);
        assert_eq!(envs[0].sender, "x");
        assert_eq!(envs[0].payload, vec![1]);
    }
}
