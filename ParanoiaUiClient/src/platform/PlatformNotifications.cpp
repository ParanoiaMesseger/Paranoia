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
        const QJniObject context = androidContext();
        if (!context.isValid()) return;
        const QJniObject javaProfileId = QJniObject::fromString(profileId);
        const QJniObject javaPeer      = QJniObject::fromString(peer);
        QJniObject::callStaticMethod<void>("app/paranoia/client/ParanoiaForegroundService", "showNewMessages",
                                           "(Landroid/content/Context;JLjava/lang/String;Ljava/lang/String;)V",
                                           context.object<jobject>(), static_cast<jlong>(count),
                                           javaProfileId.object<jstring>(), javaPeer.object<jstring>());
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
}

extern "C" void paranoia_platform_trigger_background_poll() { PlatformNotifications::triggerBackgroundPoll(); }
