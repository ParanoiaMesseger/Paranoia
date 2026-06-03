//! Движок маскировки: AEAD-конверт, раскладка по полям-носителям, разбор.

use crate::profile::{COVER_KEY_LEN, MaskingProfile, SchemaVariant};
use anyhow::{Result, anyhow, bail};
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce, aead::Aead, aead::KeyInit};
use rand::RngCore;
use serde_json::{Map, Value};

const NONCE_LEN: usize = 12;

pub fn b64_encode(bytes: &[u8]) -> String {
    B64.encode(bytes)
}

pub fn b64_decode(s: &str) -> Result<Vec<u8>> {
    B64.decode(s).map_err(|e| anyhow!("base64: {e}"))
}

/// Замаскировать внутренние байты `inner` под JSON случайно выбранной схемы
/// вида `kind`.
pub fn wrap(
    profile: &MaskingProfile,
    kind: &str,
    inner: &[u8],
    rng: &mut impl RngCore,
) -> Result<Value> {
    let spec = profile
        .kinds
        .get(kind)
        .ok_or_else(|| anyhow!("unknown kind '{kind}'"))?;
    let idx = (rng.next_u32() as usize) % spec.schemas.len();
    let variant = &spec.schemas[idx];
    let sealed = seal(&profile.cover_key()?, inner, rng)?;
    build_packet(variant, &sealed, rng)
}

/// Как [`wrap`], но с системным RNG (`rand::thread_rng`) — чтобы вызывающему
/// (например, серверу) не подключать `rand` напрямую.
pub fn wrap_auto(profile: &MaskingProfile, kind: &str, inner: &[u8]) -> Result<Value> {
    let mut rng = rand::thread_rng();
    wrap(profile, kind, inner, &mut rng)
}

/// Развернуть JSON `body` обратно во внутренние байты. Перебирает все схемы вида
/// `kind`; верную схему подтверждает AEAD-тег.
pub fn unwrap(profile: &MaskingProfile, kind: &str, body: &Value) -> Result<Vec<u8>> {
    let spec = profile
        .kinds
        .get(kind)
        .ok_or_else(|| anyhow!("unknown kind '{kind}'"))?;
    let key = profile.cover_key()?;
    for variant in &spec.schemas {
        if let Some(sealed) = extract(variant, body) {
            if let Ok(plain) = open(&key, &sealed) {
                return Ok(plain);
            }
        }
    }
    bail!("no schema variant matched for kind '{kind}'")
}

/// Построить образец пакета для КОНКРЕТНОГО варианта схемы (для валидации
/// правдоподобия в панели/деве — обычный [`wrap`] выбирает вариант случайно).
pub fn sample_packet(
    profile: &MaskingProfile,
    kind: &str,
    variant_index: usize,
    inner: &[u8],
    rng: &mut impl RngCore,
) -> Result<Value> {
    let spec = profile
        .kinds
        .get(kind)
        .ok_or_else(|| anyhow!("unknown kind '{kind}'"))?;
    let variant = spec
        .schemas
        .get(variant_index)
        .ok_or_else(|| anyhow!("variant index {variant_index} out of range for '{kind}'"))?;
    let sealed = seal(&profile.cover_key()?, inner, rng)?;
    build_packet(variant, &sealed, rng)
}

// ── AEAD-конверт ────────────────────────────────────────────────────────────

fn seal(key: &[u8; COVER_KEY_LEN], plain: &[u8], rng: &mut impl RngCore) -> Result<Vec<u8>> {
    let cipher = ChaCha20Poly1305::new(Key::from_slice(key));
    let mut nonce_bytes = [0u8; NONCE_LEN];
    rng.fill_bytes(&mut nonce_bytes);
    let ciphertext = cipher
        .encrypt(Nonce::from_slice(&nonce_bytes), plain)
        .map_err(|_| anyhow!("cover seal failed"))?;
    let mut out = Vec::with_capacity(NONCE_LEN + ciphertext.len());
    out.extend_from_slice(&nonce_bytes);
    out.extend_from_slice(&ciphertext);
    Ok(out)
}

fn open(key: &[u8; COVER_KEY_LEN], sealed: &[u8]) -> Result<Vec<u8>> {
    if sealed.len() < NONCE_LEN {
        bail!("sealed payload too short");
    }
    let cipher = ChaCha20Poly1305::new(Key::from_slice(key));
    cipher
        .decrypt(Nonce::from_slice(&sealed[..NONCE_LEN]), &sealed[NONCE_LEN..])
        .map_err(|_| anyhow!("cover open failed"))
}

