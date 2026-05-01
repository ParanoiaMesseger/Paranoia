// paranoia_lib.h
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ParanoiaHandle ParanoiaHandle;

// ── Клиент ────────────────────────────────────────────────────────────────────
ParanoiaHandle *paranoia_client_new(const char *server_url, const char *username,
                                    const char *signing_key_b64, const char *db_path);
void paranoia_client_free(ParanoiaHandle *handle);

// ── Admin ─────────────────────────────────────────────────────────────────────
void paranoia_generate_keypair(char **out_secret, char **out_pubkey);

// ── Регистрация ───────────────────────────────────────────────────────────────
int paranoia_register_user(const char *server_url, const char *username,
                           const char *user_pubkey_b64, const char *secret_b64);

// ── Сообщения ─────────────────────────────────────────────────────────────────
// Возвращает 0 при успехе, -1 при ошибке (см. paranoia_last_error).
int paranoia_send_text(ParanoiaHandle *handle, const char *user_a, const char *user_b,
                       const uint8_t *session_key, const char *text);

// Возвращает JSON-массив с отправленным сообщением или NULL при ошибке.
char *paranoia_send_text_json(ParanoiaHandle *handle, const char *user_a, const char *user_b,
                              const uint8_t *session_key, const char *text);

// Keyring variants используют JSON:
//   [{"start_seq":1,"key":"base64-32-bytes"}, ...]
// Ключ выбирается локально по максимальному start_seq <= server_seq.
char *paranoia_send_text_json_keyring(ParanoiaHandle *handle, const char *user_a,
                                      const char *user_b, const char *keyring_json,
                                      const char *text);

// Получить новые сообщения с сервера.
// Возвращает JSON-массив или NULL при сетевой ошибке.
// Пустой массив [] — нет новых сообщений.
// При ошибках расшифровки возвращает доступные сообщения, но устанавливает
// paranoia_last_error() в "decryption_failed:<N>".
char *paranoia_receive(ParanoiaHandle *handle, const char *user_a, const char *user_b,
                       const uint8_t *session_key);

char *paranoia_receive_keyring(ParanoiaHandle *handle, const char *user_a,
                               const char *user_b, const char *keyring_json);

// Локальная история из SQLite.
char *paranoia_history(ParanoiaHandle *handle, const char *user_a, const char *user_b,
                       const uint8_t *session_key, uintptr_t limit);

char *paranoia_history_keyring(ParanoiaHandle *handle, const char *user_a,
                               const char *user_b, const char *keyring_json,
                               uintptr_t limit);

// ── Управление историей ───────────────────────────────────────────────────────
// Удалить серверную историю диалога до cut_seq включительно (determinate).
// Возвращает 0 при успехе, -1 при ошибке.
int paranoia_determinate(ParanoiaHandle *handle, const char *user_a, const char *user_b,
                         const uint8_t *session_key, uint64_t cut_seq);

int paranoia_determinate_keyring(ParanoiaHandle *handle, const char *user_a,
                                 const char *user_b, const char *keyring_json,
                                 uint64_t cut_seq);

// Последний локально синхронизированный server seq для выбора start_seq нового ключа.
int paranoia_last_pulled_seq(ParanoiaHandle *handle, const char *user_a,
                             const char *user_b, uint64_t *out_seq);

// Удалить локальные данные диалога из SQLite (сообщения, состояние seq).
// Возвращает 0 при успехе, -1 при ошибке.
int paranoia_delete_local_dialogue(ParanoiaHandle *handle, const char *user_a,
                                   const char *user_b);

// ── QR/JSON out-of-band обмен ключом ─────────────────────────────────────────
// Все функции возвращают NULL при ошибке (см. paranoia_last_error).
// Возвращённые строки освобождать через paranoia_free_string.

// Создать invitation. Возвращает ExchangeBundle JSON со state и payload.
// payload можно передавать собеседнику, state должен оставаться локальным.
char *paranoia_qr_create_invitation(const char *initiator_id, const char *responder_id);

// Создать response на invitation payload JSON. Возвращает ExchangeBundle JSON.
char *paranoia_qr_create_response(const char *invitation_payload_json,
                                  const char *responder_id);

