//! Серверный cover на основе [`MaskingProfile`] (schema-cover).
//!
//! Зеркало клиентского [`paranoia_cover`]-адаптера: разворачивает входящие
//! запросы (брутфорс по схемам вида, подтверждение AEAD-тегом) и запечатывает
//! ответы по схемам вида `*_resp`. Альтернатива захардкоженному
//! [`crate::food_delivery_cover::FoodDeliveryCover`].

use crate::Cover;
use crate::routes::{
    call_poll::{ApiResponse as PollResp, CallEnvelopeOut, CallPollRequest},
    call_signal::{ApiResponse as CallSignalResp, CallSignalRequest},
    determinate::{ApiResponse as DetResp, DeterminateRequest},
    map::{ApiResponse as MapResp, MapRequest},
    notify::{ApiResponse as NotifyResp, NotifyRequest},
    pull::{ApiResponse as PullResp, PullRequest},
    push::{ApiResponse as PushResp, PushRequest},
};
use anyhow::Result;
use paranoia_cover::MaskingProfile;
use paranoia_cover::core::{
    CallPollCore, CallPollRespCore, CallSignalCore, DeterminateCore, EnvelopeCore, MapCore,
    MapRespCore, NotifyCore, NotifyRespCore, PacketCore, PullCore, PullRespCore, PushCore,
    PushRespCore, SimpleRespCore, kind,
};
use serde::Serialize;
use serde_json::{Value, json};
use std::sync::Arc;
use tracing::error;

pub struct SchemaCover {
    profile: Arc<MaskingProfile>,
}

impl SchemaCover {
    pub fn new(profile: Arc<MaskingProfile>) -> Self {
        Self { profile }
    }

    fn parse<T: serde::de::DeserializeOwned>(&self, kind: &str, body: &Value) -> Result<T> {
        let inner = paranoia_cover::unwrap(&self.profile, kind, body)?;
        Ok(serde_json::from_slice(&inner)?)
    }

    /// Запечатать ответ. При ошибке (профиль без нужного `*_resp`-вида) логируем
    /// и возвращаем пустой объект — клиент тогда явно не развернёт ответ
    /// (громкий отказ вместо тихой подмены).
    fn seal<T: Serialize>(&self, kind: &str, core: &T) -> Value {
        match serde_json::to_vec(core)
            .map_err(anyhow::Error::from)
            .and_then(|inner| paranoia_cover::wrap_auto(&self.profile, kind, &inner))
        {
            Ok(value) => value,
            Err(e) => {
                error!("schema-cover: failed to wrap '{kind}' response: {e}");
                json!({})
            }
        }
    }
}

impl Cover for SchemaCover {
    fn unwrap_push(&self, body: &Value) -> Result<PushRequest> {
        let c: PushCore = self.parse(kind::PUSH, body)?;
        Ok(PushRequest {
            sender: c.sender,
            recver: c.recver,
            seq: c.seq,
            payload: c.payload,
            sig: c.sig,
        })
    }

    fn unwrap_pull(&self, body: &Value) -> Result<PullRequest> {
        let c: PullCore = self.parse(kind::PULL, body)?;
        Ok(PullRequest {
            sender: c.sender,
            recver: c.recver,
            after_seq: c.after_seq,
            to_seq: c.to_seq,
            sig: c.sig,
        })
    }

    fn unwrap_map(&self, body: &Value) -> Result<MapRequest> {
        let c: MapCore = self.parse(kind::MAP, body)?;
        Ok(MapRequest {
            sender: c.sender,
            recver: c.recver,
            after_seq: c.after_seq,
            to_seq: c.to_seq,
            sig: c.sig,
        })
    }

    fn unwrap_notify(&self, body: &Value) -> Result<NotifyRequest> {
        let c: NotifyCore = self.parse(kind::NOTIFY, body)?;
        Ok(NotifyRequest {
            sender: c.sender,
            partner: c.partner,
            seq: c.seq,
            sig: c.sig,
            long_poll_ms: c.long_poll_ms,
        })
    }

    fn unwrap_determinate(&self, body: &Value) -> Result<DeterminateRequest> {
        let c: DeterminateCore = self.parse(kind::DETERMINATE, body)?;
        Ok(DeterminateRequest {
            sender: c.sender,
            recver: c.recver,
            from_seq: c.from_seq,
            to_seq: c.to_seq,
            sig: c.sig,
        })
    }

    fn unwrap_call_signal(&self, body: &Value) -> Result<CallSignalRequest> {
        let c: CallSignalCore = self.parse(kind::CALL_SIGNAL, body)?;
        Ok(CallSignalRequest {
            sender: c.sender,
            recver: c.recver,
            kind: c.kind,
            payload: c.payload,
            ts_ms: c.ts_ms,
            sig: c.sig,
        })
    }

    fn unwrap_call_poll(&self, body: &Value) -> Result<CallPollRequest> {
        let c: CallPollCore = self.parse(kind::CALL_POLL, body)?;
        Ok(CallPollRequest {
            user: c.user,
            nonce: c.nonce,
            long_poll_ms: c.long_poll_ms,
            sig: c.sig,
        })
    }

