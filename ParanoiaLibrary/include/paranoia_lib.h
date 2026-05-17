// paranoia_lib.h
#pragma once
#include <stddef.h>
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

// ── Проверка резервного URL
// Выполняет PUT /notify через transport (rustls + cover-обёртка) и возвращает
// JSON {"ok": true} или {"ok": false, "error": "..."}.
// url — базовый URL сервера, БЕЗ хвостового /notify (путь добавит Transport).
// NULL только при ошибке инициализации/панике. Освободить через paranoia_free_string.
char *paranoia_check_reserve_url(CSTR url);

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

char *paranoia_send_reaction_json_keyring(ParanoiaHandle *h, CSTR user_a, CSTR user_b, CSTR keyring_json,
                                          CSTR target_id, CSTR emoji);

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

// Обновить локальные статусы прочтения через GET /arrived.
// Возвращает 0 при успехе и пишет количество изменённых сообщений в out_changed.
int paranoia_arrived_get_keyring(ParanoiaHandle *h, CSTR user_a, CSTR user_b, CSTR keyring_json,
                                 uint64_t *out_changed);

// Включить/выключить read receipts для диалога через PUT /arrived.
int paranoia_arrived_put_keyring(ParanoiaHandle *h, CSTR user_a, CSTR user_b, CSTR keyring_json,
                                 int receipts_enabled);

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

// ── VoIP сигналинг (HTTP /call/signal и /call/poll)
// ────────────────────────────
// Все возвращающие char* функции NULL на ошибке (paranoia_last_error()).
// Освобождать строки через paranoia_free_string.

// Отправить один сигнальный конверт (Offer/Answer/Hangup/Ice).
// kind: 0=Offer, 1=Answer, 2=Hangup, 3=Ice.
// master_key_b64 — dialog master key (32 байта base64), им шифруется payload.
// payload_json   — JSON-тело структуры из voip::signaling.
// Возвращает 0 при успехе, -1 при ошибке.
int paranoia_call_signal_send(ParanoiaHandle *h, CSTR from_user, CSTR to_user,
                              CSTR master_key_b64, unsigned char kind,
                              CSTR payload_json);

// Long-poll входящих сигнальных конвертов.
// peers_keys_json — JSON-массив [{"peer":"name","master_key_b64":"..."}, ...].
// long_poll_ms    — 0 = сразу; >0 = ждать на сервере (клампится до 30000).
// Возвращает JSON-массив строкой:
// [{"sender":"...","kind":N,"payload_json":"<decoded JSON>","ts_ms":N}, ...].
// Конверты с неподобранным ключом или повреждённым payload'ом тихо
// отбрасываются.
char *paranoia_call_poll(ParanoiaHandle *h, CSTR user, CSTR peers_keys_json,
                         unsigned int long_poll_ms);

// ── VoIP UDP-сессия
// ──────────────────────────────────────────────────────────
typedef struct ParanoiaCallSession ParanoiaCallSession;

// Расшифрованный Opus-фрейм (voice). Указатели валидны только во время вызова.
// Callee должен быть thread-safe — вызывается из фоновой задачи.
// `sequence` — sequence number из VoIP-заголовка voice-потока, нужен для
// jitter buffer.
typedef void (*paranoia_call_frame_cb)(void *userdata,
                                       const unsigned char *opus, size_t len,
                                       uint64_t sequence);

// Расшифрованный фрагмент H.264 NAL'а (video). Указатели валидны только во
// время вызова. `sequence` — per-video-stream sequence (нужен для детекции
// потерь и реассемблера). `rtp_timestamp` — общий для всех фрагментов
// одного кадра. `flags` — bit1 (FRAME_START) у первого фрагмента кадра.
typedef void (*paranoia_call_video_cb)(void *userdata,
                                       const unsigned char *nal_fragment,
                                       size_t len, uint64_t sequence,
                                       unsigned int rtp_timestamp,
                                       unsigned char flags);

// Изменение состояния сессии: "started" / "stopped" / "error".
typedef void (*paranoia_call_state_cb)(void *userdata, CSTR state);

