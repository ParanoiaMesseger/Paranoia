#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQmlError>
#include <QDebug>
#if defined(Q_OS_ANDROID)
#include <QDir>
#include <QStandardPaths>
#endif
#include "adminStorage.hpp"
#include "ClientBackend.h"

int main(int argc, char *argv[])
{
    QCoreApplication::setOrganizationName("Paranoia");
    QCoreApplication::setApplicationName("ParanoiaUiClient");

    QGuiApplication app(argc, argv);

#if defined(Q_OS_ANDROID)
    const QString dataDir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    if (!dataDir.isEmpty() && QDir().mkpath(dataDir) && QDir::setCurrent(dataDir)) {
        qInfo().noquote() << "Using app data directory:" << dataDir;
    } else {
        qWarning().noquote() << "Failed to switch to app data directory:" << dataDir;
    }
#endif

    admin::Admin::initAdmins();

    ClientBackend backend;

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("Backend", &backend);
    engine.rootContext()->setContextProperty("appVersion", APP_VERSION);

    QObject::connect(&engine, &QQmlApplicationEngine::warnings, &app,
        [](const QList<QQmlError> &warnings) {
            for (const auto &warning : warnings)
                qWarning().noquote() << warning.toString();
        });

    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreationFailed, &app,
        [&engine]() {
            qCritical().noquote() << "QML root object creation failed. Import paths:"
                                  << engine.importPathList().join(", ");
            QCoreApplication::exit(-1);
        }, Qt::QueuedConnection);

    engine.loadFromModule("ParanoiaUiClient", "Main");
    if (engine.rootObjects().isEmpty()) {
        qCritical().noquote() << "QML root object is empty after loadFromModule. Import paths:"
                              << engine.importPathList().join(", ");
    }

    return app.exec();
}
