#include "PlatformNotifications.hpp"

#include "utils/Paths.hpp"

#include <QDebug>
#include <mutex>

#if defined(OS_ANDROID)
#include <QJniObject>
#include <QCoreApplication>
#include <android/log.h>
#include <jni.h>
#define PARANOIA_LOGI(fmt, ...) __android_log_print(ANDROID_LOG_INFO, "ParanoiaService", fmt, ##__VA_ARGS__)
#else
#define PARANOIA_LOGI(...) ((void)0)
#endif

#if defined(OS_IOS)
extern "C" void paranoia_ios_register_background_tasks();
extern "C" void paranoia_ios_schedule_background_polling();
extern "C" void paranoia_ios_cancel_background_polling();
extern "C" void paranoia_ios_show_message_count(unsigned long long count, const char *profileId, const char *peer);
extern "C" void paranoia_ios_show_incoming_call(const char *callId);
extern "C" void paranoia_ios_store_pending_call_offer(const char *json);
extern "C" bool paranoia_ios_take_pending_call_offer(char **out_json);
extern "C" bool paranoia_ios_take_pending_call_answer();
extern "C" void paranoia_ios_clear_delivered_notifications();
extern "C" bool paranoia_ios_take_open_target(char **out_profile_id, char **out_peer);
extern "C" void paranoia_ios_free_string(char *value);
#endif

#if defined(OS_MAC)
extern "C" void paranoia_macos_register_notifications();
extern "C" void paranoia_macos_show_message_count(unsigned long long count);
extern "C" void paranoia_macos_clear_delivered_notifications();
#endif

namespace
{
    std::mutex callbackMutex;
    std::function<void()> backgroundPollCallback;

#if defined(Q_OS_ANDROID)
    QJniObject androidContext() { return QNativeInterface::QAndroidApplication::context(); }

    void callAndroidService(const char *method)
    {
        const QJniObject context = androidContext();
        if (!context.isValid()) return;
        QJniObject::callStaticMethod<void>("app/paranoia/client/ParanoiaForegroundService", method,
                                           "(Landroid/content/Context;)V", context.object<jobject>());
    }
#endif
}

namespace PlatformNotifications
{
    void registerBackgroundTasks()
    {
#if defined(OS_ANDROID)
        // Передаём сервису абсолютный путь к app data root — он живёт в отдельном
        // процессе (:notifications) и сам через JNI открывает paranoia_lib без
        // Qt-зависимостей. Без этого пути сервис не находит profiles.json/dialogs.json.
        const QJniObject context = androidContext();
        if (!context.isValid()) return;
        const QJniObject appDataRoot = QJniObject::fromString(Paths::appDataRoot().absolutePath());
        QJniObject::callStaticMethod<void>("app/paranoia/client/ParanoiaForegroundService", "initialize",
                                           "(Landroid/content/Context;Ljava/lang/String;)V",
                                           context.object<jobject>(), appDataRoot.object<jstring>());
#elif defined(OS_IOS)
        paranoia_ios_register_background_tasks();
#elif defined(OS_MAC)
        paranoia_macos_register_notifications();
#endif
    }

    void setBackgroundPollCallback(std::function<void()> callback)
    {
        std::scoped_lock lock(callbackMutex);
        backgroundPollCallback = std::move(callback);
    }

    void setApplicationForeground(bool foreground)
    {
#if defined(OS_ANDROID)
        const QJniObject context = androidContext();
        if (!context.isValid()) return;
        QJniObject::callStaticMethod<void>("app/paranoia/client/ParanoiaForegroundService", "setApplicationForeground",
                                           "(Landroid/content/Context;Z)V",
                                           context.object<jobject>(), static_cast<jboolean>(foreground));
#else
        Q_UNUSED(foreground)
#endif
    }

    void triggerBackgroundPoll()
    {
        std::function<void()> callback;
        {
            std::scoped_lock lock(callbackMutex);
            callback = backgroundPollCallback;
        }
        if (callback) {
            PARANOIA_LOGI("android service callback received in background");
            callback();
        } else {
            PARANOIA_LOGI("android service callback ignored: no callback registered");
        }
    }

    void startBackgroundPollingService()
    {
#if defined(OS_ANDROID)
        callAndroidService("start");
#elif defined(OS_IOS)
        paranoia_ios_schedule_background_polling();
#endif
    }

