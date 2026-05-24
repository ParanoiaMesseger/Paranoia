#include "Logging.hpp"

#include <QCoreApplication>
#include <QDebug>
#include <QQmlError>
#include <QQmlApplicationEngine>

#if PARANOIA_BETA_LOGGING
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QMutex>
#include <QStandardPaths>
#include <QTextStream>
namespace
{
    QFile gLogFile;
    QMutex gLogMutex;
    void fileMessageHandler(QtMsgType type, const QMessageLogContext &, const QString &msg)
    {
        QMutexLocker lock(&gLogMutex);
        if (!gLogFile.isOpen()) return;
        const char *level = "DBG";
        switch (type) {
            case QtInfoMsg: level = "INF"; break;
            case QtWarningMsg: level = "WRN"; break;
            case QtCriticalMsg: level = "CRT"; break;
            case QtFatalMsg: level = "FTL"; break;
            default: break;
        }
        QTextStream(&gLogFile) << QDateTime::currentDateTime().toString("hh:mm:ss.zzz") << " [" << level << "] " << msg
                               << "\n";
        gLogFile.flush();
        if (type == QtFatalMsg) abort();
    }
}
#endif

Logging::Logging()
{
#if PARANOIA_BETA_LOGGING
    QString logDir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
#if defined(OS_ANDROID)
    // External app dir (/sdcard/Android/data/<pkg>/files/) is ADB-accessible without root
    QJniObject ctx = QNativeInterface::QAndroidApplication::context();
    QJniObject extDir =
        ctx.callObjectMethod("getExternalFilesDir", "(Ljava/lang/String;)Ljava/io/File;", jobject(nullptr));
    if (extDir.isValid()) logDir = extDir.callObjectMethod<jstring>("getAbsolutePath").toString();
#endif
    const QString logPath = logDir + QStringLiteral("/paranoia_debug.log");
    QDir().mkpath(logDir);
    gLogFile.setFileName(logPath);
    if (gLogFile.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) {
        qInstallMessageHandler(fileMessageHandler);
        qInfo().noquote() << "=== Paranoia" << APP_VERSION << "log started ===";
        qInfo().noquote() << "Log file:" << logPath;
        qInfo().noquote() << "VirtualKeyboard:" << (PARANOIA_HAS_QT_VIRTUAL_KEYBOARD ? "enabled" : "disabled");
    }
#endif
}

void Logging::connectEngine(QQmlApplicationEngine *engine)
{
    engine_ = engine;
    connect(engine, &QQmlApplicationEngine::warnings, this, &Logging::qmlWarnings);
    connect(engine, &QQmlApplicationEngine::objectCreationFailed, this, &Logging::objectCreationFailed,
            Qt::QueuedConnection);
}

void Logging::qmlWarnings(const QList<QQmlError> &warnings)
{
    for (const auto &warning : warnings) qWarning().noquote() << warning.toString();
}

void Logging::objectCreationFailed()
{
    qCritical().noquote() << "QML root object creation failed. Import paths:" << engine_->importPathList().join(", ");
    QCoreApplication::exit(-1);
}
