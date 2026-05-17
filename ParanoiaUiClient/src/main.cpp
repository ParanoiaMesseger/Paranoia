#include "platform/DesktopTray.hpp"
#include "utils/Logging.hpp"

#include <QByteArray>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQmlError>
#include <QWindow>
#include <QDebug>
#include <QStandardPaths>
#include <QDir>
#include <QFile>
#include <QStyleHints>
#if defined(DESKTOP_OS)
#include <QApplication>
#else
#include <QGuiApplication>
#endif
#if defined(OS_ANDROID)
#include <QCoreApplication>
#include <QJniEnvironment>
#include <QJniObject>
#include <ParanoiaFFI>
#endif
#include "utils/adminStorage.hpp"
#include "backend/ChatBackend.hpp"
#include "backend/MainBackend.hpp"
#include "backend/NotificationCoordinator.hpp"
#include "backend/VersionInfoBackend.hpp"
#include "platform/PlatformNotifications.hpp"
#include "spell/SpellChecker.hpp"

#if PARANOIA_HAS_VOIP
#include "voip/VoipSystem.hpp"
#endif

#ifdef OS_ANDROID
namespace
{
    bool initAndroidTlsVerifier()
    {
        QJniEnvironment env;
        const auto context = QNativeInterface::QAndroidApplication::context();
        if (paranoia_android_init(env.jniEnv(), context.object<jobject>()) == 0) return true;
        qCritical().noquote() << "Failed to initialize Android TLS verifier:" << ParanoiaFFI::last_error();
        return false;
    }
}
#endif

int main(int argc, char *argv[])
{
    QCoreApplication::setOrganizationName("Paranoia");
    QCoreApplication::setApplicationName("ParanoiaUiClient");
    QCoreApplication::setApplicationVersion(APP_VERSION);
#if defined(Q_OS_ANDROID) || defined(Q_OS_IOS)
    qputenv("QT_IM_MODULE", QByteArrayLiteral("qtvirtualkeyboard"));
    qputenv("QT_VIRTUALKEYBOARD_STYLE", QByteArrayLiteral("Paranoia"));
    QGuiApplication::styleHints()->setMousePressAndHoldInterval(300);
#endif
#if defined(Q_OS_UNIX) && !defined(Q_OS_DARWIN) && !defined(Q_OS_ANDROID)
    QGuiApplication::setDesktopFileName(QStringLiteral("app.paranoia.client"));
#endif

#if PARANOIA_DESKTOP_TRAY
    QApplication app(argc, argv);
    app.setQuitOnLastWindowClosed(false);
#else
    QGuiApplication app(argc, argv);
#endif
    app.setWindowIcon(QIcon(QStringLiteral(":/logo_symbol.svg")));

#if defined(Q_OS_ANDROID) || defined(Q_OS_IOS)
    const QString dataDir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    if (!dataDir.isEmpty() && QDir().mkpath(dataDir) && QDir::setCurrent(dataDir))
        qInfo().noquote() << "Using app data directory:" << dataDir;
    else
        qWarning().noquote() << "Failed to switch to app data directory:" << dataDir;
#endif

#if defined(Q_OS_ANDROID)
    if (!initAndroidTlsVerifier()) return -1;
#endif

#if PARANOIA_HAS_QT_VIRTUAL_KEYBOARD
    const QString hunspellDataPath = SpellChecker::prepareBundledDictionaries();
    if (!hunspellDataPath.isEmpty()) {
        QByteArray envValue       = QFile::encodeName(hunspellDataPath);
        const QByteArray existing = qgetenv("QT_VIRTUALKEYBOARD_HUNSPELL_DATA_PATH");
        if (!existing.isEmpty() && existing != envValue) {
#if defined(OS_WIN)
            envValue += envValue + ";" + existing;
#else
            envValue = envValue + ":" + existing;
#endif
        }
        qputenv("QT_VIRTUALKEYBOARD_HUNSPELL_DATA_PATH", envValue);
    }
#endif

    Logging logging;
    admin::Admin::initAdmins();
    PlatformNotifications::registerBackgroundTasks();
    NotificationCoordinator notifications;
    MainBackend backend(notifications);
    ChatBackend chatBackend;
    VersionInfoBackend versionInfoBackend;
    // Cross-backend wiring
    QObject::connect(&chatBackend, &ChatBackend::activePeerChanged, &notifications,
                     &NotificationCoordinator::onActivePeerChanged);
    QObject::connect(&chatBackend, &ChatBackend::peerMessagesRead, &notifications,
                     &NotificationCoordinator::onPeerMessagesRead);
    QObject::connect(&chatBackend, &ChatBackend::backgroundMessagesReceived, &notifications,
                     &NotificationCoordinator::onBackgroundMessagesReceived);
    QObject::connect(&notifications, &NotificationCoordinator::networkRestored, &chatBackend,
                     &ChatBackend::onNetworkRestored);
    QObject::connect(&notifications, &NotificationCoordinator::sessionReset, &chatBackend,
                     &ChatBackend::onSessionReset);
    QObject::connect(&backend, &MainBackend::dialogRemoved, &chatBackend, &ChatBackend::onDialogRemoved);
    QObject::connect(&backend, &MainBackend::sessionReset, &chatBackend, &ChatBackend::onSessionReset);

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("Backend", &backend);
    engine.rootContext()->setContextProperty("Chat", &chatBackend);
    engine.rootContext()->setContextProperty("Notifications", &notifications);
    engine.rootContext()->setContextProperty("VersionInfo", &versionInfoBackend);
    engine.rootContext()->setContextProperty("VirtualKeyboardAvailable", PARANOIA_HAS_QT_VIRTUAL_KEYBOARD != 0);
    engine.rootContext()->setContextProperty("MultimediaAvailable", PARANOIA_HAS_QT_MULTIMEDIA != 0);
    engine.rootContext()->setContextProperty("VoIPAvailable", PARANOIA_HAS_VOIP != 0);
    engine.rootContext()->setContextProperty("VideoAvailable", PARANOIA_HAS_VIDEO != 0);
    engine.rootContext()->setContextProperty("DesktopTrayEnabled", DesktopTray::desktopTrayEnabled());
#if PARANOIA_HAS_VOIP
    paranoia::voip::VoipSystem voipSystem(engine, backend);
#endif
    logging.connectEngine(&engine);
    engine.loadFromModule("ParanoiaUiClient", "Main");
    if (engine.rootObjects().isEmpty())
        qCritical().noquote() << "QML root object is empty after loadFromModule. Import paths:"
                              << engine.importPathList().join(", ");
    DesktopTray desktopTray(engine);
    QObject::connect(&notifications, &NotificationCoordinator::notificationAvailable, &desktopTray,
                     &DesktopTray::notificationAvailable);
    return app.exec();
}
