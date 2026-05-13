// paranoia_lib.h
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ParanoiaHandle ParanoiaHandle;

#define CSTR const char *

#ifdef __ANDROID__
// ── Android TLS
// Инициализировать rustls-platform-verifier вначале. -1 при ошибке (см. paranoia_last_error).
int paranoia_android_init(void *jni_env, void *android_context);
#endif

// ── Клиент
// reserve_server_urls_json: JSON-массив строк с резервными endpoint'ами, например ["https://cdn.example.com"].
// NULL или пустая строка означают отсутствие резервов.
ParanoiaHandle *paranoia_client_new(CSTR server_url, CSTR reserve_server_urls_json, CSTR username,
                                    CSTR signing_key_b64, CSTR db_path);
void paranoia_client_free(ParanoiaHandle *h);

// ── Server ID derivation
// SHA256("paranoia:server-id:v1\n" || ed25519_pubkey_bytes), hex-строка 64 символа.
// Возвращает NULL при ошибке. Освободить через paranoia_free_string.
char *paranoia_derive_server_id(CSTR signing_key_b64);

// ── Admin
void paranoia_generate_keypair(char **out_secret, char **out_pubkey);

// ── Регистрация
int paranoia_register_user(CSTR server_url, CSTR reserve_server_urls_json, CSTR username, CSTR user_pubkey_b64,
                           CSTR secret_b64);

// ── Сообщения
// Keyring API
// использует JSON: [{"start_seq":1,"key":"base64-32-bytes"}, ...]
// Ключ выбирается локально по максимальному start_seq <= server_seq.
char *paranoia_send_text_json_keyring(ParanoiaHandle *h, CSTR user_a, CSTR user_b, CSTR keyring_json, CSTR text);

char *paranoia_send_file_json_keyring(ParanoiaHandle *h, CSTR user_a, CSTR user_b, CSTR keyring_json, CSTR file_path,
                                      CSTR mime_type);

// Получить новые сообщения с сервера.
// Возвращает JSON-массив или NULL при сетевой ошибке.
// Пустой массив [] — нет новых сообщений.
// При ошибках расшифровки возвращает доступные сообщения, но устанавливает
// paranoia_last_error() в "decryption_failed:<N>".
char *paranoia_receive_keyring(ParanoiaHandle *h, CSTR user_a, CSTR user_b, CSTR keyring_json);

// Проверить количество новых сообщений без загрузки payload.
// Возвращает 0 при успехе и пишет результат в out_count.
int paranoia_notify_count_keyring(ParanoiaHandle *h, CSTR user_a, CSTR user_b, CSTR keyring_json, uint64_t *out_count);

// Локальная история из SQLite.
char *paranoia_history_keyring(ParanoiaHandle *h, CSTR user_a, CSTR user_b, CSTR keyring_json, uintptr_t limit);

// Сохранить вложение. Если тело файла ещё не загружено, скачивает нужный
// диапазон body-пакетов через bounded pull и затем пишет target_path.
int paranoia_save_attachment_keyring(ParanoiaHandle *h, CSTR user_a, CSTR user_b, CSTR keyring_json, CSTR message_id,
                                     CSTR target_path);

// Сохранить вложение во внутренний cache приложения и вернуть локальный путь.
char *paranoia_cache_attachment_keyring(ParanoiaHandle *h, CSTR user_a, CSTR user_b, CSTR keyring_json,
                                        CSTR message_id);

// ── Управление историей
// ─────────────────────────────────────────────────────── Удалить серверную
// историю диалога до cut_seq включительно (determinate). Возвращает 0 при
// успехе, -1 при ошибке.
int paranoia_determinate_keyring(ParanoiaHandle *h, CSTR user_a, CSTR user_b, CSTR keyring_json, uint64_t cut_seq);

// Удалить локальные сообщения диалога до cut_seq включительно.
int paranoia_delete_local_until_keyring(ParanoiaHandle *h, CSTR user_a, CSTR user_b, CSTR keyring_json,
                                        uint64_t cut_seq);

// Последний локально синхронизированный server seq для выбора start_seq нового
// ключа.
int paranoia_last_pulled_seq(ParanoiaHandle *h, CSTR user_a, CSTR user_b, uint64_t *out_seq);

// Удалить локальные данные диалога из SQLite (сообщения, состояние seq).
// Возвращает 0 при успехе, -1 при ошибке.
int paranoia_delete_local_dialogue(ParanoiaHandle *h, CSTR user_a, CSTR user_b);

// ── QR/JSON out-of-band обмен ключом ─────────────────────────────────────────
// Все функции возвращают NULL при ошибке (см. paranoia_last_error).
// Возвращённые строки освобождать через paranoia_free_string.

// Создать invitation. Возвращает ExchangeBundle JSON со state и payload.
// payload можно передавать собеседнику, state должен оставаться локальным.
char *paranoia_qr_create_invitation(CSTR initiator_id);

