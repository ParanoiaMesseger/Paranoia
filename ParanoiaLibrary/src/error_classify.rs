fn contains_any(value: &str, patterns: &[&str]) -> bool {
    patterns.iter().any(|pattern| value.contains(pattern))
}

fn classify_by_table(err: &str, table: &[(&[&str], &str)], fallback: &str) -> String {
    let lower = err.to_ascii_lowercase();
    table
        .iter()
        .find(|(patterns, _)| contains_any(&lower, patterns))
        .map_or_else(|| fallback.to_string(), |(_, code)| (*code).to_string())
}

/// Классифицировать ошибку отправки в строку для paranoia_last_error().
pub(crate) fn classify_send_error(err: &str) -> String {
    const SEND_PATTERNS: &[(&[&str], &str)] = &[
        (&["duplicate seq", "duplicate_seq"], "duplicate_seq"),
        (
            &["invalid seq", "invalid_seq", "expected seq"],
            "invalid_seq",
        ),
        (&["file_read_error"], "file_read_error"),
        (&["file_too_large"], "file_too_large"),
    ];

    let classified = classify_by_table(err, SEND_PATTERNS, "");
    if classified.is_empty() {
        classify_network_error(err, "send_error")
    } else {
        classified
    }
}

pub(crate) fn classify_network_error(err: &str, fallback: &str) -> String {
    const NETWORK_PATTERNS: &[(&[&str], &str)] = &[
        (
            &[
                "certificate",
                "tls",
                "rustls",
                "unknown issuer",
                "certificate verify failed",
                "invalid peer certificate",
                "hostname mismatch",
                "platform-verifier",
                "native verifier",
                "trust manager",
                "sectrust",
                "trust evaluation",
                "trustevaluation",
                "certificate is not trusted",
                "not valid for name",
                "certificate expired",
                "certificate has expired",
                "revocation",
                "errsec",
                "classnotfound",
                "noclassdeffound",
                "expect rustls-platform-verifier to be initialized",
            ],
            "tls_error",
        ),
        (
            &[
                "dns",
                "failed to lookup",
                "name or service not known",
                "no such host",
                "temporary failure in name resolution",
            ],
            "dns_error",
        ),
        (
            &[
                "push failed",
                "pull failed",
                "arrived failed",
                "arrived set failed",
                "determinate failed",
                "reg failed",
            ],
            "server_rejected",
        ),
        (
            &[
                "status code",
                "http status",
                "response status",
                "decode",
                "invalid type",
                "expected value",
                "json",
            ],
            "http_error",
        ),
        (
            &[
                "connection",
                "connect",
                "timeout",
                "error sending request",
                "refused",
            ],
            "server_unavailable",
        ),
    ];

    classify_by_table(err, NETWORK_PATTERNS, fallback)
}

pub(crate) fn classify_exchange_error(err: &str) -> String {
    const EXCHANGE_PATTERNS: &[(&[&str], &str)] = &[
        (&["expired"], "exchange_expired"),
        (
            &["fingerprint_mismatch", "fingerprint mismatch"],
            "fingerprint_mismatch",
        ),
        (&["already used"], "exchange_id_reused"),
        (&["mismatch"], "participant_mismatch"),
        (&["payload json", "payload"], "invalid_exchange_payload"),
        (&["state json", "state"], "invalid_exchange_state"),
    ];

    classify_by_table(err, EXCHANGE_PATTERNS, "qr_exchange_error")
}