    void stopBackgroundPollingService()
    {
#if defined(OS_ANDROID)
        callAndroidService("stop");
#elif defined(OS_IOS)
        paranoia_ios_cancel_background_polling();
#endif
    }

    void showMessageCount(quint64 count, const QString &profileId, const QString &peer)
    {
#if defined(OS_ANDROID)
        // Android-сервис теперь обезличен: peer/profileId в notification text не
        // показываются. Передаём только count; profileId/peer игнорируем (важно
        // для UI / iOS, где они всё ещё нужны для deep-link при тапе).
        Q_UNUSED(profileId)
        Q_UNUSED(peer)
        const QJniObject context = androidContext();
        if (!context.isValid()) return;
        QJniObject::callStaticMethod<void>("app/paranoia/client/ParanoiaForegroundService", "showNewMessages",
                                           "(Landroid/content/Context;J)V",
                                           context.object<jobject>(), static_cast<jlong>(count));
#elif defined(OS_IOS)
        const QByteArray profileIdUtf8 = profileId.toUtf8();
        const QByteArray peerUtf8      = peer.toUtf8();
        paranoia_ios_show_message_count(static_cast<unsigned long long>(count),
                                        profileIdUtf8.constData(), peerUtf8.constData());
#elif defined(OS_MAC)
        Q_UNUSED(profileId)
        Q_UNUSED(peer)
        paranoia_macos_show_message_count(static_cast<unsigned long long>(count));
#else
        Q_UNUSED(count)
        Q_UNUSED(profileId)
        Q_UNUSED(peer)
#endif
    }

    // Локальный баннер входящего вызова (#6). На Android звонки в фоне ведёт сам
    // ParanoiaForegroundService (Java call-poll), здесь только iOS-путь (опрос
    // идёт в Qt-процессе, см. NotificationCoordinator).
    void showIncomingCall(const QString &callId)
    {
#if defined(OS_IOS)
        const QByteArray callIdUtf8 = callId.toUtf8();
        paranoia_ios_show_incoming_call(callIdUtf8.constData());
#else
        Q_UNUSED(callId)
#endif
    }

    void clearAccumulatedNotifications()
    {
#if defined(OS_ANDROID)
        const QJniObject context = androidContext();
        if (!context.isValid()) return;
        QJniObject::callStaticMethod<void>("app/paranoia/client/ParanoiaForegroundService",
                                           "clearMessageNotifications",
                                           "(Landroid/content/Context;)V", context.object<jobject>());
#elif defined(OS_IOS)
        paranoia_ios_clear_delivered_notifications();
#elif defined(OS_MAC)
        paranoia_macos_clear_delivered_notifications();
#endif
        // Для Linux/Windows очистка происходит на уровне DesktopTray
        // (см. DesktopTray::clearAccumulatedNotifications).
    }

    NotificationTarget takeOpenTargetFromNotification()
    {
        NotificationTarget target;
#if defined(OS_ANDROID)
        const QJniObject context = androidContext();
        if (!context.isValid()) return target;
        const QJniObject result = QJniObject::callStaticObjectMethod(
            "app/paranoia/client/ParanoiaForegroundService", "takeOpenTarget",
            "(Landroid/content/Context;)Ljava/lang/String;", context.object<jobject>());
        const QString encoded     = result.isValid() ? result.toString() : QString();
        const qsizetype separator = encoded.indexOf(QLatin1Char('\n'));
        if (separator < 0) {
            target.peer = encoded;
        } else {
            target.profileId = encoded.left(separator);
            target.peer      = encoded.mid(separator + 1);
        }
#elif defined(OS_IOS)
        char *profileIdC = nullptr;
        char *peerC      = nullptr;
        if (paranoia_ios_take_open_target(&profileIdC, &peerC)) {
            if (profileIdC) {
                target.profileId = QString::fromUtf8(profileIdC);
                paranoia_ios_free_string(profileIdC);
            }
            if (peerC) {
                target.peer = QString::fromUtf8(peerC);
                paranoia_ios_free_string(peerC);
            }
        }
#endif
        return target;
    }

    QString takeOpenPeerFromNotification() { return takeOpenTargetFromNotification().peer; }

