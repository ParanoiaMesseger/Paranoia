#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include "adminStorage.hpp"
#include "ClientBackend.h"

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);

    admin::Admin::initAdmins();

    ClientBackend backend;

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("Backend", &backend);

    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreationFailed, &app,
        []() { QCoreApplication::exit(-1); }, Qt::QueuedConnection);

    engine.load(QUrl(QStringLiteral("qrc:/qt/qml/ParanoiaUiClient/Main.qml")));
    return app.exec();
}
