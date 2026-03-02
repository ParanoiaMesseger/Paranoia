use crate::crypto::decode_b64;
use crate::routes::{
    determinate::{ApiResponse as DetResp, DeterminateRequest},
    pull::{ApiResponse as PullResp, PullRequest},
    push::{ApiResponse as PushResp, PushRequest},
};
use crate::Cover;
use anyhow::{anyhow, Result};
use serde_json::{json, Value};

/// Базовый маскарад: API "склад/заказы".
pub struct FoodDeliveryCover;

impl FoodDeliveryCover {
    pub fn new() -> Self {
        Self
    }

    fn join_bytes(&self, parts: &[Vec<u8>]) -> Vec<u8> {
        let mut out = Vec::new();
        for p in parts {
            out.extend_from_slice(p);
        }
        out
    }
}

impl Cover for FoodDeliveryCover {
    // ===================== PUSH ======================

    /// Ожидаемый внешний формат /push:
    /// {
    ///   "operation": "updateOrder",
    ///   "orderId": "A1F9-27C3",
    ///   "client": { "id": "alice", "segment": "retail" },
    ///   "items": [ { "sku": "bob", "qty": 1 } ],
    ///   "meta": {
    ///     "p1": "...", "p2": "...", "p3": "...", "p4": "..."
    ///   }
    /// }
    fn unwrap_push(&self, body: &Value) -> Result<PushRequest> {
        let op = body["operation"]
            .as_str()
            .ok_or_else(|| anyhow!("no operation"))?;
        if op != "updateOrder" {
            return Err(anyhow!("unsupported operation"));
        }

        let sender = body["client"]["id"]
            .as_str()
            .ok_or_else(|| anyhow!("no client.id"))?
            .to_string();
        let recver = body["items"][0]["sku"]
            .as_str()
            .ok_or_else(|| anyhow!("no items[0].sku"))?
            .to_string();
        let meta = &body["meta"];

        let p1 = decode_b64(meta["p1"].as_str().ok_or_else(|| anyhow!("no meta.p1"))?)?;
        let p2 = decode_b64(meta["p2"].as_str().ok_or_else(|| anyhow!("no meta.p2"))?)?;
        let p3 = decode_b64(meta["p3"].as_str().ok_or_else(|| anyhow!("no meta.p3"))?)?;
        let p4 = decode_b64(meta["p4"].as_str().ok_or_else(|| anyhow!("no meta.p4"))?)?;

        let buf = self.join_bytes(&[p1, p2, p3, p4]);

        // Для простоты: внутри buf лежит JSON CorePush
        let core_json: Value = serde_json::from_slice(&buf)?;
        let sender_core = core_json["sender"]
            .as_str()
            .ok_or_else(|| anyhow!("no sender"))?;
        let recver_core = core_json["recver"]
            .as_str()
            .ok_or_else(|| anyhow!("no recver"))?;
        if sender_core != sender || recver_core != recver {
            return Err(anyhow!("cover/core mismatch"));
        }

        Ok(PushRequest {
            sender,
            recver,
            seq: core_json["seq"].as_u64().ok_or_else(|| anyhow!("no seq"))?,
            payload: core_json["payload"]
                .as_str()
                .ok_or_else(|| anyhow!("no payload"))?
                .to_string(),
            sig: core_json["sig"]
                .as_str()
                .ok_or_else(|| anyhow!("no sig"))?
                .to_string(),
        })
    }

    fn wrap_push_response(&self, resp: &PushResp) -> Value {
        // Маскируем ответ под "статус обновления заказа"
        json!({
            "ok": resp.success,
            "status": if resp.success { "updated" } else { "error" },
            "message": resp.message,
        })
    }

    // ===================== PULL ======================

    /// Внешний формат /pull:
    /// {
    ///   "operation": "syncOrders",
    ///   "clientId": "alice",
    ///   "partnerId": "bob",
    ///   "cursor": 10,
    ///   "auth": "<sig base64>"
    /// }
    fn unwrap_pull(&self, body: &Value) -> Result<PullRequest> {
        let op = body["operation"]
            .as_str()
            .ok_or_else(|| anyhow!("no operation"))?;
        if op != "syncOrders" {
            return Err(anyhow!("unsupported operation"));
        }

        let sender = body["clientId"]
            .as_str()
            .ok_or_else(|| anyhow!("no clientId"))?
            .to_string();
        let recver = body["partnerId"]
            .as_str()
            .ok_or_else(|| anyhow!("no partnerId"))?
            .to_string();
        let after_seq = body["cursor"]
            .as_u64()
            .ok_or_else(|| anyhow!("no cursor"))?;
        let sig = body["auth"]
            .as_str()
            .ok_or_else(|| anyhow!("no auth"))?
            .to_string();

        Ok(PullRequest {
            sender,
            recver,
            after_seq,
            sig,
        })
    }

    /// Внешний формат ответа /pull:
    /// {
    ///   "ok": true,
    ///   "orders": [
    ///     { "id": 11, "blob": "<payload base64>" },
    ///     ...
    ///   ]
    /// }
    fn wrap_pull_response(&self, resp: &PullResp) -> Value {
        if !resp.success {
            return json!({
                "ok": false,
                "error": resp.message, // тут message — либо строка, либо массив, мы оборачиваем как есть
            });
        }

        let arr = resp.message.as_array().cloned().unwrap_or_default();
        let orders: Vec<Value> = arr
            .into_iter()
            .map(|item| {
                json!({
                    "id": item["seq"],
                    "blob": item["payload"],
                })
            })
            .collect();

        json!({
            "ok": true,
            "orders": orders,
        })
    }

    // ================== DETERMINATE ==================

    /// Внешний формат /determinate:
    /// {
    ///   "operation": "cleanupHistory",
    ///   "clientId": "alice",
    ///   "partnerId": "bob",
    ///   "cutoff": 123,
    ///   "auth": "<sig base64>"
    /// }
    fn unwrap_determinate(&self, body: &Value) -> Result<DeterminateRequest> {
        let op = body["operation"]
            .as_str()
            .ok_or_else(|| anyhow!("no operation"))?;
        if op != "cleanupHistory" {
            return Err(anyhow!("unsupported operation"));
        }

        let sender = body["clientId"]
            .as_str()
            .ok_or_else(|| anyhow!("no clientId"))?
            .to_string();
        let recver = body["partnerId"]
            .as_str()
            .ok_or_else(|| anyhow!("no partnerId"))?
            .to_string();
        let cut_seq = body["cutoff"]
            .as_u64()
            .ok_or_else(|| anyhow!("no cutoff"))?;
        let sig = body["auth"]
            .as_str()
            .ok_or_else(|| anyhow!("no auth"))?
            .to_string();

        Ok(DeterminateRequest {
            sender,
            recver,
            cut_seq,
            sig,
        })
    }

    /// Внешний формат ответа /determinate:
    /// {
    ///   "ok": true,
    ///   "status": "cleaned" | "error",
    ///   "message": "..."
    /// }
    fn wrap_determinate_response(&self, resp: &DetResp) -> Value {
        json!({
            "ok": resp.success,
            "status": if resp.success { "cleaned" } else { "error" },
            "message": resp.message,
        })
    }
}