    void storePendingCallOffer(const QString &envelopeJson)
    {
#if defined(OS_IOS)
        const QByteArray utf8 = envelopeJson.toUtf8();
        paranoia_ios_store_pending_call_offer(utf8.constData());
#else
        // Android: оффер сохраняет сам фон-сервис (тот же процесс, что показывает
        // баннер) — см. ParanoiaForegroundService.showIncomingCall.
        Q_UNUSED(envelopeJson)
#endif
    }

    // Забрать отложенный конверт входящего звонка (#6 handoff). Фон-сервис сохранил
    // расшифрованный оффер; foreground забирает его при открытии и скармливает в
    // CallSignaling.injectEnvelope. Возвращает JSON конверта или пустую строку.
    QString takePendingCallOffer()
    {
#if defined(OS_ANDROID)
        const QJniObject context = androidContext();
        if (!context.isValid()) return {};
        const QJniObject result = QJniObject::callStaticObjectMethod(
            "app/paranoia/client/ParanoiaForegroundService", "takePendingCallOffer",
            "(Landroid/content/Context;)Ljava/lang/String;", context.object<jobject>());
        return result.isValid() ? result.toString() : QString();
#elif defined(OS_IOS)
        char *offerC = nullptr;
        if (paranoia_ios_take_pending_call_offer(&offerC) && offerC) {
            const QString offer = QString::fromUtf8(offerC);
            paranoia_ios_free_string(offerC);
            return offer;
        }
        return {};
#else
        return {};
#endif
    }

    void heartbeatUiCallPolling()
    {
#if defined(OS_ANDROID)
        const QJniObject context = androidContext();
        if (!context.isValid()) return;
        QJniObject::callStaticMethod<void>(
            "app/paranoia/client/ParanoiaForegroundService", "heartbeatUiCallPolling",
            "(Landroid/content/Context;)V", context.object<jobject>());
#endif
    }

    void clearUiCallPolling()
    {
#if defined(OS_ANDROID)
        const QJniObject context = androidContext();
        if (!context.isValid()) return;
        QJniObject::callStaticMethod<void>(
            "app/paranoia/client/ParanoiaForegroundService", "clearUiCallPolling",
            "(Landroid/content/Context;)V", context.object<jobject>());
#endif
    }

    void handoffIncomingCallToService(const QString &envelopeJson)
    {
#if defined(OS_ANDROID)
        const QJniObject context = androidContext();
        if (!context.isValid()) return;
        const QJniObject jenv = QJniObject::fromString(envelopeJson);
        QJniObject::callStaticMethod<void>(
            "app/paranoia/client/ParanoiaForegroundService", "showIncomingCallFromUi",
            "(Landroid/content/Context;Ljava/lang/String;)V", context.object<jobject>(), jenv.object<jstring>());
#else
        Q_UNUSED(envelopeJson)
#endif
    }

    bool takePendingCallAnswerIntent()
    {
#if defined(OS_ANDROID)
        const QJniObject context = androidContext();
        if (!context.isValid()) return false;
        return QJniObject::callStaticMethod<jboolean>(
            "app/paranoia/client/ParanoiaForegroundService", "takePendingCallAnswerIntent",
            "(Landroid/content/Context;)Z", context.object<jobject>());
#elif defined(OS_IOS)
        return paranoia_ios_take_pending_call_answer();
#else
        return false;
#endif
    }

    void publishServiceSnapshot(const QString &snapshotJson)
    {
#if defined(OS_ANDROID)
        const QJniObject context = androidContext();
        if (!context.isValid()) return;
        const QJniObject javaJson = QJniObject::fromString(snapshotJson);
        QJniObject::callStaticMethod<void>("app/paranoia/client/ParanoiaForegroundService",
                                           "publishSnapshot",
                                           "(Landroid/content/Context;Ljava/lang/String;)V",
                                           context.object<jobject>(), javaJson.object<jstring>());
#else
        Q_UNUSED(snapshotJson)
#endif
    }

    void clearServiceSnapshot()
    {
#if defined(OS_ANDROID)
        callAndroidService("clearSnapshot");
#endif
    }
}

extern "C" void paranoia_platform_trigger_background_poll() { PlatformNotifications::triggerBackgroundPoll(); }
