use crate::client_cover::ClientCover;
use crate::crypto::{decode_b64, encode_b64};
use crate::transport::{
    CallEnvelopeIn, CoreCallPoll, CoreCallSignal, CoreDeterminate, CoreMap, CoreNotify, CorePull,
    CorePush, MapResponse, RawPacket,
};
use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
pub struct FoodDeliveryClientCover;

impl FoodDeliveryClientCover {
    pub fn new() -> Self {
        Self
    }

    fn split4(&self, data: &[u8], seed: &[u8]) -> [Vec<u8>; 4] {
        if data.is_empty() {
            return Default::default();
        }
        let h = Sha256::digest(seed);
        let n = data.len();
        let mut c = [h[0] as usize % n, h[1] as usize % n, h[2] as usize % n];
        c.sort_unstable();
        let b = [0, c[0], c[1], c[2], n];
        std::array::from_fn(|i| data[b[i]..b[i + 1]].to_vec())
    }
}

fn check_ok(body: &Value, op: &str) -> Result<()> {
    body["ok"]
        .as_bool()
        .unwrap_or(false)
        .then_some(())
        .ok_or_else(|| anyhow!("{op} failed: {body}"))
}

impl ClientCover for FoodDeliveryClientCover {
    fn wrap_push(&self, core: &CorePush) -> Result<Value> {
        let seed = format!("ORD-{}-{}-{}", core.sender, core.recver, core.seq);
        let raw = serde_json::to_vec(&json!({
            "sender": core.sender, "recver": core.recver,
            "seq": core.seq,
            "payload": encode_b64(&core.payload),
            "sig": encode_b64(&core.sig),
        }))?;
        let [p1, p2, p3, p4] = self.split4(&raw, seed.as_bytes()).map(|p| encode_b64(&p));
        Ok(json!({
            "operation": "updateOrder", "orderId": seed,
            "client": {"id": core.sender, "segment": "retail"},
            "items": [{"sku": core.recver, "qty": 1}],
            "meta": {"p1":p1,"p2":p2,"p3":p3,"p4":p4},
        }))
    }

    fn wrap_pull(&self, core: &CorePull) -> Result<Value> {
        Ok(json!({
            "operation": "syncOrders",
            "clientId": core.sender, "partnerId": core.recver,
            "cursor": core.after_seq, "toSeq": core.to_seq,
            "auth": encode_b64(&core.sig),
        }))
    }

    fn wrap_notify(&self, core: &CoreNotify) -> Result<Value> {
        Ok(json!({
            "operation": "checkOrders",
            "clientId": core.sender, "partnerId": core.partner,
            "cursor": core.seq, "auth": encode_b64(&core.sig),
            // long-poll: сервер читает опц. waitMs (0/нет → короткий поллинг).
            "waitMs": core.long_poll_ms,
        }))
    }

    fn wrap_map(&self, core: &CoreMap) -> Result<Value> {
        Ok(json!({
            "operation": "scanInventory",
            "clientId": core.sender, "partnerId": core.recver,
            "cursor": core.after_seq, "toSeq": core.to_seq,
            "auth": encode_b64(&core.sig),
        }))
    }

    fn wrap_determinate(&self, core: &CoreDeterminate) -> Result<Value> {
        Ok(json!({
            "operation": "cleanupHistory",
            "clientId": core.sender, "partnerId": core.recver,
            "fromSeq": core.from_seq, "toSeq": core.to_seq,
            "auth": encode_b64(&core.sig),
        }))
    }

    fn unwrap_pull_response(&self, body: &Value) -> Result<Vec<RawPacket>> {
        check_ok(body, "Pull")?;
        body["orders"]
            .as_array()
            .ok_or_else(|| anyhow!("Pull: expected 'orders' array"))?
            .iter()
            .map(|item| {
                Ok(RawPacket {
                    seq: item["id"].as_u64().ok_or_else(|| anyhow!("Missing id"))?,
                    payload: decode_b64(
                        item["blob"]
                            .as_str()
                            .ok_or_else(|| anyhow!("Missing blob"))?,
                    )?,
                })
            })
            .collect()
    }

