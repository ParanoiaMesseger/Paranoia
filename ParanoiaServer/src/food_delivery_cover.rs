use crate::Cover;
use crate::crypto::decode_b64;
use crate::routes::{
    call_poll::{ApiResponse as PollResp, CallEnvelopeOut, CallPollRequest},
    call_signal::{ApiResponse as CallSignalResp, CallSignalRequest},
    determinate::{ApiResponse as DetResp, DeterminateRequest},
    map::{ApiResponse as MapResp, MapRequest},
    notify::{ApiResponse as NotifyResp, NotifyRequest},
    pull::{ApiResponse as PullResp, PullRequest},
    push::{ApiResponse as PushResp, PushRequest},
};
use anyhow::{Result, anyhow};
use serde_json::{Value, json};

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
    ///   "toSeq": 0,
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
        let to_seq = body["toSeq"].as_u64().ok_or_else(|| anyhow!("no toSeq"))?;
        let sig = body["auth"]
            .as_str()
            .ok_or_else(|| anyhow!("no auth"))?
            .to_string();

        Ok(PullRequest {
            sender,
            recver,
            after_seq,
            to_seq,
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

    // ====================== MAP ======================

    /// Внешний формат /map:
    /// {
    ///   "operation": "scanInventory",
    ///   "clientId": "alice",
    ///   "partnerId": "bob",
    ///   "cursor": 0,
    ///   "toSeq": 0,
    ///   "auth": "<sig base64>"
    /// }
    fn unwrap_map(&self, body: &Value) -> Result<MapRequest> {
        let op = body["operation"]
            .as_str()
            .ok_or_else(|| anyhow!("no operation"))?;
        if op != "scanInventory" {
            return Err(anyhow!("unsupported operation"));
        }

        Ok(MapRequest {
            sender: body["clientId"]
                .as_str()
                .ok_or_else(|| anyhow!("no clientId"))?
                .to_string(),
            recver: body["partnerId"]
                .as_str()
                .ok_or_else(|| anyhow!("no partnerId"))?
                .to_string(),
            after_seq: body["cursor"]
                .as_u64()
                .ok_or_else(|| anyhow!("no cursor"))?,
            to_seq: body["toSeq"].as_u64().ok_or_else(|| anyhow!("no toSeq"))?,
            sig: body["auth"]
                .as_str()
                .ok_or_else(|| anyhow!("no auth"))?
                .to_string(),
        })
    }

    /// Внешний формат ответа /map:
    /// {
    ///   "ok": true,
    ///   "shelves": [[5, 1247], [1300, 1342]],
    ///   "topShelf": 1500,
    ///   "more": false
    /// }
    fn wrap_map_response(&self, resp: &MapResp) -> Value {
        if !resp.success {
            return json!({
                "ok": false,
                "status": "error",
                "message": resp.message,
            });
        }
        let shelves: Vec<Value> = resp
            .runs
            .iter()
            .map(|(begin, end)| json!([begin, end]))
            .collect();
        json!({
            "ok": true,
            "shelves": shelves,
            "topShelf": resp.last_seq,
            "more": resp.truncated,
        })
    }

    // ===================== NOTIFY =====================

    /// Внешний формат /notify:
    /// {
    ///   "operation": "checkOrders",
    ///   "clientId": "alice",
    ///   "partnerId": "bob",
    ///   "cursor": 42,
    ///   "auth": "<sig base64>"
    /// }
    fn unwrap_notify(&self, body: &Value) -> Result<NotifyRequest> {
        let op = body["operation"]
            .as_str()
            .ok_or_else(|| anyhow!("no operation"))?;
        if op != "checkOrders" {
            return Err(anyhow!("unsupported operation"));
        }

        let sender = body["clientId"]
            .as_str()
            .ok_or_else(|| anyhow!("no clientId"))?
            .to_string();
        let partner = body["partnerId"]
            .as_str()
            .ok_or_else(|| anyhow!("no partnerId"))?
            .to_string();
        let seq = body["cursor"]
            .as_u64()
            .ok_or_else(|| anyhow!("no cursor"))?;
        let sig = body["auth"]
            .as_str()
            .ok_or_else(|| anyhow!("no auth"))?
            .to_string();

        Ok(NotifyRequest {
            sender,
            partner,
            seq,
            sig,
        })
    }

    /// Внешний формат ответа /notify:
    /// {
    ///   "ok": true,
    ///   "n": 3
    /// }
    fn wrap_notify_response(&self, resp: &NotifyResp) -> Value {
        if !resp.success {
            return json!({
                "ok": false,
                "status": "error",
                "message": resp.message,
            });
        }

        json!({
            "ok": true,
            "n": resp.n,
        })
    }

    // ================== DETERMINATE ==================

    /// Внешний формат /determinate:
    /// {
    ///   "operation": "cleanupHistory",
    ///   "clientId": "alice",
    ///   "partnerId": "bob",
    ///   "fromSeq": 0,
    ///   "toSeq": 123,
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
        let from_seq = body["fromSeq"]
            .as_u64()
            .ok_or_else(|| anyhow!("no fromSeq"))?;
        let to_seq = body["toSeq"]
            .as_u64()
            .ok_or_else(|| anyhow!("no toSeq"))?;
        let sig = body["auth"]
            .as_str()
            .ok_or_else(|| anyhow!("no auth"))?
            .to_string();

        Ok(DeterminateRequest {
            sender,
            recver,
            from_seq,
            to_seq,
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

    // =================== CALL SIGNAL ==================

    /// Внешний формат /call/signal — диспетчер курьеров отправляет инструкцию:
    /// {
    ///   "operation": "dispatchCourier",
    ///   "courierId": "alice",
    ///   "targetId": "bob",
    ///   "stage": 0,
    ///   "issuedAt": 1700000000000,
    ///   "manifest": "<base64 payload>",
    ///   "auth": "<sig base64>"
    /// }
    fn unwrap_call_signal(&self, body: &Value) -> Result<CallSignalRequest> {
        let op = body["operation"]
            .as_str()
            .ok_or_else(|| anyhow!("no operation"))?;
        if op != "dispatchCourier" {
            return Err(anyhow!("unsupported operation"));
        }
        Ok(CallSignalRequest {
            sender: body["courierId"]
                .as_str()
                .ok_or_else(|| anyhow!("no courierId"))?
                .to_string(),
            recver: body["targetId"]
                .as_str()
                .ok_or_else(|| anyhow!("no targetId"))?
                .to_string(),
            kind: u8::try_from(
                body["stage"]
                    .as_u64()
                    .ok_or_else(|| anyhow!("no stage"))?,
            )
            .map_err(|_| anyhow!("stage out of u8 range"))?,
            ts_ms: body["issuedAt"]
                .as_i64()
                .ok_or_else(|| anyhow!("no issuedAt"))?,
            payload: body["manifest"]
                .as_str()
                .ok_or_else(|| anyhow!("no manifest"))?
                .to_string(),
            sig: body["auth"]
                .as_str()
                .ok_or_else(|| anyhow!("no auth"))?
                .to_string(),
        })
    }

    fn wrap_call_signal_response(&self, resp: &CallSignalResp) -> Value {
        json!({
            "ok": resp.success,
            "status": if resp.success { "dispatched" } else { "error" },
            "message": resp.message,
        })
    }

    // ==================== CALL POLL ===================

    /// Внешний формат /call/poll — курьер запрашивает свой список заданий:
    /// {
    ///   "operation": "pollDispatch",
    ///   "courierId": "alice",
    ///   "nonce": 123456,
    ///   "waitMs": 25000,
    ///   "auth": "<sig base64>"
    /// }
    fn unwrap_call_poll(&self, body: &Value) -> Result<CallPollRequest> {
        let op = body["operation"]
            .as_str()
            .ok_or_else(|| anyhow!("no operation"))?;
        if op != "pollDispatch" {
            return Err(anyhow!("unsupported operation"));
        }
        Ok(CallPollRequest {
            user: body["courierId"]
                .as_str()
                .ok_or_else(|| anyhow!("no courierId"))?
                .to_string(),
            nonce: body["nonce"].as_u64().ok_or_else(|| anyhow!("no nonce"))?,
            long_poll_ms: u32::try_from(
                body["waitMs"]
                    .as_u64()
                    .ok_or_else(|| anyhow!("no waitMs"))?,
            )
            .map_err(|_| anyhow!("waitMs out of u32 range"))?,
            sig: body["auth"]
                .as_str()
                .ok_or_else(|| anyhow!("no auth"))?
                .to_string(),
        })
    }

    /// Внешний формат ответа /call/poll:
    /// {
    ///   "ok": true,
    ///   "tasks": [ { "from": "...", "stage": N, "manifest": "<b64>", "issuedAt": ts }, ... ]
    /// }
    fn wrap_call_poll_response(&self, resp: &PollResp) -> Value {
        if !resp.success {
            return json!({
                "ok": false,
                "status": "error",
                "message": resp.message,
            });
        }
        let tasks: Vec<Value> = resp
            .items
            .iter()
            .map(|e: &CallEnvelopeOut| {
                json!({
                    "from": e.sender,
                    "stage": e.kind,
                    "manifest": e.payload,
                    "issuedAt": e.ts_ms,
                })
            })
            .collect();
        json!({
            "ok": true,
            "tasks": tasks,
        })
    }
}