// Запустить сессию. role: 0=initiator, 1=responder.
// Сессия всегда мультиплексирует voice + video по одному UDP-сокету —
// stream_id в заголовке пакета разводит их при приёме. Видео-канал просто
// молчит, если push_h264 никто не вызывает. Любой из callback'ов может быть
// NULL — соответствующий поток будет тихо игнорироваться.
// local_bind например "0.0.0.0:0", peer_addr "ip:port".
// session_id_b64 — 16 байт base64 (одинаков на обеих сторонах звонка).
// Возвращает NULL при ошибке. Освобождать только paranoia_call_session_stop.
ParanoiaCallSession *paranoia_call_session_start(
    CSTR local_bind, CSTR peer_addr, CSTR master_key_b64, CSTR session_id_b64,
    int role, paranoia_call_frame_cb frame_cb,
    paranoia_call_video_cb video_cb, paranoia_call_state_cb state_cb,
    void *userdata);

// Запустить сессию без заранее известного peer'а: только bind. Peer
// задаётся позже через paranoia_call_session_set_peer, либо сессия сама
// определит его при первом валидном входящем пакете (auto-discovery).
ParanoiaCallSession *paranoia_call_session_start_unbound(
    CSTR local_bind, CSTR master_key_b64, CSTR session_id_b64, int role,
    paranoia_call_frame_cb frame_cb, paranoia_call_video_cb video_cb,
    paranoia_call_state_cb state_cb, void *userdata);

// Задать peer-адрес уже запущенной сессии. peer_addr — "ip:port".
// Возвращает 0/-1.
int paranoia_call_session_set_peer(ParanoiaCallSession *s, CSTR peer_addr);

// Локальный адрес сессии вида "ip:port" (после bind).
// Возвращает NULL при ошибке. Освобождать через paranoia_free_string.
char *paranoia_call_session_local_addr(ParanoiaCallSession *s);

// Послать STUN Binding Request через UDP-сокет уже-запущенной сессии и
// вернуть reflexive "ip:port". В отличие от paranoia_stun_discover (с
// собственным сокетом), это даёт reflexive того же порта, что использует
// сессия — критично для NAT-traversal'а через ICE-кандидаты.
// Возвращает строку или NULL. Освобождать через paranoia_free_string.
char *paranoia_call_session_stun_discover(ParanoiaCallSession *s, CSTR stun_server,
                                          unsigned int timeout_ms);

// Выполнить TURN Allocate через UDP-сокет сессии и вернуть relayed "ip:port".
// Этот адрес отправляется собеседнику как relay candidate. Возвращает NULL при
// ошибке/таймауте. Освобождать через paranoia_free_string.
char *paranoia_call_session_turn_allocate(ParanoiaCallSession *s, CSTR turn_server,
                                          unsigned int timeout_ms);

// Переключить peer на TURN relay. Исходящие media будут отправляться через
// turn_server как Send Indication к peer_relay_addr, входящие Data Indication
// распаковываются автоматически.
// Возвращает 0/-1.
int paranoia_call_session_set_turn_peer(ParanoiaCallSession *s, CSTR turn_server,
                                        CSTR peer_relay_addr);

// Передать один Opus-фрейм для отправки (voice). Возвращает 0/-1.
int paranoia_call_session_push_opus(ParanoiaCallSession *s,
                                    const unsigned char *opus, size_t len);

// Передать один уже-фрагментированный H.264 NAL-пакет для отправки (video).
// Caller обязан выставлять FRAME_START (bit1) у первого фрагмента кадра и 0
// у остальных; rtp_timestamp одинаков у всех фрагментов одного кадра.
// Возвращает 0/-1.
int paranoia_call_session_push_h264(ParanoiaCallSession *s,
                                    const unsigned char *payload, size_t len,
                                    unsigned char flags,
                                    unsigned int rtp_timestamp);

// Корректно остановить и освободить сессию.
void paranoia_call_session_stop(ParanoiaCallSession *s);

// ── STUN
// ────────────────────────────────────────────────────────────────────
// Определить публичный (reflexive) IP:port через один STUN Binding Request.
// local_bind — например "0.0.0.0:0"; stun_server — "host:port" вашего STUN.
// Возвращает "ip:port" строкой или NULL при ошибке/таймауте.
// Освобождать через paranoia_free_string.
char *paranoia_stun_discover(CSTR local_bind, CSTR stun_server,
                             unsigned int timeout_ms);

#ifdef __cplusplus
}
#endif
