#include <QIcon>
#include <QByteArray>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQmlError>
#include <QWindow>
#include <QDebug>
#if defined(Q_OS_WIN) || (defined(Q_OS_UNIX) && !defined(Q_OS_DARWIN) && !defined(Q_OS_ANDROID))
#include <QAction>
#include <QApplication>
#include <QMenu>
#include <QSystemTrayIcon>
#define PARANOIA_DESKTOP_TRAY 1
#else
#include <QGuiApplication>
#define PARANOIA_DESKTOP_TRAY 0
#endif
#if defined(Q_OS_ANDROID)
#include <QCoreApplication>
#include <QDir>
#include <QJniEnvironment>
#include <QJniObject>
#include <QStandardPaths>
#include <ParanoiaFFI>
#endif
#include "utils/adminStorage.hpp"
#include "backend/ChatBackend.hpp"
#include "backend/MainBackend.hpp"
#include "platform/PlatformNotifications.hpp"

#ifndef PARANOIA_HAS_QT_VIRTUAL_KEYBOARD
#define PARANOIA_HAS_QT_VIRTUAL_KEYBOARD 0
#endif

#ifndef PARANOIA_HAS_QT_MULTIMEDIA
#define PARANOIA_HAS_QT_MULTIMEDIA 0
#endif

#ifndef PARANOIA_BETA_LOGGING
#define PARANOIA_BETA_LOGGING 0
#endif

#if PARANOIA_BETA_LOGGING
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QMutex>
#include <QStandardPaths>
#include <QTextStream>
namespace {
    QFile gLogFile;
    QMutex gLogMutex;
    void fileMessageHandler(QtMsgType type, const QMessageLogContext &, const QString &msg)
    {
        QMutexLocker lock(&gLogMutex);
        if (!gLogFile.isOpen()) return;
        const char *level = "DBG";
        switch (type) {
        case QtInfoMsg:     level = "INF"; break;
        case QtWarningMsg:  level = "WRN"; break;
        case QtCriticalMsg: level = "CRT"; break;
        case QtFatalMsg:    level = "FTL"; break;
        default: break;
        }
        QTextStream(&gLogFile) << QDateTime::currentDateTime().toString("hh:mm:ss.zzz")
                               << " [" << level << "] " << msg << "\n";
        gLogFile.flush();
        if (type == QtFatalMsg) abort();
    }
}
#endif

#if defined(Q_OS_ANDROID)
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

#if defined(Q_OS_ANDROID)
    if (!initAndroidTlsVerifier()) return -1;
    const QString dataDir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    if (!dataDir.isEmpty() && QDir().mkpath(dataDir) && QDir::setCurrent(dataDir))
        qInfo().noquote() << "Using app data directory:" << dataDir;
    else
        qWarning().noquote() << "Failed to switch to app data directory:" << dataDir;
#endif

#if PARANOIA_BETA_LOGGING
    {
        QString logDir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
#if defined(Q_OS_ANDROID)
        // External app dir (/sdcard/Android/data/<pkg>/files/) is ADB-accessible without root
        QJniObject ctx = QNativeInterface::QAndroidApplication::context();
        QJniObject extDir = ctx.callObjectMethod(
            "getExternalFilesDir", "(Ljava/lang/String;)Ljava/io/File;", jobject(nullptr));
        if (extDir.isValid())
            logDir = extDir.callObjectMethod<jstring>("getAbsolutePath").toString();
#endif
        const QString logPath = logDir + QStringLiteral("/paranoia_debug.log");
        QDir().mkpath(logDir);
        gLogFile.setFileName(logPath);
        if (gLogFile.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) {
            qInstallMessageHandler(fileMessageHandler);
            qInfo().noquote() << "=== Paranoia" << APP_VERSION << "log started ===";
            qInfo().noquote() << "Log file:" << logPath;
#if PARANOIA_HAS_QT_VIRTUAL_KEYBOARD
            qInfo().noquote() << "VirtualKeyboard: enabled, style=Paranoia";
#else
            qInfo().noquote() << "VirtualKeyboard: disabled";
#endif
        }
    }
