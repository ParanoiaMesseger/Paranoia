// paranoia_lib.h
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RS_QS RS_QS;
typedef RS_QS ParanoiaHandle;

/// QString to CString
#define QS_RS(str) str.toUtf8().constData()
#define QS_RS2(x, x1) QS_RS(x), QS_RS(x1)
#define QS_RS3(x, x1, x2) QS_RS(x), QS_RS(x1), QS_RS(x2)
#define QS_RS4(x, x1, x2, x3) QS_RS(x), QS_RS(x1), QS_RS(x2), QS_RS(x3)
#ifdef __ANDROID__
// ── Android TLS
// Инициализировать rustls-platform-verifier вначале. -1 при ошибке (см. paranoia_last_error).
int paranoia_android_init(void *jni_env, void *android_context);
#endif

// ── Клиент
RS_QS *paranoia_client_new(const char *server_url, const char *username, const char *signing_key_b64,
                           const char *db_path);
void paranoia_client_free(RS_QS *handle);

// ── Admin
void paranoia_generate_keypair(char **out_secret, char **out_pubkey);

// ── Регистрация
int paranoia_register_user(const char *server_url, const char *username, const char *user_pubkey_b64,
                           const char *secret_b64);

// ── Сообщения
// Keyring API
// использует JSON: [{"start_seq":1,"key":"base64-32-bytes"}, ...]
// Ключ выбирается локально по максимальному start_seq <= server_seq.
char *paranoia_send_text_json_keyring(RS_QS *handle, const char *user_a, const char *user_b, const char *keyring_json,
                                      const char *text);

// Получить новые сообщения с сервера.
// Возвращает JSON-массив или NULL при сетевой ошибке.
// Пустой массив [] — нет новых сообщений.
// При ошибках расшифровки возвращает доступные сообщения, но устанавливает
// paranoia_last_error() в "decryption_failed:<N>".
char *paranoia_receive_keyring(RS_QS *handle, const char *user_a, const char *user_b, const char *keyring_json);

// Локальная история из SQLite.
char *paranoia_history_keyring(RS_QS *handle, const char *user_a, const char *user_b, const char *keyring_json,
                               uintptr_t limit);

// ── Управление историей
// ─────────────────────────────────────────────────────── Удалить серверную
// историю диалога до cut_seq включительно (determinate). Возвращает 0 при
// успехе, -1 при ошибке.
int paranoia_determinate_keyring(RS_QS *handle, const char *user_a, const char *user_b, const char *keyring_json,
                                 uint64_t cut_seq);

// Последний локально синхронизированный server seq для выбора start_seq нового
// ключа.
int paranoia_last_pulled_seq(RS_QS *handle, const char *user_a, const char *user_b, uint64_t *out_seq);

// Удалить локальные данные диалога из SQLite (сообщения, состояние seq).
// Возвращает 0 при успехе, -1 при ошибке.
int paranoia_delete_local_dialogue(RS_QS *handle, const char *user_a, const char *user_b);

// ── QR/JSON out-of-band обмен ключом ─────────────────────────────────────────
// Все функции возвращают NULL при ошибке (см. paranoia_last_error).
// Возвращённые строки освобождать через paranoia_free_string.

// Создать invitation. Возвращает ExchangeBundle JSON со state и payload.
// payload можно передавать собеседнику, state должен оставаться локальным.
char *paranoia_qr_create_invitation(const char *initiator_id, const char *responder_id);

// Создать response на invitation payload JSON. Возвращает ExchangeBundle JSON.
char *paranoia_qr_create_response(const char *invitation_payload_json, const char *responder_id);

// Получить 6-значный SAS/fingerprint для показа пользователю без выдачи ключа.
char *paranoia_qr_fingerprint(const char *local_state_json, const char *peer_payload_json);

// Подтвердить SAS/fingerprint и вернуть CompletedExchange JSON с
// session_key_b64. Вызывать только после сравнения SAS пользователем по
// независимому каналу.
char *paranoia_qr_confirm_exchange(const char *local_state_json, const char *peer_payload_json,
                                   const char *confirmed_fingerprint);

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
char *paranoia_ecies_pubkey(const char *private_key_b64);

// Зашифровать строку (JSON payload экспорта) на публичном ключе принимающего.
// receiver_pubkey_b64 — base64 X25519 публичный ключ принимающего устройства.
// plaintext — UTF-8 строка для шифрования.
// Возвращает JSON-конверт EciesEnvelope или NULL при ошибке.
// Освободить через paranoia_free_string.
char *paranoia_ecies_encrypt(const char *receiver_pubkey_b64, const char *plaintext);

// Расшифровать JSON-конверт EciesEnvelope приватным ключом устройства.
// device_private_key_b64 — base64 X25519 приватный ключ устройства.
// envelope_json — JSON-конверт от paranoia_ecies_encrypt.
// Возвращает исходную UTF-8 строку или NULL при ошибке.
// Освободить через paranoia_free_string.
// Ошибки: "ecies_decrypt_error", "ecies_unsupported_version",
// "invalid_device_key".
char *paranoia_ecies_decrypt(const char *device_private_key_b64, const char *envelope_json);

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
const char *paranoia_last_error();

// ── Память
// ────────────────────────────────────────────────────────────────────
void paranoia_free_string(char *s);