// ── сборка/разбор пакета ────────────────────────────────────────────────────

fn build_packet(variant: &SchemaVariant, sealed: &[u8], rng: &mut impl RngCore) -> Result<Value> {
    let mut out = variant.template.clone();
    let chunks = split(sealed, variant.carriers.len());
    for (path, chunk) in variant.carriers.iter().zip(chunks.iter()) {
        set_path(&mut out, path, Value::String(b64_encode(chunk)))?;
    }
    // Опциональные поля включаются с вероятностью 1/2 — комбинаторный разброс.
    for opt in &variant.optional {
        if rng.next_u32() & 1 == 0 {
            set_path(&mut out, &opt.path, opt.value.clone())?;
        }
    }
    shuffle_object_keys(&mut out, rng);
    Ok(out)
}

fn extract(variant: &SchemaVariant, body: &Value) -> Option<Vec<u8>> {
    let mut sealed = Vec::new();
    for path in &variant.carriers {
        let chunk = b64_decode(get_path(body, path)?.as_str()?).ok()?;
        sealed.extend_from_slice(&chunk);
    }
    Some(sealed)
}

/// Разбить `data` на `n` частей примерно равной длины (порядок = порядок
/// полей-носителей; сборка обратная).
fn split(data: &[u8], n: usize) -> Vec<Vec<u8>> {
    if n == 0 {
        return Vec::new();
    }
    let base = data.len() / n;
    let rem = data.len() % n;
    let mut out = Vec::with_capacity(n);
    let mut pos = 0;
    for i in 0..n {
        let extra = usize::from(i < rem);
        let end = (pos + base + extra).min(data.len());
        out.push(data[pos..end].to_vec());
        pos = end;
    }
    out
}

// ── работа с путями (через точку) ───────────────────────────────────────────

fn get_path<'a>(value: &'a Value, path: &str) -> Option<&'a Value> {
    let mut cur = value;
    for seg in path.split('.') {
        cur = match seg.parse::<usize>() {
            Ok(idx) => cur.get(idx)?,
            Err(_) => cur.get(seg)?,
        };
    }
    Some(cur)
}

fn set_path(value: &mut Value, path: &str, leaf: Value) -> Result<()> {
    let segments: Vec<&str> = path.split('.').collect();
    set_path_rec(value, &segments, leaf)
}

fn set_path_rec(value: &mut Value, segments: &[&str], leaf: Value) -> Result<()> {
    let (head, rest) = segments
        .split_first()
        .ok_or_else(|| anyhow!("empty carrier path"))?;

    if let Ok(idx) = head.parse::<usize>() {
        // Сегмент-индекс: массив должен уже существовать в шаблоне.
        let arr = value
            .as_array_mut()
            .ok_or_else(|| anyhow!("expected array at index segment '{head}'"))?;
        let elem = arr
            .get_mut(idx)
            .ok_or_else(|| anyhow!("array index {idx} out of range"))?;
        if rest.is_empty() {
            *elem = leaf;
            Ok(())
        } else {
            set_path_rec(elem, rest, leaf)
        }
    } else {
        let obj = ensure_object(value);
        if rest.is_empty() {
            obj.insert(head.to_string(), leaf);
            Ok(())
        } else {
            let entry = obj
                .entry(head.to_string())
                .or_insert_with(|| Value::Object(Map::new()));
            set_path_rec(entry, rest, leaf)
        }
    }
}

fn ensure_object(value: &mut Value) -> &mut Map<String, Value> {
    if !value.is_object() {
        *value = Value::Object(Map::new());
    }
    value.as_object_mut().expect("just ensured object")
}

/// Рекурсивно перемешать порядок ключей в объектах (порядок элементов массивов
/// НЕ трогаем — иначе сломались бы индексные пути полей-носителей). Требует
/// serde_json с `preserve_order`.
fn shuffle_object_keys(value: &mut Value, rng: &mut impl RngCore) {
    match value {
        Value::Object(map) => {
            for (_, child) in map.iter_mut() {
                shuffle_object_keys(child, rng);
            }
            let mut entries: Vec<(String, Value)> = std::mem::take(map).into_iter().collect();
            fisher_yates(&mut entries, rng);
            for (key, val) in entries {
                map.insert(key, val);
            }
        }
        Value::Array(arr) => {
            for child in arr.iter_mut() {
                shuffle_object_keys(child, rng);
            }
        }
        _ => {}
    }
}

