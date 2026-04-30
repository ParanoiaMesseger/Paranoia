// paranoia_lib.h
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ParanoiaHandle ParanoiaHandle;

// --- Клиент ---
ParanoiaHandle *paranoia_client_new(const char *server_url, const char *username, const char *signing_key_b64,
                                    const char *db_path);
void paranoia_client_free(ParanoiaHandle *handle);

// --- Admin ---
void paranoia_generate_keypair(char **out_secret, char **out_pubkey);

// --- Регистрация ---
int paranoia_register_user(const char *server_url, const char *username, const char *user_pubkey_b64,
                           const char *secret_b64);

// --- Сообщения ---
int paranoia_send_text(ParanoiaHandle *handle, const char *user_a, const char *user_b, const uint8_t *session_key,
                       const char *text);

char *paranoia_send_text_json(ParanoiaHandle *handle, const char *user_a, const char *user_b,
                              const uint8_t *session_key, const char *text);

char *paranoia_receive(ParanoiaHandle *handle, const char *user_a, const char *user_b, const uint8_t *session_key);

char *paranoia_history(ParanoiaHandle *handle, const char *user_a, const char *user_b, const uint8_t *session_key,
                       uintptr_t limit);

// --- Память ---
void paranoia_free_string(char *s);

#ifdef __cplusplus
}
#endif
