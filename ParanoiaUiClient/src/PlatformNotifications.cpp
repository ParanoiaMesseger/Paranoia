#include "PlatformNotifications.hpp"

#include <mutex>

#if defined(Q_OS_ANDROID)
#include <QJniObject>
#include <QCoreApplication>
#include <jni.h>
#endif

#if defined(Q_OS_IOS)
extern "C" void paranoia_ios_register_background_tasks();
extern "C" void paranoia_ios_schedule_background_polling();
extern "C" void paranoia_ios_cancel_background_polling();
extern "C" void paranoia_ios_show_message_count(unsigned long long count);
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
#if defined(Q_OS_IOS)
        paranoia_ios_register_background_tasks();
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
        if (callback) callback();
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

    void showMessageCount(quint64 count, const QString &peer)
    {
#if defined(Q_OS_ANDROID)
        const QJniObject context = androidContext();
        if (!context.isValid()) return;
        const QJniObject javaPeer = QJniObject::fromString(peer);
        QJniObject::callStaticMethod<void>("app/paranoia/client/ParanoiaForegroundService", "showNewMessages",
                                           "(Landroid/content/Context;JLjava/lang/String;)V", context.object<jobject>(),
                                           static_cast<jlong>(count), javaPeer.object<jstring>());
#elif defined(Q_OS_IOS)
        Q_UNUSED(peer)
        paranoia_ios_show_message_count(static_cast<unsigned long long>(count));
#else
        Q_UNUSED(count)
        Q_UNUSED(peer)
#endif
    }

    QString takeOpenPeerFromNotification()
    {
#if defined(Q_OS_ANDROID)
        const QJniObject context = androidContext();
        if (!context.isValid()) return {};
        const QJniObject result = QJniObject::callStaticObjectMethod(
            "app/paranoia/client/ParanoiaForegroundService", "takeOpenPeer",
            "(Landroid/content/Context;)Ljava/lang/String;", context.object<jobject>());
        return result.isValid() ? result.toString() : QString();
#else
        return {};
#endif
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