#ifdef __cplusplus
}

#ifdef QSTRING_H

inline QString takeRustString(char *ptr)
{
    QString value = QString::fromUtf8(ptr);
    ::paranoia_free_string(ptr);
    return value;
}

#define RS_QS(ptr) (ptr ? takeRustString(ptr) : QString())

class ParanoiaFFI
{
public:
    using QSTR       = const QString &;
    using PrivateKey = QString;
    using PublicKey  = QString;

    ParanoiaFFI(QSTR server_url, QSTR username, QSTR signing_key_b64, QSTR db_path)
        : ptr(::paranoia_client_new(QS_RS4(server_url, username, signing_key_b64, db_path)))
    {
    }
    bool isRawOk() const { return ptr != nullptr; }
    ParanoiaFFI(const ParanoiaFFI &)            = delete;
    ParanoiaFFI &operator=(const ParanoiaFFI &) = delete;

    QString send_text_json_keyring(QSTR user_a, QSTR user_b, QSTR keyring_json, QSTR text)
    { return RS_QS(::paranoia_send_text_json_keyring(ptr, QS_RS4(user_a, user_b, keyring_json, text))); }

    QString receive_keyring(QSTR user_a, QSTR user_b, QSTR keyring_json)
    { return RS_QS(::paranoia_receive_keyring(ptr, QS_RS3(user_a, user_b, keyring_json))); }

    QString history_keyring(QSTR user_a, QSTR user_b, QSTR keyring_json, uintptr_t limit)
    { return RS_QS(::paranoia_history_keyring(ptr, QS_RS(user_a), QS_RS(user_b), QS_RS(keyring_json), limit)); }

    int determinate_keyring(QSTR user_a, QSTR user_b, QSTR keyring_json, uint64_t cut_seq)
    { return ::paranoia_determinate_keyring(ptr, QS_RS(user_a), QS_RS(user_b), QS_RS(keyring_json), cut_seq); }

    int last_pulled_seq(QSTR user_a, QSTR user_b, uint64_t &out_seq)
    { return ::paranoia_last_pulled_seq(ptr, QS_RS(user_a), QS_RS(user_b), &out_seq); }

    int delete_local_dialogue(QSTR user_a, QSTR user_b)
    { return ::paranoia_delete_local_dialogue(ptr, QS_RS2(user_a, user_b)); }

    ~ParanoiaFFI() { ::paranoia_client_free(ptr); }

    static int register_user(QSTR server_url, QSTR username, QSTR user_pubkey_b64, QSTR secret_b64)
    { return ::paranoia_register_user(QS_RS4(server_url, username, user_pubkey_b64, secret_b64)); }

    static QString qr_create_invitation(QSTR initiator_id, QSTR responder_id)
    { return RS_QS(::paranoia_qr_create_invitation(QS_RS2(initiator_id, responder_id))); }

    static QString qr_create_response(QSTR invitation_payload_json, QSTR responder_id)
    { return RS_QS(::paranoia_qr_create_response(QS_RS2(invitation_payload_json, responder_id))); }

    static QString qr_fingerprint(QSTR local_state_json, QSTR peer_payload_json)
    { return RS_QS(::paranoia_qr_fingerprint(QS_RS2(local_state_json, peer_payload_json))); }

    static QString qr_confirm_exchange(QSTR local_state_json, QSTR peer_payload_json, QSTR confirmed_fingerprint)
    {
        return RS_QS(
            ::paranoia_qr_confirm_exchange(QS_RS3(local_state_json, peer_payload_json, confirmed_fingerprint)));
    }

    static std::pair<PrivateKey, PublicKey> ecies_generate_keypair()
    {
        char *out_private_key = nullptr, *out_pubkey = nullptr;
        ::paranoia_ecies_generate_keypair(&out_private_key, &out_pubkey);
        return {RS_QS(out_private_key), RS_QS(out_pubkey)};
    }

    static QString ecies_pubkey(QSTR private_key_b64)
    { return private_key_b64.isEmpty() ? "" : RS_QS(::paranoia_ecies_pubkey(QS_RS(private_key_b64))); }

    static QString ecies_encrypt(QSTR receiver_pubkey_b64, QSTR plaintext)
    { return RS_QS(::paranoia_ecies_encrypt(QS_RS2(receiver_pubkey_b64, plaintext))); }

    static QString ecies_decrypt(QSTR device_private_key_b64, QSTR envelope_json)
    { return RS_QS(::paranoia_ecies_decrypt(QS_RS2(device_private_key_b64, envelope_json))); }

    static std::pair<PrivateKey, PublicKey> generate_keypair()
    {
        char *out_private_key = nullptr, *out_pubkey = nullptr;
        ::paranoia_generate_keypair(&out_private_key, &out_pubkey);
        return {RS_QS(out_private_key), RS_QS(out_pubkey)};
    }

    static QString last_error()
    {
        const char *err = ::paranoia_last_error();
        return err ? QString::fromUtf8(err) : QString();
    }

    static QVariantMap errorResult(const QString &message) { return QVariantMap{{"ok", false}, {"error", message}}; }

    static QVariantMap lastRustErrorResult() { return errorResult(ParanoiaFFI::last_error()); }

private:
    RS_QS *ptr = nullptr;
};

#endif

#endif
