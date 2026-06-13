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

// ── In-app обновление: HTTP через rustls (единый TLS-стек; работает на Android
// без Qt-OpenSSL-бандла). Plain GET/download без маскировки.
// GET → тело ответа (UTF-8) или NULL при ошибке/не-2xx. Освободить paranoia_free_string.
char *paranoia_http_get(CSTR url);
// Колбэк прогресса: возврат 0 => прервать загрузку; иначе продолжать.
typedef int (*ParanoiaDownloadProgress)(uint64_t received, uint64_t total, void *user_data);
// Скачать url в dest_path (rustls). 0=успех, -1=ошибка, -2=отменено. Блокирующая.
int paranoia_http_download(CSTR url, CSTR dest_path, ParanoiaDownloadProgress progress, void *user_data);

// ── Admin
void paranoia_generate_keypair(char **out_secret, char **out_pubkey);

// ── Регистрация
int paranoia_register_user(CSTR server_url, CSTR reserve_server_urls_json, CSTR username, CSTR user_pubkey_b64,
                           CSTR secret_b64);

// ── Admin-API (управление сервером по подписи администратора)
// Все функции возвращают JSON-строку тела ответа сервера, либо NULL при сетевой
// ошибке (см. paranoia_last_error). Освобождать через paranoia_free_string.
// admin_secret_b64 — приватный Ed25519-ключ администратора (base64, 32 байта).
//
// list_users     → {"success":true,"count":N,"users":{username:pubkey,...}}
// delete_user    → {"success":true,"message":"OK"} | {"success":false,"message":"..."}
// list_dialogues → {"success":true,"count":N,"dialogues":[{"dialogue_id":...,"last_seq":N},...]}
// prune          → {"success":true,"pruned":N,"pruned_ids":[...]}
// get_config     → {"success":true,"config":{port,stun_bind,turn_*,users_count,...}}
// set_config     → {"success":true,"message":"OK"}; patch_json — объект с полями
//                  port/stun_bind/turn_public_ip/turn_relay_port_range.
char *paranoia_admin_list_users(CSTR server_url, CSTR reserve_server_urls_json, CSTR admin_secret_b64);
char *paranoia_admin_delete_user(CSTR server_url, CSTR reserve_server_urls_json, CSTR admin_secret_b64,
                                 CSTR username);
char *paranoia_admin_list_dialogues(CSTR server_url, CSTR reserve_server_urls_json, CSTR admin_secret_b64);
char *paranoia_admin_prune_dialogues(CSTR server_url, CSTR reserve_server_urls_json, CSTR admin_secret_b64);
char *paranoia_admin_get_config(CSTR server_url, CSTR reserve_server_urls_json, CSTR admin_secret_b64);
char *paranoia_admin_set_config(CSTR server_url, CSTR reserve_server_urls_json, CSTR admin_secret_b64,
                                CSTR patch_json);
// Регистрация пользователя через admin put_json-путь. {"success":..,"message":..}
char *paranoia_admin_register_user(CSTR server_url, CSTR reserve_server_urls_json, CSTR admin_secret_b64,
                                   CSTR username, CSTR user_pubkey_b64);
// Вывести admin-pubkey (base64) из приватного ключа. NULL при ошибке.
char *paranoia_admin_pubkey_from_secret(CSTR admin_secret_b64);

// ── Corporate/commercial distribution-нода
// Зашифровать связку сотрудника PSK и запушить блоб (подпись админ-ключом).
// plaintext — keyring JSON, version монотонно (unix-ms). JSON-ответ или NULL.
char *paranoia_corp_publish(CSTR dist_url, CSTR admin_secret_b64, CSTR server_id, CSTR psk_b64,
                            unsigned long long version, CSTR plaintext);
// Удалить блоб сотрудника (подпись админ-ключом).
char *paranoia_corp_delete(CSTR dist_url, CSTR admin_secret_b64, CSTR server_id);
// Запушить коммерческий датасет (несекретный JSON, подпись админ-ключом).
char *paranoia_commercial_publish(CSTR dist_url, CSTR admin_secret_b64, CSTR data_json);
// Забрать+расшифровать связку (owner-proof подписью signing-ключом). plaintext
// keyring JSON, "" если блоба нет, NULL при ошибке.
char *paranoia_corp_sync(CSTR dist_url, CSTR server_id, CSTR signing_key_b64, CSTR psk_b64);

