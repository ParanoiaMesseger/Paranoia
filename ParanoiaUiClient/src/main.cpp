#include <QGuiApplication>
#include <QIcon>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQmlError>
#include <QDebug>
#if defined(Q_OS_ANDROID)
#include <QCoreApplication>
#include <QDir>
#include <QJniEnvironment>
#include <QStandardPaths>
#include <paranoia_lib.h>
#endif
#include "adminStorage.hpp"
#include "ClientBackend.hpp"

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
#if defined(Q_OS_UNIX) && !defined(Q_OS_DARWIN) && !defined(Q_OS_ANDROID)
    QGuiApplication::setDesktopFileName(QStringLiteral("app.paranoia.client"));
#endif

    QGuiApplication app(argc, argv);
    app.setWindowIcon(QIcon(QStringLiteral(":/logo_symbol.svg")));

#if defined(Q_OS_ANDROID)
    if (!initAndroidTlsVerifier()) return -1;
    const QString dataDir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    if (!dataDir.isEmpty() && QDir().mkpath(dataDir) && QDir::setCurrent(dataDir))
        qInfo().noquote() << "Using app data directory:" << dataDir;
    else
        qWarning().noquote() << "Failed to switch to app data directory:" << dataDir;
#endif

    admin::Admin::initAdmins();
    ClientBackend backend;
    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("Backend", &backend);
    QObject::connect(&engine, &QQmlApplicationEngine::warnings, &app, [](const QList<QQmlError> &warnings) {
        for (const auto &warning : warnings) qWarning().noquote() << warning.toString();
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
    return app.exec();
}