// Создать response на invitation payload JSON. Возвращает ExchangeBundle JSON.
char *paranoia_qr_create_response(CSTR invitation_payload_json, CSTR responder_id);

// Получить 6-значный SAS/fingerprint для показа пользователю без выдачи ключа.
char *paranoia_qr_fingerprint(CSTR local_state_json, CSTR peer_payload_json);

// Подтвердить SAS/fingerprint и вернуть CompletedExchange JSON с
// session_key_b64. Вызывать только после сравнения SAS пользователем по
// независимому каналу.
char *paranoia_qr_confirm_exchange(CSTR local_state_json, CSTR peer_payload_json, CSTR confirmed_fingerprint);

// ── ECIES шифрование экспорта keyring ────────────────────────────────────────
// Используется для шифрованного out-of-band переноса данных на новое
// устройство. Схема: эфемерный X25519 ECDH + HKDF-SHA256 + ChaCha20-Poly1305.
// Отправитель шифрует данные на публичном ключе принимающего устройства.
// Принимающее устройство расшифровывает своим приватным ключом.

// Сгенерировать X25519 device keypair.
// out_private_key, out_pubkey заполняются base64-строками (32 байта каждый).
// Освобождать через paranoia_free_string.
void paranoia_ecies_generate_keypair(char **out_private_key, char **out_pubkey);

// Вывести публичный ключ из base64-приватного ключа.
// Возвращает base64-строку или NULL при ошибке. Освободить через
// paranoia_free_string.
char *paranoia_ecies_pubkey(CSTR private_key_b64);

// Зашифровать строку (JSON payload экспорта) на публичном ключе принимающего.
// receiver_pubkey_b64 — base64 X25519 публичный ключ принимающего устройства.
// plaintext — UTF-8 строка для шифрования.
// Возвращает JSON-конверт EciesEnvelope или NULL при ошибке.
// Освободить через paranoia_free_string.
char *paranoia_ecies_encrypt(CSTR receiver_pubkey_b64, CSTR plaintext);

// Расшифровать JSON-конверт EciesEnvelope приватным ключом устройства.
// device_private_key_b64 — base64 X25519 приватный ключ устройства.
// envelope_json — JSON-конверт от paranoia_ecies_encrypt.
// Возвращает исходную UTF-8 строку или NULL при ошибке.
// Освободить через paranoia_free_string.
// Ошибки: "ecies_decrypt_error", "ecies_unsupported_version",
// "invalid_device_key".
char *paranoia_ecies_decrypt(CSTR device_private_key_b64, CSTR envelope_json);

// ── Ошибки
// ────────────────────────────────────────────────────────────────────
// Последняя ошибка текущего потока. Указатель действителен до следующего
// FFI-вызова в этом потоке. НЕ освобождать через paranoia_free_string.
// Возможные значения:
//   "duplicate_seq"          — сервер отклонил пакет из-за дублирующегося seq
//   "invalid_seq"            — сервер отклонил пакет из-за
//   устаревшего/неверного seq "server_unavailable"     — сетевая ошибка
//   "tls_error"              — ошибка TLS/сертификата
//   "dns_error"              — ошибка DNS/резолва хоста
//   "http_error"             — ошибка HTTP/формата ответа
//   "server_rejected"        — сервер ответил protocol-level ошибкой
//   "decryption_failed:<N>"  — N сообщений не удалось расшифровать (неверный
//   ключ) "exchange_expired"       — QR/JSON payload истёк
//   "fingerprint_mismatch"   — подтверждённый SAS не совпал с рассчитанным
//   "participant_mismatch"   — участники QR/JSON обмена не совпадают
//   "invalid_exchange_payload" — некорректный QR/JSON payload
//   "invalid_exchange_state" — некорректное локальное состояние QR/JSON обмена
//   "invalid_keyring"        — некорректный keyring JSON
//   "invalid_keyring_key_length" — ключ keyring не 32 байта
//   "invalid_keyring_start_seq" — некорректный start_seq keyring
//   "ecies_decrypt_error"    — ошибка расшифровки ECIES (неверный ключ или
//   повреждён файл) "ecies_unsupported_version" — неподдерживаемая версия ECIES
//   конверта "invalid_device_key"     — некорректный device keypair (не 32
//   байта base64) "android_init_error"     — ошибка инициализации Android TLS
//   verifier "send_error" / "receive_error" / "history_error" /
//   "determinate_error" — иная ошибка "send_panic" / "receive_panic" /
//   "history_panic" / "determinate_panic" — panic в Rust FFI
CSTR paranoia_last_error();

// ── Память
// ────────────────────────────────────────────────────────────────────
void paranoia_free_string(char *s);

#ifdef __cplusplus
}
#endif