// ── Сообщения
// Keyring API
// использует JSON: [{"start_seq":1,"key":"base64-32-bytes"}, ...]
// Ключ выбирается локально по максимальному start_seq <= server_seq.
char *paranoia_send_text_json_keyring(ParanoiaHandle *h, CSTR user_a, CSTR user_b, CSTR keyring_json, CSTR text);

char *paranoia_send_text_reply_json_keyring(ParanoiaHandle *h, CSTR user_a, CSTR user_b, CSTR keyring_json,
                                            CSTR text, CSTR reply_to_id, CSTR reply_sender, CSTR reply_text);

char *paranoia_send_reaction_json_keyring(ParanoiaHandle *h, CSTR user_a, CSTR user_b, CSTR keyring_json,
                                          CSTR target_id, CSTR emoji);

char *paranoia_send_file_json_keyring(ParanoiaHandle *h, CSTR user_a, CSTR user_b, CSTR keyring_json, CSTR file_path,
                                      CSTR mime_type);

// Callback'и для прогресса отправки файла. Вызываются ПОСЛЕ успешной отправки
// каждого chunk'а (1-based), из runtime-потока FFI — caller обязан перевести
// результат в свой UI-thread.
typedef void (*paranoia_progress_callback)(uint32_t chunk_index, uint32_t total, void *user_data);

char *paranoia_send_file_json_keyring_with_progress(ParanoiaHandle *h, CSTR user_a, CSTR user_b,
                                                    CSTR keyring_json, CSTR file_path, CSTR mime_type,
                                                    paranoia_progress_callback progress, void *user_data);

// ── Фото-группы (мозаика из нескольких фото с общей подписью)
// Заголовок группы: group_id + caption (может быть пустой). Сами фото шлются
// отдельными вызовами grouped-with-progress с тем же group_id.
char *paranoia_send_photo_group_json_keyring(ParanoiaHandle *h, CSTR user_a, CSTR user_b, CSTR keyring_json,
                                             CSTR group_id, CSTR caption);

// Одно фото в составе группы: как send_file_with_progress, но с тегом group_id
// (вид фиксируется как изображение).
char *paranoia_send_photo_grouped_file_json_keyring_with_progress(ParanoiaHandle *h, CSTR user_a, CSTR user_b,
                                                                  CSTR keyring_json, CSTR file_path, CSTR mime_type,
                                                                  CSTR group_id, paranoia_progress_callback progress,
                                                                  void *user_data);

// ── Эфемерные большие файлы (вне истории, blob-хранилище с TTL)
// Лимиты файлов с сервера: JSON {max_history_file_size, large_file_max,
// ephemeral_retention_secs} (байты/секунды) или NULL.
char *paranoia_blob_limits_json_keyring(ParanoiaHandle *h, CSTR user_a, CSTR user_b, CSTR keyring_json);

// Отправить большой файл эфемерно (тело в blob, в историю — reference-сообщение).
// NULL при ошибке (last_error="file_too_large", если больше large_file_max).
char *paranoia_send_large_file_json_keyring_with_progress(ParanoiaHandle *h, CSTR user_a, CSTR user_b,
                                                          CSTR keyring_json, CSTR file_path, CSTR mime_type,
                                                          paranoia_progress_callback progress, void *user_data);

// Авто-выбор канала по размеру (история / эфемерно / отказ). C++ зовёт ЭТУ
// функцию для обычной отправки файла — порог резолвит lib.
char *paranoia_send_file_auto_json_keyring_with_progress(ParanoiaHandle *h, CSTR user_a, CSTR user_b,
                                                         CSTR keyring_json, CSTR file_path, CSTR mime_type,
                                                         paranoia_progress_callback progress, void *user_data);

// Получить новые сообщения с сервера.
// Возвращает JSON-массив или NULL при сетевой ошибке.
// Пустой массив [] — нет новых сообщений.
// При ошибках расшифровки возвращает доступные сообщения, но устанавливает
// paranoia_last_error() в "decryption_failed:<N>".
char *paranoia_receive_keyring(ParanoiaHandle *h, CSTR user_a, CSTR user_b, CSTR keyring_json);

