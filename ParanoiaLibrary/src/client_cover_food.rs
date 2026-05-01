use crate::client_cover::ClientCover;
use crate::crypto::{decode_b64, encode_b64};
use crate::transport::{CoreDeterminate, CorePull, CorePush, RawPacket};
use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

pub struct FoodDeliveryClientCover;

impl FoodDeliveryClientCover {
    pub fn new() -> Self {
        Self
    }

    fn split_bytes(&self, data: &[u8], seed: &[u8]) -> [Vec<u8>; 4] {
        if data.is_empty() {
            return [Vec::new(), Vec::new(), Vec::new(), Vec::new()];
        }
        let mut hasher = Sha256::new();
        hasher.update(seed);
        let h = hasher.finalize();

        let n = data.len();
        let mut points = [
            (h[0] as usize) % n,
            (h[1] as usize) % n,
            (h[2] as usize) % n,
        ];
        points.sort();

        let mut parts: Vec<Vec<u8>> = Vec::new();
        let mut last = 0;
        for p in points {
            if p > last {
                parts.push(data[last..p].to_vec());
                last = p;
            }
        }
        if last < n {
            parts.push(data[last..].to_vec());
        }
        while parts.len() < 4 {
            parts.push(Vec::new());
        }
        [
            parts[0].clone(),
            parts[1].clone(),
            parts[2].clone(),
            parts[3].clone(),
        ]
    }
}

impl ClientCover for FoodDeliveryClientCover {
    fn wrap_push(&self, core: &CorePush) -> Result<Value> {
        let payload_b64 = encode_b64(&core.payload);
        let sig_b64 = encode_b64(&core.sig);

        let core_json = json!({
            "sender":  core.sender,
            "recver":  core.recver,
            "seq":     core.seq,
            "payload": payload_b64,
            "sig":     sig_b64,
        });
        let core_bytes = serde_json::to_vec(&core_json)?;

        let order_id = format!("ORD-{}-{}-{}", core.sender, core.recver, core.seq);
        let parts = self.split_bytes(&core_bytes, order_id.as_bytes());

        let p1 = encode_b64(&parts[0]);
        let p2 = encode_b64(&parts[1]);
        let p3 = encode_b64(&parts[2]);
        let p4 = encode_b64(&parts[3]);

        Ok(json!({
            "operation": "updateOrder",
            "orderId":   order_id,
            "client": {
                "id": core.sender,
                "segment": "retail",
            },
            "items": [
                { "sku": core.recver, "qty": 1 }
            ],
            "meta": {
                "p1": p1,
                "p2": p2,
                "p3": p3,
                "p4": p4,
            }
        }))
    }

    fn wrap_pull(&self, core: &CorePull) -> Result<Value> {
        let sig_b64 = encode_b64(&core.sig);
        Ok(json!({
            "operation": "syncOrders",
            "clientId":  core.sender,
            "partnerId": core.recver,
            "cursor":    core.after_seq,
            "auth":      sig_b64,
        }))
    }

    fn wrap_determinate(&self, core: &CoreDeterminate) -> Result<Value> {
        let sig_b64 = encode_b64(&core.sig);
        Ok(json!({
            "operation": "cleanupHistory",
            "clientId":  core.sender,
            "partnerId": core.recver,
            "cutoff":    core.cut_seq,
            "auth":      sig_b64,
        }))
    }

    fn unwrap_pull_response(&self, body: &Value) -> Result<Vec<RawPacket>> {
        if !body["ok"].as_bool().unwrap_or(false) {
            return Err(anyhow!("Pull failed: {}", body));
        }
        let orders = body["orders"]
            .as_array()
            .ok_or_else(|| anyhow!("Pull: expected 'orders' array"))?;

        let mut packets = Vec::new();
        for item in orders {
            let seq = item["id"]
                .as_u64()
                .ok_or_else(|| anyhow!("Missing id in order"))?;
            let payload_b64 = item["blob"]
                .as_str()
                .ok_or_else(|| anyhow!("Missing blob in order"))?;
            let payload = decode_b64(payload_b64)?;
            packets.push(RawPacket { seq, payload });
        }
        Ok(packets)
    }

    fn unwrap_push_response(&self, body: &Value) -> Result<()> {
        if !body["ok"].as_bool().unwrap_or(false) {
            let msg = body["message"].as_str().unwrap_or("unknown error");
            let lower = msg.to_ascii_lowercase();
            if lower.contains("duplicate seq") || lower.contains("duplicate_seq") {
                return Err(anyhow!("duplicate_seq"));
            }
            if lower.contains("invalid seq")
                || lower.contains("invalid_seq")
                || lower.contains("expected seq")
            {
                return Err(anyhow!("invalid_seq"));
            }
            return Err(anyhow!("Push failed: {msg}"));
        }
        Ok(())
    }

    fn unwrap_determinate_response(&self, body: &Value) -> Result<()> {
        if !body["ok"].as_bool().unwrap_or(false) {
            return Err(anyhow!("Determinate failed: {}", body));
        }
        Ok(())
    }
}