pub(crate) fn classify_keyring_error(err: &str) -> String {
    const KEYRING_PATTERNS: &[(&[&str], &str)] = &[
        (&["duplicate"], "invalid_keyring_duplicate_start_seq"),
        (&["start_seq"], "invalid_keyring_start_seq"),
        (&["length"], "invalid_keyring_key_length"),
    ];

    classify_by_table(err, KEYRING_PATTERNS, "invalid_keyring")
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── classify_send_error ──────────────────────────────────────────────────

    #[test]
    fn duplicate_seq_is_classified() {
        assert_eq!(classify_send_error("Duplicate seq 42"), "duplicate_seq");
        assert_eq!(
            classify_send_error("Push failed: Duplicate seq 1"),
            "duplicate_seq"
        );
        assert_eq!(classify_send_error("error: duplicate_seq"), "duplicate_seq");
    }

    #[test]
    fn invalid_seq_is_classified() {
        assert_eq!(classify_send_error("Invalid seq 42"), "invalid_seq");
        assert_eq!(
            classify_send_error("Push failed: expected seq 7"),
            "invalid_seq"
        );
        assert_eq!(classify_send_error("error: invalid_seq"), "invalid_seq");
    }

    #[test]
    fn duplicate_seq_does_not_leak_server_data() {
        // seq number и dialogue ID не должны появляться в результате
        let raw = "Push failed: Duplicate seq 99 for dialogue:deadbeefcafe0000";
        let classified = classify_send_error(raw);
        assert_eq!(classified, "duplicate_seq");
        assert!(!classified.contains("99"));
        assert!(!classified.contains("deadbeef"));
        assert!(!classified.contains("dialogue"));
    }

    #[test]
    fn network_error_classified_as_server_unavailable() {
        assert_eq!(
            classify_network_error("connection refused", "fallback"),
            "server_unavailable"
        );
        assert_eq!(
            classify_network_error("connect error: refused", "fallback"),
            "server_unavailable"
        );
        assert_eq!(
            classify_network_error("request timeout after 30s", "fallback"),
            "server_unavailable"
        );
    }

    #[test]
    fn network_error_strips_server_url() {
        // URL сервера не должен попасть в результат
        let raw = "connection refused to http://secret.internal.server.example.com:8443/push";
        let classified = classify_network_error(raw, "send_error");
        assert_eq!(classified, "server_unavailable");
        assert!(!classified.contains("secret.internal"));
        assert!(!classified.contains("example.com"));
        assert!(!classified.contains("http://"));
        assert!(!classified.contains("8443"));
    }

    #[test]
    fn send_error_strips_raw_server_response() {
        // Сырой ответ сервера (payload, приватные данные) не должен попасть в результат
        let raw = "Push failed: internal state dump: private_key=abc123 payload_b64=XXXYYY==";
        let classified = classify_send_error(raw);
        assert_eq!(classified, "server_rejected");
        assert!(!classified.contains("private_key"));
        assert!(!classified.contains("abc123"));
        assert!(!classified.contains("payload_b64"));
        assert!(!classified.contains("XXXYYY"));
    }

    #[test]
    fn receive_error_strips_raw_server_response() {
        let raw =
            "Pull failed: {\"ok\":false,\"error\":\"internal: db_path=/var/data/users/bob.db\"}";
        let classified = classify_network_error(raw, "receive_error");
        assert_eq!(classified, "server_rejected");
        assert!(!classified.contains("db_path"));
        assert!(!classified.contains("/var/data"));
        assert!(!classified.contains("bob.db"));
    }

    #[test]
    fn tls_error_is_classified_without_raw_details() {
        let raw = "invalid peer certificate: UnknownIssuer for https://secret.internal";
        let classified = classify_network_error(raw, "receive_error");
        assert_eq!(classified, "tls_error");
        assert!(!classified.contains("secret.internal"));
        assert!(!classified.contains("https://"));
    }

    #[test]
    fn android_native_verifier_errors_are_tls_errors() {
        let raw = "error sending request for url: invalid peer certificate: failed to call native verifier: java.lang.ClassNotFoundException";
        assert_eq!(classify_network_error(raw, "receive_error"), "tls_error");
    }

    #[test]
    fn apple_trust_errors_are_tls_errors() {
        assert_eq!(
            classify_network_error(
                "SecTrust evaluation failed with errSecCertificateExpired",
                "receive_error"
            ),
            "tls_error"
        );
        assert_eq!(
            classify_network_error(
                "certificate is not trusted by the platform verifier",
                "send_error"
            ),
            "tls_error"
        );
    }

    #[test]
    fn dns_error_is_classified_without_host_details() {
        let raw = "dns error: failed to lookup address information: no such host api.secret.local";
        let classified = classify_network_error(raw, "receive_error");
        assert_eq!(classified, "dns_error");
        assert!(!classified.contains("api.secret.local"));
    }

    #[test]
    fn http_error_is_classified_without_raw_payload() {
        let raw = "error decoding response body: invalid type: map, expected sequence at line 1";
        let classified = classify_network_error(raw, "receive_error");
        assert_eq!(classified, "http_error");
        assert!(!classified.contains("invalid type"));
    }

    #[test]
    fn unknown_error_uses_fallback_without_raw_message() {
        let raw = "some unknown internal error with sensitive_token=s3cr3t";
        let classified = classify_send_error(raw);
        assert_eq!(classified, "send_error");
        assert!(!classified.contains("sensitive_token"));
        assert!(!classified.contains("s3cr3t"));
    }

    #[test]
    fn reqwest_error_sending_request_is_server_unavailable() {
        // reqwest 0.13 возвращает "error sending request for url (...)" при сбое транспорта
        let raw = "error sending request for url (http://secret.internal.server:9000/push)";
        let classified = classify_network_error(raw, "send_error");
        assert_eq!(classified, "server_unavailable");
        // URL не должен утечь
        assert!(!classified.contains("secret.internal"));
        assert!(!classified.contains("9000"));
        assert!(!classified.contains("http://"));
    }

    #[test]
    fn exchange_errors_are_classified_without_raw_payload() {
        assert_eq!(
            classify_exchange_error("exchange payload expired"),
            "exchange_expired"
        );
        assert_eq!(
            classify_exchange_error("responder_id mismatch: bob vs mallory"),
            "participant_mismatch"
        );
        assert_eq!(
            classify_exchange_error("invalid exchange payload json: {private_key=abc}"),
            "invalid_exchange_payload"
        );

        let classified =
            classify_exchange_error("invalid exchange payload json: private_key=abc123");
        assert_eq!(classified, "invalid_exchange_payload");
        assert!(!classified.contains("private_key"));
        assert!(!classified.contains("abc123"));
    }

    #[test]
    fn keyring_errors_are_classified_without_raw_key_material() {
        assert_eq!(
            classify_keyring_error("invalid keyring start_seq 0"),
            "invalid_keyring_start_seq"
        );
        assert_eq!(
            classify_keyring_error("invalid keyring key length: secret_b64=abc"),
            "invalid_keyring_key_length"
        );
        assert_eq!(
            classify_keyring_error("duplicate keyring start_seq"),
            "invalid_keyring_duplicate_start_seq"
        );

        let classified = classify_keyring_error("raw keyring [{\"key\":\"SECRET\"}]");
        assert_eq!(classified, "invalid_keyring");
        assert!(!classified.contains("SECRET"));
        assert!(!classified.contains("keyring ["));
    }
}