#endif

    admin::Admin::initAdmins();
    PlatformNotifications::registerBackgroundTasks();
    MainBackend backend;
    ChatBackend chatBackend;
    // Cross-backend wiring
    QObject::connect(&chatBackend, &ChatBackend::activePeerChanged, &backend, &MainBackend::onActivePeerChanged);
    QObject::connect(&chatBackend, &ChatBackend::peerMessagesRead,  &backend, &MainBackend::onPeerMessagesRead);
    QObject::connect(&chatBackend, &ChatBackend::backgroundMessagesReceived, &backend,
                     &MainBackend::onBackgroundMessagesReceived);
    QObject::connect(&app, &QGuiApplication::applicationStateChanged, &chatBackend,
                     &ChatBackend::onApplicationStateChanged);
    QObject::connect(&backend, &MainBackend::networkRestored, &chatBackend, &ChatBackend::onNetworkRestored);
    QObject::connect(&backend, &MainBackend::dialogRemoved,   &chatBackend, &ChatBackend::onDialogRemoved);
    QObject::connect(&backend, &MainBackend::sessionReset,    &chatBackend, &ChatBackend::onSessionReset);
    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("Backend", &backend);
    engine.rootContext()->setContextProperty("Chat", &chatBackend);
    engine.rootContext()->setContextProperty("VirtualKeyboardAvailable", PARANOIA_HAS_QT_VIRTUAL_KEYBOARD != 0);
    engine.rootContext()->setContextProperty("MultimediaAvailable", PARANOIA_HAS_QT_MULTIMEDIA != 0);
#if PARANOIA_DESKTOP_TRAY
    const bool desktopTrayEnabled = QSystemTrayIcon::isSystemTrayAvailable();
#else
    const bool desktopTrayEnabled = false;
#endif
    engine.rootContext()->setContextProperty("DesktopTrayEnabled", desktopTrayEnabled);
    QObject::connect(&engine, &QQmlApplicationEngine::warnings, &app, [](const QList<QQmlError> &warnings) {
        for (const auto &warning : warnings) qWarning().noquote() << warning.toString();
    });
    QObject::connect(&backend, &MainBackend::notificationAvailable, &app,
                     [](quint64 count, const QString &profileId, const QString &peer) {
                         PlatformNotifications::showMessageCount(count, profileId, peer);
                     });
    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreationFailed, &app,
        [&engine]() {
            qCritical().noquote() << "QML root object creation failed. Import paths:"
                                  << engine.importPathList().join(", ");
            QCoreApplication::exit(-1);
        },
        Qt::QueuedConnection);
    engine.loadFromModule("ParanoiaUiClient", "Main");
    if (engine.rootObjects().isEmpty()) {
        qCritical().noquote() << "QML root object is empty after loadFromModule. Import paths:"
                              << engine.importPathList().join(", ");
    }
#if PARANOIA_DESKTOP_TRAY
    QSystemTrayIcon tray(QIcon(QStringLiteral(":/logo_symbol.svg")));
    QMenu trayMenu;
    QAction showAction(QStringLiteral("Открыть Paranoia"), &trayMenu);
    QAction quitAction(QStringLiteral("Выйти"), &trayMenu);
    trayMenu.addAction(&showAction);
    trayMenu.addSeparator();
    trayMenu.addAction(&quitAction);
    tray.setContextMenu(&trayMenu);

    auto showWindow = [&engine]() {
        if (engine.rootObjects().isEmpty()) return;
        if (auto *window = qobject_cast<QWindow *>(engine.rootObjects().first())) {
            window->show();
            window->raise();
            window->requestActivate();
        }
    };
    QObject::connect(&showAction, &QAction::triggered, &app, showWindow);
    QObject::connect(&quitAction, &QAction::triggered, &app, &QCoreApplication::quit);
    QObject::connect(&tray, &QSystemTrayIcon::activated, &app, [&](QSystemTrayIcon::ActivationReason reason) {
        if (reason == QSystemTrayIcon::Trigger || reason == QSystemTrayIcon::DoubleClick) showWindow();
    });
    QObject::connect(&backend, &MainBackend::notificationAvailable, &app,
                     [&](quint64 count, const QString &profileId, const QString &peer) {
                         Q_UNUSED(profileId)
                         Q_UNUSED(peer)
                         if (!tray.isVisible()) return;
                         tray.showMessage(QStringLiteral("Paranoia"), QStringLiteral("Новых сообщений: %1").arg(count),
                                          QSystemTrayIcon::Information, 10000);
                     });
    if (desktopTrayEnabled) tray.show();
#endif
    return app.exec();
}
