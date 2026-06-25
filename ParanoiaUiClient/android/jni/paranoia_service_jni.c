// Минимальный JNI-шим для notifications-сервиса.
//
// Живёт в отдельном процессе (android:process=":notifications") и не
// зависит от Qt — иначе libParanoia_<abi>.so при загрузке тянет
// libQt6Multimedia, чей JNI_OnLoad дёргает QJniEnvironment::getJniEnv()
// и падает, потому что javaVM у Qt в этом процессе ничем не заполнен
// (QtActivity там никогда не стартовала).
//
// Сервис работает ТОЛЬКО по in-memory snapshot'у, который UI присылает
// после unlock'а (см. ParanoiaForegroundService::snapshot). Никакого
// SQLCipher, никакого vault — даже dump процесса не вскрывает контент
// диалогов. Здесь — тонкая обёртка над двумя C-FFI: paranoia_android_init
// (для reqwest/network init) и paranoia_service_notify_count (stateless
// /notify к серверу). Bonus: paranoia_last_error для диагностики.

#include <jni.h>
#include <stdint.h>
#include <stdlib.h>

#include "paranoia_lib.h"

static const char *take_chars(JNIEnv *env, jstring s)
{
    if (!s) return NULL;
    return (*env)->GetStringUTFChars(env, s, NULL);
}

static void release_chars(JNIEnv *env, jstring s, const char *chars)
{
    if (s && chars) (*env)->ReleaseStringUTFChars(env, s, chars);
}

JNIEXPORT jboolean JNICALL
Java_app_paranoia_client_ParanoiaForegroundService_paranoiaInit(JNIEnv *env, jclass cls, jobject context)
{
    (void)cls;
    return paranoia_android_init((void *)env, (void *)context) == 0 ? JNI_TRUE : JNI_FALSE;
}

// Stateless notify-count: ни handle, ни БД, ни keyring'а. Все нужные
// идентификаторы и ключ подписи приходят из snapshot'а (UI-процесса).
// Возвращает count >= 0 при успехе, -1 при сетевой/протокольной ошибке.
// Подробности ошибки см. paranoia_last_error.
JNIEXPORT jlong JNICALL
Java_app_paranoia_client_ParanoiaForegroundService_paranoiaServiceNotifyCount(
    JNIEnv *env, jclass cls,
    jstring server_url, jstring reserve_urls_json,
    jstring signing_key_b64, jstring sender_server_id, jstring partner_server_id,
    jlong seq)
{
    (void)cls;
    const char *url        = take_chars(env, server_url);
    const char *res        = take_chars(env, reserve_urls_json);
    const char *sk         = take_chars(env, signing_key_b64);
    const char *sender     = take_chars(env, sender_server_id);
    const char *partner    = take_chars(env, partner_server_id);

    uint64_t count = 0;
    const int rc = paranoia_service_notify_count(
        url ? url : "", res ? res : "", sk ? sk : "",
        sender ? sender : "", partner ? partner : "",
        seq < 0 ? 0 : (uint64_t)seq, &count);

    release_chars(env, server_url, url);
    release_chars(env, reserve_urls_json, res);
    release_chars(env, signing_key_b64, sk);
    release_chars(env, sender_server_id, sender);
    release_chars(env, partner_server_id, partner);

    if (rc != 0) return -1;
    if (count > (uint64_t)INT64_MAX) return INT64_MAX;
    return (jlong)count;
}

// Как paranoiaServiceNotifyCount, но с long-poll (сервер держит запрос до нового
// сообщения / long_poll_ms). Фон-сервис гоняет per-диалог параллельно → мгновенные
// сообщения, тот же маскированный /notify (без правок сервера).
JNIEXPORT jlong JNICALL
Java_app_paranoia_client_ParanoiaForegroundService_paranoiaServiceNotifyCountWait(
    JNIEnv *env, jclass cls,
    jstring server_url, jstring reserve_urls_json,
    jstring signing_key_b64, jstring sender_server_id, jstring partner_server_id,
    jlong seq, jint long_poll_ms)
{
    (void)cls;
    const char *url        = take_chars(env, server_url);
    const char *res        = take_chars(env, reserve_urls_json);
    const char *sk         = take_chars(env, signing_key_b64);
    const char *sender     = take_chars(env, sender_server_id);
    const char *partner    = take_chars(env, partner_server_id);

    uint64_t count = 0;
    const int rc = paranoia_service_notify_count_wait(
        url ? url : "", res ? res : "", sk ? sk : "",
        sender ? sender : "", partner ? partner : "",
        seq < 0 ? 0 : (uint64_t)seq,
        long_poll_ms < 0 ? 0 : (uint32_t)long_poll_ms, &count);

    release_chars(env, server_url, url);
    release_chars(env, reserve_urls_json, res);
    release_chars(env, signing_key_b64, sk);
    release_chars(env, sender_server_id, sender);
    release_chars(env, partner_server_id, partner);

    if (rc != 0) return -1;
    if (count > (uint64_t)INT64_MAX) return INT64_MAX;
    return (jlong)count;
}