// Получить 6-значный SAS/fingerprint для показа пользователю без выдачи ключа.
char *paranoia_qr_fingerprint(const char *local_state_json, const char *peer_payload_json);

// Подтвердить SAS/fingerprint и вернуть CompletedExchange JSON с session_key_b64.
// Вызывать только после сравнения SAS пользователем по независимому каналу.
char *paranoia_qr_confirm_exchange(const char *local_state_json,
                                   const char *peer_payload_json,
                                   const char *confirmed_fingerprint);

// ── ECIES шифрование экспорта keyring ────────────────────────────────────────
// Используется для шифрованного out-of-band переноса данных на новое устройство.
// Схема: эфемерный X25519 ECDH + HKDF-SHA256 + ChaCha20-Poly1305.
// Отправитель шифрует данные на публичном ключе принимающего устройства.
// Принимающее устройство расшифровывает своим приватным ключом.

// Сгенерировать X25519 device keypair.
// out_privkey, out_pubkey заполняются base64-строками (32 байта каждый).
// Освобождать через paranoia_free_string.
void paranoia_ecies_generate_keypair(char **out_privkey, char **out_pubkey);

// Вывести публичный ключ из base64-приватного ключа.
// Возвращает base64-строку или NULL при ошибке. Освободить через paranoia_free_string.
char *paranoia_ecies_pubkey(const char *privkey_b64);

// Зашифровать строку (JSON payload экспорта) на публичном ключе принимающего.
// receiver_pubkey_b64 — base64 X25519 публичный ключ принимающего устройства.
// plaintext — UTF-8 строка для шифрования.
// Возвращает JSON-конверт EciesEnvelope или NULL при ошибке.
// Освободить через paranoia_free_string.
char *paranoia_ecies_encrypt(const char *receiver_pubkey_b64, const char *plaintext);

// Расшифровать JSON-конверт EciesEnvelope приватным ключом устройства.
// device_privkey_b64 — base64 X25519 приватный ключ устройства.
// envelope_json — JSON-конверт от paranoia_ecies_encrypt.
// Возвращает исходную UTF-8 строку или NULL при ошибке.
// Освободить через paranoia_free_string.
// Ошибки: "ecies_decrypt_error", "ecies_unsupported_version", "invalid_device_key".
char *paranoia_ecies_decrypt(const char *device_privkey_b64, const char *envelope_json);

// ── Ошибки ────────────────────────────────────────────────────────────────────
// Последняя ошибка текущего потока. Указатель действителен до следующего
// FFI-вызова в этом потоке. НЕ освобождать через paranoia_free_string.
// Возможные значения:
//   "duplicate_seq"          — сервер отклонил пакет из-за дублирующегося seq
//   "invalid_seq"            — сервер отклонил пакет из-за устаревшего/неверного seq
//   "server_unavailable"     — сетевая ошибка
//   "decryption_failed:<N>"  — N сообщений не удалось расшифровать (неверный ключ)
//   "exchange_expired"       — QR/JSON payload истёк
//   "fingerprint_mismatch"   — подтверждённый SAS не совпал с рассчитанным
//   "participant_mismatch"   — участники QR/JSON обмена не совпадают
//   "invalid_exchange_payload" — некорректный QR/JSON payload
//   "invalid_exchange_state" — некорректное локальное состояние QR/JSON обмена
//   "invalid_keyring"        — некорректный keyring JSON
//   "invalid_keyring_key_length" — ключ keyring не 32 байта
//   "invalid_keyring_start_seq" — некорректный start_seq keyring
//   "ecies_decrypt_error"    — ошибка расшифровки ECIES (неверный ключ или повреждён файл)
//   "ecies_unsupported_version" — неподдерживаемая версия ECIES конверта
//   "invalid_device_key"     — некорректный device keypair (не 32 байта base64)
//   "send_error:<detail>"    — иная ошибка отправки
//   "receive_error:<detail>" — иная ошибка получения
const char *paranoia_last_error();

// ── Память ────────────────────────────────────────────────────────────────────
void paranoia_free_string(char *s);

#ifdef __cplusplus
}
#endif