// Проверить количество новых сообщений без загрузки payload.
// Возвращает 0 при успехе и пишет результат в out_count.
int paranoia_notify_count_keyring(ParanoiaHandle *h, CSTR user_a, CSTR user_b, CSTR keyring_json, uint64_t *out_count);

// Как notify_count_keyring, но с long-poll: сервер держит запрос до нового
// сообщения или long_poll_ms (капается серверным потолком). 0 = короткий опрос.
// Блокирует до удержания сервера — вызывать на воркере (НЕ на GUI-потоке).
int paranoia_notify_count_wait_keyring(ParanoiaHandle *h, CSTR user_a, CSTR user_b, CSTR keyring_json,
                                       uint32_t long_poll_ms, uint64_t *out_count);

// Как notify_count, но без учёта сообщений, уже прочитанных мной на другом
// устройстве (база = max(локальный seq, мой read-seq с сервера через arrived).
int paranoia_notify_unread_count_keyring(ParanoiaHandle *h, CSTR user_a, CSTR user_b, CSTR keyring_json,
                                         uint64_t *out_count);

// Полностью stateless проверка notify_count для notifications-сервиса. Не
// открывает SQLCipher и не трогает vault. Все нужные параметры передаются
// явно (см. ParanoiaLibrary/src/ffi.rs::paranoia_service_notify_count).
//   signing_key_b64    — Ed25519 signing key, base64 32-байтовый seed.
//   sender_server_id   — собственный server-side ID.
//   partner_server_id  — server-side ID собеседника.
//   seq                — последний известный last_pulled_seq (snapshot из UI).
// 0=ok, иначе см. paranoia_last_error.
int paranoia_service_notify_count(CSTR server_url, CSTR reserve_server_urls_json,
                                  CSTR signing_key_b64, CSTR sender_server_id,
                                  CSTR partner_server_id, uint64_t seq,
                                  uint64_t *out_count);

// Как paranoia_service_notify_count, но с long-poll: сервер держит запрос до
// нового сообщения в диалоге либо до long_poll_ms (капается сервером). Эндпоинт
// тот же /notify (маскировку не трогаем). Фон-сервис гоняет это per-диалог
// параллельно → мгновенные сообщения. 0=ok, иначе см. paranoia_last_error.
int paranoia_service_notify_count_wait(CSTR server_url, CSTR reserve_server_urls_json,
                                       CSTR signing_key_b64, CSTR sender_server_id,
                                       CSTR partner_server_id, uint64_t seq,
                                       uint32_t long_poll_ms, uint64_t *out_count);

// STATELESS опрос входящих звонков для notifications-сервиса (фон, без сессии).
// Аналог paranoia_call_poll, но без ParanoiaHandle (см. voip_ffi.rs::paranoia_service_call_poll).
//   signing_key_b64 — Ed25519 seed (32 байта, base64); user — свой server-id;
//   peers_keys_json — [{"peer","master_key_b64"}] для расшифровки офферов.
// Возвращает JSON-массив [{sender,kind,payload_json,ts_ms}] (освобождать
// paranoia_free_string) либо NULL при ошибке (paranoia_last_error).
char *paranoia_service_call_poll(CSTR server_url, CSTR reserve_server_urls_json,
                                 CSTR signing_key_b64, CSTR user,
                                 CSTR peers_keys_json, unsigned int long_poll_ms);

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

// Получить расшифрованные байты вложения В ПАМЯТЬ — без plaintext-копии
// на диске. Plaintext остаётся в RAM; вызывающая сторона обязана освободить
// буфер через paranoia_free_buffer(ptr, len). Persistent на диске — только
// зашифрованный attachment-cache/<msg_id>.enc. Возвращает 0=ok, -1=ошибка.
int paranoia_cache_attachment_bytes_keyring(ParanoiaHandle *h, CSTR user_a, CSTR user_b,
                                            CSTR keyring_json, CSTR message_id,
                                            unsigned char **out_ptr, size_t *out_len);

// Освободить буфер, возвращённый FFI'ями вида *_bytes_*. len ОБЯЗАН совпадать
// с тем, что было возвращено в out_len. NULL-указатель безопасен.
void paranoia_free_buffer(unsigned char *ptr, size_t len);

