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

// Получить новые сообщения с сервера.
// Возвращает JSON-массив или NULL при сетевой ошибке.
// Пустой массив [] — нет новых сообщений.
// При ошибках расшифровки возвращает доступные сообщения, но устанавливает
// paranoia_last_error() в "decryption_failed:<N>".
char *paranoia_receive(ParanoiaHandle *handle, const char *user_a, const char *user_b,
                       const uint8_t *session_key);

// Локальная история из SQLite.
char *paranoia_history(ParanoiaHandle *handle, const char *user_a, const char *user_b,
                       const uint8_t *session_key, uintptr_t limit);

// ── Управление историей ───────────────────────────────────────────────────────
// Удалить серверную историю диалога до cut_seq включительно (determinate).
// Возвращает 0 при успехе, -1 при ошибке.
int paranoia_determinate(ParanoiaHandle *handle, const char *user_a, const char *user_b,
                         const uint8_t *session_key, uint64_t cut_seq);

// Удалить локальные данные диалога из SQLite (сообщения, состояние seq).
// Возвращает 0 при успехе, -1 при ошибке.
int paranoia_delete_local_dialogue(ParanoiaHandle *handle, const char *user_a,
                                   const char *user_b);

// ── Ошибки ────────────────────────────────────────────────────────────────────
// Последняя ошибка текущего потока. Указатель действителен до следующего
// FFI-вызова в этом потоке. НЕ освобождать через paranoia_free_string.
// Возможные значения:
//   "duplicate_seq"          — сервер отклонил пакет из-за дублирующегося seq
//   "server_unavailable"     — сетевая ошибка
//   "decryption_failed:<N>"  — N сообщений не удалось расшифровать (неверный ключ)
//   "send_error:<detail>"    — иная ошибка отправки
//   "receive_error:<detail>" — иная ошибка получения
const char *paranoia_last_error();

// ── Память ────────────────────────────────────────────────────────────────────
void paranoia_free_string(char *s);

#ifdef __cplusplus
}
#endif
