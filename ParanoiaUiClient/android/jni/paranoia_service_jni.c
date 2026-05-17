// Минимальный JNI-шим для notifications-сервиса.
//
// Живёт в отдельном процессе (android:process=":notifications") и не
// зависит от Qt — иначе libParanoia_<abi>.so при загрузке тянет
// libQt6Multimedia, чей JNI_OnLoad дёргает QJniEnvironment::getJniEnv()
// и падает, потому что javaVM у Qt в этом процессе ничем не заполнен
// (QtActivity там никогда не стартовала).
//
// Здесь — только тонкая обёртка над paranoia_lib C-ABI, чтобы Java-сервис
// мог сам пройтись по профилям/диалогам и спросить у сервера notify_count.

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

JNIEXPORT jlong JNICALL
Java_app_paranoia_client_ParanoiaForegroundService_paranoiaClientNew(JNIEnv *env, jclass cls,
                                                                     jstring server_url,
                                                                     jstring reserve_urls_json,
                                                                     jstring server_id,
                                                                     jstring private_key_b64,
                                                                     jstring db_path)
{
    (void)cls;
    const char *url  = take_chars(env, server_url);
    const char *res  = take_chars(env, reserve_urls_json);
    const char *id   = take_chars(env, server_id);
    const char *key  = take_chars(env, private_key_b64);
    const char *db   = take_chars(env, db_path);

    ParanoiaHandle *handle = paranoia_client_new(url ? url : "",
                                                 res ? res : "",
                                                 id ? id : "",
                                                 key ? key : "",
                                                 db ? db : "");

    release_chars(env, server_url, url);
    release_chars(env, reserve_urls_json, res);
    release_chars(env, server_id, id);
    release_chars(env, private_key_b64, key);
    release_chars(env, db_path, db);
    return (jlong)(uintptr_t)handle;
}

JNIEXPORT void JNICALL
Java_app_paranoia_client_ParanoiaForegroundService_paranoiaClientFree(JNIEnv *env, jclass cls, jlong handle)
{
    (void)env;
    (void)cls;
    if (handle) paranoia_client_free((ParanoiaHandle *)(uintptr_t)handle);
}

JNIEXPORT jlong JNICALL
Java_app_paranoia_client_ParanoiaForegroundService_paranoiaNotifyCount(JNIEnv *env, jclass cls, jlong handle,
                                                                       jstring user_a, jstring user_b,
                                                                       jstring keyring_json)
{
    (void)cls;
    if (!handle) return -1;
    const char *a = take_chars(env, user_a);
    const char *b = take_chars(env, user_b);
    const char *k = take_chars(env, keyring_json);

    uint64_t count = 0;
    const int rc = paranoia_notify_count_keyring((ParanoiaHandle *)(uintptr_t)handle,
                                                 a ? a : "", b ? b : "", k ? k : "", &count);

    release_chars(env, user_a, a);
    release_chars(env, user_b, b);
    release_chars(env, keyring_json, k);
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