// ── Управление историей
// ─────────────────────────────────────────────────────── Удалить серверную
// историю диалога до cut_seq включительно (determinate). Возвращает 0 при
// успехе, -1 при ошибке.
int paranoia_determinate_keyring(ParanoiaHandle *h, CSTR user_a, CSTR user_b, CSTR keyring_json, uint64_t cut_seq);

// Удалить пакеты на сервере в диапазоне [from_seq, to_seq] (включительно).
// from_seq == 0 означает "с начала диалога". Возвращает 0 при успехе, -1 при ошибке.
int paranoia_remove_server_range_keyring(ParanoiaHandle *h, CSTR user_a, CSTR user_b, CSTR keyring_json,
                                         uint64_t from_seq, uint64_t to_seq);

// Атомарно удалить пакеты диалога в [from_seq, to_seq] и на сервере, и
// в локальной БД (single call для UI ranged-delete). Возвращает 0/-1.
int paranoia_delete_dialogue_range_keyring(ParanoiaHandle *h, CSTR user_a, CSTR user_b, CSTR keyring_json,
                                           uint64_t from_seq, uint64_t to_seq);

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

// Callback для async-варианта call_signal_send. Вызывается из фоновой
// tokio-задачи, поэтому caller обязан переключаться на свой поток сам.
// `status == 0` — успех; `error_message` валиден только во время вызова
// (NULL при status==0).
typedef void (*paranoia_call_signal_cb)(void *userdata, int status,
                                        CSTR error_message);

// Асинхронный вариант paranoia_call_signal_send: сразу возвращает управление,
// фактическая отправка идёт в tokio-runtime. Итог сообщается через `cb`
// (`cb` может быть NULL — fire-and-forget).
// `userdata` валиден на момент вызова cb — caller обязан не освобождать его
// раньше. Handle тоже должен жить до cb.
// Возвращает 0 если задача поставлена в очередь, -1 при ошибке подготовки.
int paranoia_call_signal_send_async(ParanoiaHandle *h, CSTR from_user,
                                    CSTR to_user, CSTR master_key_b64,
                                    unsigned char kind, CSTR payload_json,
                                    paranoia_call_signal_cb cb, void *userdata);

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

// Текущий peer-адрес сессии (rx-источник, обновляется auto-discover'ом).
// Пустая строка если peer ещё не определён. NULL при ошибке. Освобождать
// через paranoia_free_string.
char *paranoia_call_session_get_peer(ParanoiaCallSession *s);

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

// ── Local Vault (LocalStorageEncryptionPolicy.md)
// Установить корень app data. Вызывать на старте до любых других vault-функций.
int paranoia_vault_init(CSTR app_data_root);

// 0=not_initialized, 1=locked, 2=unlocked, -1=ошибка (см. paranoia_last_error).
int paranoia_vault_status(void);

// Установить PIN впервые. 0=ok, 1=already_initialized, -1=internal.
int paranoia_vault_set_pin(CSTR pin);

// Разблокировать. 0=ok, 1=wrong_pin, 2=locked_out, 3=not_initialized, -1=internal.
int paranoia_vault_unlock(CSTR pin);

// PKCS#11-токен (доступно только при сборке libparanoia с фичей `pkcs11`).
// Инициализировать НОВЫЙ vault под токеном. 0=ok, 1=already_initialized, -1=error.
int paranoia_vault_init_token(CSTR module_path, CSTR token_pin);
// Разблокировать token-mode vault. 0=ok, 3=not_initialized, -1=error.
int paranoia_vault_unlock_token(CSTR module_path, CSTR token_pin);

