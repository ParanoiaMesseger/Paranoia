//! Генератор случайных правдоподобных схем маскировки (`SchemaVariant`).
//!
//! Только для панели — за фичей `schema-gen`, чтобы зависимость `fake` не
//! попадала в клиент/сервер. Даёт пользователю «бросить кости»: получить
//! случайную схему под случайный архетип прикрытия и доработать её вручную.

use fake::Fake;
use fake::faker::company::en::CompanyName;
use fake::faker::lorem::en::Word;
use fake::faker::name::en::Name;
use rand::Rng;
use serde_json::{Value, json};

fn rand_hex(rng: &mut impl Rng, n: usize) -> String {
    const HEX: &[u8] = b"0123456789abcdef";
    (0..n).map(|_| HEX[rng.gen_range(0..16)] as char).collect()
}

/// Случайный правдоподобный путь фейкового эндпоинта (таргет вида трафика),
/// напр. `/api/v2/sync`, `/gw/events/ingest`, `/o/items`.
pub fn generate_random_path() -> String {
    let mut rng = rand::thread_rng();
    const PREFIXES: &[&str] = &[
        "/api", "/api/v1", "/api/v2", "/v1", "/v2", "/gw", "/svc", "/o", "/cdn", "/edge", "/rpc", "/data",
    ];
    const SEGS: &[&str] = &[
        "sync", "events", "track", "collect", "ingest", "notify", "push", "pull", "feed", "items",
        "data", "ping", "beacon", "metrics", "log", "upload", "fetch", "state", "poll", "queue",
        "session", "report", "batch", "stream", "tx",
    ];
    let pre = PREFIXES[rng.gen_range(0..PREFIXES.len())];
    let w1 = SEGS[rng.gen_range(0..SEGS.len())];
    if rng.gen_bool(0.4) {
        let w2 = SEGS[rng.gen_range(0..SEGS.len())];
        format!("{pre}/{w1}/{w2}")
    } else {
        format!("{pre}/{w1}")
    }
}

/// Случайная схема (`SchemaVariant`) под один из архетипов прикрытия.
/// Поля-носители (carriers) — строковые, движок перезаписывает их значения.
pub fn generate_random_schema() -> Value {
    let mut rng = rand::thread_rng();
    let ts: u64 = 1_700_000_000 + rng.gen_range(0..40_000_000u64);

    match rng.gen_range(0..5) {
        0 => {
            // Заказ интернет-магазина.
            let name: String = Name().fake();
            json!({
                "template": {
                    "event": "order.created",
                    "order_id": format!("ord_{}", rand_hex(&mut rng, 16)),
                    "ts": ts,
                    "customer": { "id": "", "name": name },
                    "items": [ { "sku": "", "qty": rng.gen_range(1..5), "price": rng.gen_range(100..9999) } ],
                    "signature": ""
                },
                "carriers": ["customer.id", "items.0.sku", "signature"],
                "optional": [ { "path": "coupon", "value": "SUMMER25" } ]
            })
        }
        1 => {
            // Событие телеметрии/аналитики.
            let app: String = CompanyName().fake();
            let evt: String = Word().fake();
            json!({
                "template": {
                    "type": "telemetry",
                    "app": app,
                    "session_id": "",
                    "ts": ts,
                    "events": [ { "name": evt, "trace": "", "attrs": { "id": "" } } ]
                },
                "carriers": ["session_id", "events.0.trace", "events.0.attrs.id"],
                "optional": [ { "path": "sdk_version", "value": "3.2.1" } ]
            })
        }
        2 => {
            // Синхронизация заметок.
            let title: String = Word().fake();
            json!({
                "template": {
                    "op": "sync",
                    "device": format!("dev-{}", rand_hex(&mut rng, 8)),
                    "cursor": "",
                    "notes": [ { "id": "", "etag": "", "title": title, "updated_at": ts } ]
                },
                "carriers": ["cursor", "notes.0.id", "notes.0.etag"],
                "optional": [ { "path": "full_sync", "value": false } ]
            })
        }
        3 => {
            // Push-уведомление.
            json!({
                "template": {
                    "to": "",
                    "collapse_key": format!("ck_{}", rand_hex(&mut rng, 6)),
                    "priority": "high",
                    "data": { "token": "", "payload": "" }
                },
                "carriers": ["to", "data.token", "data.payload"],
                "optional": [ { "path": "ttl", "value": 3600 } ]
            })
        }
        _ => {
            // Универсальный API-ответ.
            json!({
                "template": {
                    "status": "ok",
                    "request_id": format!("req_{}", rand_hex(&mut rng, 12)),
                    "ts": ts,
                    "data": { "hash": "", "blob": "" }
                },
                "carriers": ["data.hash", "data.blob"],
                "optional": [ { "path": "cached", "value": true } ]
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generates_valid_schema_variants() {
        for _ in 0..50 {
            let v = generate_random_schema();
            let o = v.as_object().expect("schema is object");
            assert!(o.contains_key("template"), "has template");
            let carriers = o.get("carriers").and_then(|c| c.as_array()).expect("carriers array");
            assert!(!carriers.is_empty(), "carriers non-empty");
            for c in carriers {
                assert!(c.as_str().map(|s| !s.is_empty()).unwrap_or(false), "carrier is non-empty string");
            }
            // Сгенерированная схема должна парситься ядром как SchemaVariant.
            let _: crate::SchemaVariant =
                serde_json::from_value(v).expect("parses as SchemaVariant");
        }
    }
}