fn fisher_yates<T>(items: &mut [T], rng: &mut impl RngCore) {
    for i in (1..items.len()).rev() {
        let j = (rng.next_u32() as usize) % (i + 1);
        items.swap(i, j);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::profile::MaskingProfile;
    use rand::SeedableRng;
    use rand::rngs::StdRng;

    fn profile_json() -> String {
        // cover_key = 32 нулевых байта в base64.
        let key = B64.encode([0u8; 32]);
        format!(
            r#"{{
              "name": "test-app",
              "cover_key_b64": "{key}",
              "user_agents": ["UA/1.0"],
              "kinds": {{
                "push": {{
                  "path": "/v2/orders",
                  "method": "PUT",
                  "schemas": [
                    {{
                      "template": {{"op":"order","client":{{"id":"x"}},"items":[{{"sku":"y","note":""}}],"meta":{{"a":"","b":""}}}},
                      "carriers": ["meta.a","meta.b","items.0.note"],
                      "optional": [{{"path":"meta.coupon","value":"SAVE10"}}]
                    }},
                    {{
                      "template": {{"action":"sync","box":{{"p":""}}}},
                      "carriers": ["box.p"]
                    }}
                  ]
                }}
              }}
            }}"#
        )
    }

    #[test]
    fn parses_and_validates() {
        let p = MaskingProfile::from_json(&profile_json()).unwrap();
        assert_eq!(p.name, "test-app");
        assert_eq!(p.kinds["push"].schemas.len(), 2);
    }

    #[test]
    fn wrap_unwrap_roundtrips_for_either_variant() {
        let p = MaskingProfile::from_json(&profile_json()).unwrap();
        let inner = b"the secret inner core bytes \x00\x01\x02";
        // Прогоняем много seed'ов, чтобы задействовать обе схемы-варианта.
        for seed in 0..50u64 {
            let mut rng = StdRng::seed_from_u64(seed);
            let packet = wrap(&p, "push", inner, &mut rng).unwrap();
            let back = unwrap(&p, "push", &packet).unwrap();
            assert_eq!(back, inner, "roundtrip failed for seed {seed}");
        }
    }

    #[test]
    fn wrong_cover_key_fails_to_unwrap() {
        let p = MaskingProfile::from_json(&profile_json()).unwrap();
        let mut rng = StdRng::seed_from_u64(7);
        let packet = wrap(&p, "push", b"data", &mut rng).unwrap();

        // Профиль с другим ключом не развернёт пакет.
        let other_json = profile_json().replace(
            &B64.encode([0u8; 32]),
            &B64.encode([1u8; 32]),
        );
        let other = MaskingProfile::from_json(&other_json).unwrap();
        assert!(unwrap(&other, "push", &packet).is_err());
    }

    #[test]
    fn optional_fields_vary_shape() {
        let p = MaskingProfile::from_json(&profile_json()).unwrap();
        let inner = b"x";
        let mut with_coupon = false;
        let mut without_coupon = false;
        for seed in 0..50u64 {
            let mut rng = StdRng::seed_from_u64(seed);
            let packet = wrap(&p, "push", inner, &mut rng).unwrap();
            // Интересует только вариант со схемой #0 (где есть meta).
            if packet.get("meta").is_some() {
                if get_path(&packet, "meta.coupon").is_some() {
                    with_coupon = true;
                } else {
                    without_coupon = true;
                }
            }
            // Всегда должно разворачиваться независимо от опц. полей.
            assert_eq!(unwrap(&p, "push", &packet).unwrap(), inner);
        }
        assert!(with_coupon && without_coupon, "optional field did not vary");
    }

    #[test]
    fn rejects_too_many_schemas() {
        let key = B64.encode([0u8; 32]);
        let one = r#"{"template":{"a":""},"carriers":["a"]}"#;
        let schemas = std::iter::repeat(one).take(11).collect::<Vec<_>>().join(",");
        let json = format!(
            r#"{{"name":"x","cover_key_b64":"{key}","kinds":{{"push":{{"path":"/p","schemas":[{schemas}]}}}}}}"#
        );
        assert!(MaskingProfile::from_json(&json).is_err());
    }

    #[test]
    fn carrier_in_array_element_survives_key_shuffle() {
        let p = MaskingProfile::from_json(&profile_json()).unwrap();
        // Форсируем схему #0 (carrier в items.0.note) и проверяем целостность.
        for seed in 0..30u64 {
            let mut rng = StdRng::seed_from_u64(seed);
            let packet = wrap(&p, "push", b"payload-in-array", &mut rng).unwrap();
            assert_eq!(unwrap(&p, "push", &packet).unwrap(), b"payload-in-array");
        }
    }
}