// ── Masking-профиль (маскировка трафика / раздача)
// Сменить активную маскировку: profile_json (JSON профиля) или NULL/"" =
// встроенная food-маска. 0=ok, -1=error.
int paranoia_set_masking_profile(ParanoiaHandle *h, CSTR profile_json);
// Применить ПОДПИСАННЫЙ профиль: проверить подпись доверенным ключом
// trusted_pubkey_b64 и при успехе сменить маскировку. 0=ok, -1=error.
int paranoia_set_signed_masking_profile(ParanoiaHandle *h, CSTR signed_json, CSTR trusted_pubkey_b64);
// Подписать профиль extended-секретом (панель). JSON конверта или NULL.
// Освобождать paranoia_free_string.
char *paranoia_sign_masking_profile(CSTR profile_json, CSTR extended_secret_b64);
// Скачать подписанный профиль (GET url, опц. Bearer bearer_token=NULL/""),
// проверить подпись trusted_pubkey_b64 и применить. 0=ok, -1=error.
int paranoia_fetch_and_apply_signed_profile(ParanoiaHandle *h, CSTR url, CSTR trusted_pubkey_b64, CSTR bearer_token);
// Задать активный masking-профиль для admin/reg-трафика (глобально). NULL/"" —
// очистить (admin-трафик пойдёт плоско). 0=ok, -1=error.
int paranoia_admin_set_masking_profile(CSTR profile_json);
// Случайная правдоподобная схема маскировки (JSON SchemaVariant) — «бросить
// кости» в панели. Доступна только в сборке libparanoia с фичей schema-gen;
// иначе символ отсутствует. NULL при ошибке. Освобождать paranoia_free_string.
char *paranoia_generate_masking_schema(void);
// Случайный путь фейкового эндпоинта (таргет). Только в сборке с фичей
// schema-gen. NULL при ошибке. Освобождать paranoia_free_string.
char *paranoia_generate_masking_path(void);
// Запушить подписанный masking-профиль на distribution-ноду (PUT
// /masking/profile). admin_secret_b64 — base admin-ключ сервера (подпись
// записи). signed_profile_json — конверт, подписанный extended-ключом. Пустая
// строка при успехе, иначе сообщение об ошибке. Освобождать paranoia_free_string.
char *paranoia_masking_publish(CSTR dist_url, CSTR admin_secret_b64, CSTR signed_profile_json);

// Очистить master_key из RAM. Всегда 0.
int paranoia_vault_lock(void);

// Проверить старый PIN без замены активных ключей.
// 0=ok, 1=wrong_pin, 3=not_initialized, -1=internal.
int paranoia_vault_verify_pin(CSTR pin);

// ── Транзакционный rekey ────────────────────────────────────────────────
// Полный flow смены PIN с перешифровкой всех файлов и БД:
//   1) paranoia_vault_verify_pin(old)  → проверить старый PIN
//   2) paranoia_vault_rekey_begin(new) → подготовить новые ключи
//   3) для каждого JSON-файла:  paranoia_vault_rekey_file(path)
//   4) для каждой SQLite БД:    paranoia_vault_rekey_db(db_path)
//   5) paranoia_vault_rekey_commit() → атомарно свапнуть и записать vault.json
// При ошибке на любом шаге — paranoia_vault_rekey_abort().
// ВНИМАНИЕ: abort НЕ откатывает уже перешифрованные файлы.
int paranoia_vault_rekey_begin(CSTR new_pin);
int paranoia_vault_rekey_file(CSTR path);
int paranoia_vault_rekey_db(CSTR db_path);
// salt_str — то же значение, что использовалось при первичном шифровании
// (обычно UUID сообщения).
int paranoia_vault_rekey_attachment(CSTR salt_str, CSTR path);
int paranoia_vault_rekey_commit(void);
int paranoia_vault_rekey_abort(void);

// Сколько секунд осталось до конца текущего lockout-таймаута. 0=можно вводить.
int paranoia_vault_lockout_seconds(uint64_t *out_secs);

// Низкоуровневое шифрованное IO для JSON-файлов. 0=ok, -1=ошибка.
int paranoia_vault_encrypt_json(CSTR path, const unsigned char *data, size_t len);
// NULL=ошибка; иначе расшифрованный JSON как UTF-8 C-string (free через paranoia_free_string).
char *paranoia_vault_decrypt_json(CSTR path);

// Шифрование attachment'ов per-file ключом HKDF(files_key, salt_str, "attachment-v1").
// salt_str — обычно UUID сообщения. 0=ok, -1=ошибка.
int paranoia_vault_encrypt_attachment(CSTR salt_str, CSTR src_path, CSTR dst_path);
int paranoia_vault_decrypt_attachment(CSTR salt_str, CSTR src_path, CSTR dst_path);

#ifdef __cplusplus
}
#endif
