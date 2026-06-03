//! Валидация правдоподобия профиля по JSON Schema. Только при фиче `validation`
//! (панель/дев) — клиент и сервер собираются без неё.
//!
//! Для каждого варианта схемы, у которого задан `json_schema`, генерируется
//! несколько образцов пакетов (с разным набором опциональных полей) и
//! проверяется их соответствие схеме. Это режим «валидация без применения» из
//! админ-панели — поймать кривой профиль до раздачи пользователям.

use crate::engine;
use crate::profile::MaskingProfile;
use rand::SeedableRng;
use rand::rngs::StdRng;

const SAMPLES_PER_VARIANT: u64 = 8;

/// Провалидировать профиль. Возвращает список проблем (пусто = всё ок).
pub fn validate_profile(profile: &MaskingProfile) -> Vec<String> {
    let mut issues = Vec::new();
    if let Err(e) = profile.validate() {
        issues.push(format!("structure: {e}"));
        return issues;
    }
    let dummy = b"validation-sample-inner-payload";
    for (kind, spec) in &profile.kinds {
        for (i, variant) in spec.schemas.iter().enumerate() {
            let Some(schema) = &variant.json_schema else {
                continue;
            };
            let validator = match jsonschema::validator_for(schema) {
                Ok(v) => v,
                Err(e) => {
                    issues.push(format!("{kind}#{i}: invalid json_schema: {e}"));
                    continue;
                }
            };
            for seed in 0..SAMPLES_PER_VARIANT {
                let mut rng = StdRng::seed_from_u64(seed);
                match engine::sample_packet(profile, kind, i, dummy, &mut rng) {
                    Ok(sample) => {
                        if !validator.is_valid(&sample) {
                            let details: Vec<String> = validator
                                .iter_errors(&sample)
                                .map(|e| e.to_string())
                                .take(3)
                                .collect();
                            issues.push(format!(
                                "{kind}#{i}: sample (seed {seed}) violates json_schema: {}",
                                details.join("; ")
                            ));
                            break; // одного отчёта на вариант достаточно
                        }
                    }
                    Err(e) => issues.push(format!("{kind}#{i}: sample build failed: {e}")),
                }
            }
        }
    }
    issues
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::b64_encode;

    fn profile_with_schema(required: &str) -> MaskingProfile {
        let key = b64_encode(&[0u8; 32]);
        let json = format!(
            r#"{{
              "name": "v",
              "cover_key_b64": "{key}",
              "kinds": {{
                "push": {{
                  "path": "/p",
                  "schemas": [{{
                    "template": {{"d": ""}},
                    "carriers": ["d"],
                    "json_schema": {{"type": "object", "required": ["{required}"]}}
                  }}]
                }}
              }}
            }}"#
        );
        MaskingProfile::from_json(&json).unwrap()
    }

    #[test]
    fn valid_profile_has_no_issues() {
        // Образец всегда содержит поле "d" (carrier) → схема выполняется.
        let issues = validate_profile(&profile_with_schema("d"));
        assert!(issues.is_empty(), "unexpected issues: {issues:?}");
    }

    #[test]
    fn schema_violation_is_reported() {
        // Схема требует несуществующее поле → должно сообщить о нарушении.
        let issues = validate_profile(&profile_with_schema("nonexistent_field"));
        assert!(!issues.is_empty());
        assert!(issues[0].contains("violates json_schema"));
    }
}
