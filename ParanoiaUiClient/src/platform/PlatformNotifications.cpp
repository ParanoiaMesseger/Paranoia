#include "PlatformNotifications.hpp"

#include <QDebug>
#include <mutex>

#if defined(Q_OS_ANDROID)
#include <QJniObject>
#include <QCoreApplication>
#include <android/log.h>
#include <jni.h>
#define PARANOIA_LOGI(fmt, ...) __android_log_print(ANDROID_LOG_INFO, "ParanoiaService", fmt, ##__VA_ARGS__)
#else
#define PARANOIA_LOGI(...) ((void)0)
#endif

#if defined(Q_OS_IOS)
extern "C" void paranoia_ios_register_background_tasks();
extern "C" void paranoia_ios_schedule_background_polling();
extern "C" void paranoia_ios_cancel_background_polling();
extern "C" void paranoia_ios_show_message_count(unsigned long long count);
#endif

#if defined(Q_OS_DARWIN) && !defined(Q_OS_IOS)
extern "C" void paranoia_macos_register_notifications();
extern "C" void paranoia_macos_show_message_count(unsigned long long count);
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
#if defined(Q_OS_ANDROID)
        callAndroidService("initialize");
#elif defined(Q_OS_IOS)
        paranoia_ios_register_background_tasks();
#elif defined(Q_OS_DARWIN)
        paranoia_macos_register_notifications();
#endif
    }

    void setBackgroundPollCallback(std::function<void()> callback)
    {
        std::scoped_lock lock(callbackMutex);
        backgroundPollCallback = std::move(callback);
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
#if defined(Q_OS_ANDROID)
        callAndroidService("start");
#elif defined(Q_OS_IOS)
        paranoia_ios_schedule_background_polling();
#endif
    }

    void stopBackgroundPollingService()
    {
#if defined(Q_OS_ANDROID)
        callAndroidService("stop");
#elif defined(Q_OS_IOS)
        paranoia_ios_cancel_background_polling();
#endif
    }

    void showMessageCount(quint64 count, const QString &profileId, const QString &peer)
    {
#if defined(Q_OS_ANDROID)
        const QJniObject context = androidContext();
        if (!context.isValid()) return;
        const QJniObject javaProfileId = QJniObject::fromString(profileId);
        const QJniObject javaPeer = QJniObject::fromString(peer);
        QJniObject::callStaticMethod<void>("app/paranoia/client/ParanoiaForegroundService", "showNewMessages",
                                            "(Landroid/content/Context;JLjava/lang/String;Ljava/lang/String;)V",
                                            context.object<jobject>(), static_cast<jlong>(count),
                                            javaProfileId.object<jstring>(), javaPeer.object<jstring>());
#elif defined(Q_OS_IOS)
        Q_UNUSED(profileId)
        Q_UNUSED(peer)
        paranoia_ios_show_message_count(static_cast<unsigned long long>(count));
#elif defined(Q_OS_DARWIN)
        Q_UNUSED(profileId)
        Q_UNUSED(peer)
        paranoia_macos_show_message_count(static_cast<unsigned long long>(count));
#else
        Q_UNUSED(count)
        Q_UNUSED(profileId)
        Q_UNUSED(peer)
#endif
    }

    NotificationTarget takeOpenTargetFromNotification()
    {
        NotificationTarget target;
#if defined(Q_OS_ANDROID)
        const QJniObject context = androidContext();
        if (!context.isValid()) return target;
        const QJniObject result = QJniObject::callStaticObjectMethod(
            "app/paranoia/client/ParanoiaForegroundService", "takeOpenTarget",
            "(Landroid/content/Context;)Ljava/lang/String;", context.object<jobject>());
        const QString encoded = result.isValid() ? result.toString() : QString();
        const qsizetype separator = encoded.indexOf(QLatin1Char('\n'));
        if (separator < 0) {
            target.peer = encoded;
        } else {
            target.profileId = encoded.left(separator);
            target.peer      = encoded.mid(separator + 1);
        }
#endif
        return target;
    }

    QString takeOpenPeerFromNotification()
    {
        return takeOpenTargetFromNotification().peer;
    }
}

extern "C" void paranoia_platform_trigger_background_poll() { PlatformNotifications::triggerBackgroundPoll(); }

#if defined(Q_OS_ANDROID)
extern "C" JNIEXPORT void JNICALL
Java_app_paranoia_client_ParanoiaForegroundService_triggerBackgroundPollNative(JNIEnv *, jclass)
{
    PlatformNotifications::triggerBackgroundPoll();
}
#endif