    fn unwrap_map_response(&self, body: &Value) -> Result<MapResponse> {
        check_ok(body, "Map")?;
        let shelves = body["shelves"]
            .as_array()
            .ok_or_else(|| anyhow!("Map: expected 'shelves' array"))?;
        let mut runs = Vec::with_capacity(shelves.len());
        for shelf in shelves {
            let arr = shelf
                .as_array()
                .ok_or_else(|| anyhow!("Map: shelf is not an array"))?;
            if arr.len() != 2 {
                return Err(anyhow!("Map: shelf must be [begin, end]"));
            }
            let begin = arr[0]
                .as_u64()
                .ok_or_else(|| anyhow!("Map: bad shelf begin"))?;
            let end = arr[1]
                .as_u64()
                .ok_or_else(|| anyhow!("Map: bad shelf end"))?;
            runs.push((begin, end));
        }
        Ok(MapResponse {
            runs,
            last_seq: body["topShelf"]
                .as_u64()
                .ok_or_else(|| anyhow!("Map: missing topShelf"))?,
            truncated: body["more"].as_bool().unwrap_or(false),
        })
    }

    fn unwrap_notify_response(&self, body: &Value) -> Result<u64> {
        check_ok(body, "Notify")?;
        body["n"]
            .as_u64()
            .ok_or_else(|| anyhow!("Notify: missing n"))
    }

    fn unwrap_push_response(&self, body: &Value) -> Result<()> {
        if body["ok"].as_bool().unwrap_or(false) {
            return Ok(());
        }
        let msg = body["message"].as_str().unwrap_or("").to_ascii_lowercase();
        Err(anyhow!(if msg.contains("duplicate") {
            "duplicate_seq"
        } else if msg.contains("invalid seq") || msg.contains("expected seq") {
            "invalid_seq"
        } else {
            "Push failed: {msg}"
        }))
    }

    fn unwrap_determinate_response(&self, body: &Value) -> Result<()> {
        check_ok(body, "Determinate")
    }

    fn wrap_call_signal(&self, core: &CoreCallSignal) -> Result<Value> {
        Ok(json!({
            "operation": "dispatchCourier",
            "courierId": core.sender,
            "targetId": core.recver,
            "stage": core.kind,
            "issuedAt": core.ts_ms,
            "manifest": encode_b64(&core.payload),
            "auth": encode_b64(&core.sig),
        }))
    }

    fn wrap_call_poll(&self, core: &CoreCallPoll) -> Result<Value> {
        Ok(json!({
            "operation": "pollDispatch",
            "courierId": core.user,
            "nonce": core.nonce,
            "waitMs": core.long_poll_ms,
            "auth": encode_b64(&core.sig),
        }))
    }

    fn unwrap_call_signal_response(&self, body: &Value) -> Result<()> {
        check_ok(body, "CallSignal")
    }

    fn unwrap_call_poll_response(&self, body: &Value) -> Result<Vec<CallEnvelopeIn>> {
        check_ok(body, "CallPoll")?;
        let arr = body["tasks"]
            .as_array()
            .ok_or_else(|| anyhow!("CallPoll: expected 'tasks' array"))?;
        arr.iter()
            .map(|item| {
                Ok(CallEnvelopeIn {
                    sender: item["from"]
                        .as_str()
                        .ok_or_else(|| anyhow!("CallPoll: missing from"))?
                        .to_string(),
                    kind: u8::try_from(
                        item["stage"]
                            .as_u64()
                            .ok_or_else(|| anyhow!("CallPoll: missing stage"))?,
                    )
                    .map_err(|_| anyhow!("CallPoll: stage out of range"))?,
                    payload: decode_b64(
                        item["manifest"]
                            .as_str()
                            .ok_or_else(|| anyhow!("CallPoll: missing manifest"))?,
                    )?,
                    ts_ms: item["issuedAt"]
                        .as_i64()
                        .ok_or_else(|| anyhow!("CallPoll: missing issuedAt"))?,
                })
            })
            .collect()
    }
}