    fn wrap_push_response(&self, resp: &PushResp) -> Value {
        self.seal(
            kind::PUSH_RESP,
            &PushRespCore {
                ok: resp.success,
                message: resp.message.clone(),
            },
        )
    }

    fn wrap_pull_response(&self, resp: &PullResp) -> Value {
        let core = if resp.success {
            let packets = resp
                .message
                .as_array()
                .map(|arr| {
                    arr.iter()
                        .filter_map(|item| {
                            Some(PacketCore {
                                seq: item.get("seq")?.as_u64()?,
                                payload: item.get("payload")?.as_str()?.to_string(),
                            })
                        })
                        .collect()
                })
                .unwrap_or_default();
            PullRespCore {
                ok: true,
                packets,
                message: String::new(),
            }
        } else {
            PullRespCore {
                ok: false,
                packets: Vec::new(),
                message: resp
                    .message
                    .as_str()
                    .unwrap_or("error")
                    .to_string(),
            }
        };
        self.seal(kind::PULL_RESP, &core)
    }

    fn wrap_map_response(&self, resp: &MapResp) -> Value {
        self.seal(
            kind::MAP_RESP,
            &MapRespCore {
                ok: resp.success,
                runs: resp.runs.clone(),
                last_seq: resp.last_seq,
                truncated: resp.truncated,
                message: resp.message.clone(),
            },
        )
    }

    fn wrap_notify_response(&self, resp: &NotifyResp) -> Value {
        self.seal(
            kind::NOTIFY_RESP,
            &NotifyRespCore {
                ok: resp.success,
                n: resp.n,
                message: resp.message.clone(),
            },
        )
    }

    fn wrap_determinate_response(&self, resp: &DetResp) -> Value {
        self.seal(
            kind::DETERMINATE_RESP,
            &SimpleRespCore {
                ok: resp.success,
                message: resp.message.clone(),
            },
        )
    }

    fn wrap_call_signal_response(&self, resp: &CallSignalResp) -> Value {
        self.seal(
            kind::CALL_SIGNAL_RESP,
            &SimpleRespCore {
                ok: resp.success,
                message: resp.message.clone(),
            },
        )
    }

    fn wrap_call_poll_response(&self, resp: &PollResp) -> Value {
        let items = resp
            .items
            .iter()
            .map(|e: &CallEnvelopeOut| EnvelopeCore {
                sender: e.sender.clone(),
                kind: e.kind,
                payload: e.payload.clone(),
                ts_ms: e.ts_ms,
            })
            .collect();
        self.seal(
            kind::CALL_POLL_RESP,
            &CallPollRespCore {
                ok: resp.success,
                items,
                message: resp.message.clone(),
            },
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_profile() -> Arc<MaskingProfile> {
        let key = paranoia_cover::b64_encode(&[0u8; 32]);
        let mut kinds = String::new();
        for k in ["push", "pull", "push_resp", "pull_resp"] {
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
    fn unwrap_push_recovers_request() {
        let cover = SchemaCover::new(test_profile());
        let body = paranoia_cover::wrap_auto(
            &cover.profile,
            kind::PUSH,
            &serde_json::to_vec(&PushCore {
                sender: "alice".into(),
                recver: "bob".into(),
                seq: 7,
                payload: "cGF5".into(),
                sig: "c2ln".into(),
            })
            .unwrap(),
        )
        .unwrap();
        let req = cover.unwrap_push(&body).unwrap();
        assert_eq!(req.sender, "alice");
        assert_eq!(req.recver, "bob");
        assert_eq!(req.seq, 7);
        assert_eq!(req.payload, "cGF5");
        assert_eq!(req.sig, "c2ln");
    }

    #[test]
    fn wrap_push_response_is_recoverable() {
        let cover = SchemaCover::new(test_profile());
        let body = cover.wrap_push_response(&PushResp {
            success: false,
            message: "Duplicate seq".into(),
        });
        let inner = paranoia_cover::unwrap(&cover.profile, kind::PUSH_RESP, &body).unwrap();
        let resp: PushRespCore = serde_json::from_slice(&inner).unwrap();
        assert!(!resp.ok);
        assert_eq!(resp.message, "Duplicate seq");
    }

    #[test]
    fn wrap_pull_response_carries_packets() {
        let cover = SchemaCover::new(test_profile());
        let body = cover.wrap_pull_response(&PullResp {
            success: true,
            message: json!([{"seq": 3, "payload": "YWJj"}]),
        });
        let inner = paranoia_cover::unwrap(&cover.profile, kind::PULL_RESP, &body).unwrap();
        let resp: PullRespCore = serde_json::from_slice(&inner).unwrap();
        assert!(resp.ok);
        assert_eq!(resp.packets.len(), 1);
        assert_eq!(resp.packets[0].seq, 3);
        assert_eq!(resp.packets[0].payload, "YWJj");
    }
}
