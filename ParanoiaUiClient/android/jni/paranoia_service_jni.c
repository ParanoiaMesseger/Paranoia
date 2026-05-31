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

JNIEXPORT jstring JNICALL
Java_app_paranoia_client_ParanoiaForegroundService_paranoiaLastError(JNIEnv *env, jclass cls)
{
    (void)cls;
    const char *err = paranoia_last_error();
    return (*env)->NewStringUTF(env, err ? err : "");
}