// MULTI-notify long-poll: ОДИН запрос на N диалогов вместо N одиночных
// (снимает «N диалогов = N запросов» — батарея фон-сервиса). items_json —
// массив [{"partner":"<server_id>","seq":<u64>}, …]; сервер просыпается на ПЕРВОМ
// зажёгшемся диалоге. Возвращает JSON-массив [{"partner":"…","n":<u64>}, …]
// ТОЛЬКО зажжённых (n>0), либо null при ошибке (paranoia_last_error). Тот же
// маскированный /notify (правок маскировки не нужно — режим по форме запроса).
JNIEXPORT jstring JNICALL
Java_app_paranoia_client_ParanoiaForegroundService_paranoiaServiceNotifyMultiWait(
    JNIEnv *env, jclass cls,
    jstring server_url, jstring reserve_urls_json,
    jstring signing_key_b64, jstring sender_server_id,
    jstring items_json, jint long_poll_ms)
{
    (void)cls;
    const char *url    = take_chars(env, server_url);
    const char *res    = take_chars(env, reserve_urls_json);
    const char *sk     = take_chars(env, signing_key_b64);
    const char *sender = take_chars(env, sender_server_id);
    const char *items  = take_chars(env, items_json);

    char *out      = NULL;
    const int rc = paranoia_service_notify_multi_wait(
        url ? url : "", res ? res : "", sk ? sk : "",
        sender ? sender : "", items ? items : "",
        long_poll_ms < 0 ? 0u : (uint32_t)long_poll_ms, &out);

    release_chars(env, server_url, url);
    release_chars(env, reserve_urls_json, res);
    release_chars(env, signing_key_b64, sk);
    release_chars(env, sender_server_id, sender);
    release_chars(env, items_json, items);

    if (rc != 0 || !out) {
        if (out) paranoia_free_string(out);
        return NULL;
    }
    jstring result = (*env)->NewStringUTF(env, out);
    paranoia_free_string(out);
    return result;
}

// Stateless опрос входящих звонков: возвращает JSON-массив конвертов
// [{sender,kind,payload_json,ts_ms}] или null при ошибке (paranoia_last_error).
JNIEXPORT jstring JNICALL
Java_app_paranoia_client_ParanoiaForegroundService_paranoiaServiceCallPoll(
    JNIEnv *env, jclass cls,
    jstring server_url, jstring reserve_urls_json,
    jstring signing_key_b64, jstring user, jstring peers_keys_json,
    jint long_poll_ms)
{
    (void)cls;
    const char *url   = take_chars(env, server_url);
    const char *res   = take_chars(env, reserve_urls_json);
    const char *sk    = take_chars(env, signing_key_b64);
    const char *usr   = take_chars(env, user);
    const char *peers = take_chars(env, peers_keys_json);

    char *json = paranoia_service_call_poll(
        url ? url : "", res ? res : "", sk ? sk : "",
        usr ? usr : "", peers ? peers : "",
        long_poll_ms < 0 ? 0u : (unsigned int)long_poll_ms);

    release_chars(env, server_url, url);
    release_chars(env, reserve_urls_json, res);
    release_chars(env, signing_key_b64, sk);
    release_chars(env, user, usr);
    release_chars(env, peers_keys_json, peers);

    if (!json) return NULL;
    jstring result = (*env)->NewStringUTF(env, json);
    paranoia_free_string(json);
    return result;
}

JNIEXPORT jstring JNICALL
Java_app_paranoia_client_ParanoiaForegroundService_paranoiaLastError(JNIEnv *env, jclass cls)
{
    (void)cls;
    const char *err = paranoia_last_error();
    return (*env)->NewStringUTF(env, err ? err : "");
}
