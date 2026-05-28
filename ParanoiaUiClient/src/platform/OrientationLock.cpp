#include "OrientationLock.hpp"

#if defined(Q_OS_ANDROID)
#include <QCoreApplication>
#include <QJniEnvironment>
#include <QJniObject>
#endif

#if defined(Q_OS_IOS)
namespace paranoia::platform
{
    // Реализованы в IosOrientationLock.mm.
    extern "C" void paranoia_ios_lock_orientation_portrait();
    extern "C" void paranoia_ios_unlock_orientation();
}
#endif

namespace paranoia::platform
{

    OrientationLock::OrientationLock(QObject *parent) : QObject(parent) {}

    void OrientationLock::lockPortrait()
    {
#if defined(Q_OS_ANDROID)
        QJniEnvironment env;
        const auto ctx = QNativeInterface::QAndroidApplication::context();
        if (!ctx.isValid()) return;
        QJniObject::callStaticMethod<void>("app/paranoia/client/ParanoiaAndroidUtils",
                                           "lockOrientationPortrait", "(Landroid/content/Context;Z)V",
                                           ctx.object<jobject>(), jboolean(JNI_TRUE));
        if (env->ExceptionCheck()) env->ExceptionClear();
#elif defined(Q_OS_IOS)
        paranoia_ios_lock_orientation_portrait();
#endif
    }

    void OrientationLock::unlock()
    {
#if defined(Q_OS_ANDROID)
        QJniEnvironment env;
        const auto ctx = QNativeInterface::QAndroidApplication::context();
        if (!ctx.isValid()) return;
        QJniObject::callStaticMethod<void>("app/paranoia/client/ParanoiaAndroidUtils",
                                           "lockOrientationPortrait", "(Landroid/content/Context;Z)V",
                                           ctx.object<jobject>(), jboolean(JNI_FALSE));
        if (env->ExceptionCheck()) env->ExceptionClear();
#elif defined(Q_OS_IOS)
        paranoia_ios_unlock_orientation();
#endif
    }

} // namespace paranoia::platform
