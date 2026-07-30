#include "ProfilingHarness.hpp"

#include "FrameProfiler.hpp"
#include "MainThreadWatchdog.hpp"

#include <QDateTime>
#include <QDir>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQuickWindow>
#include <QStandardPaths>
#include <QtGlobal>

#if defined(Q_OS_UNIX)
#include <QSocketNotifier>
#include <csignal>
#include <unistd.h>
#endif

namespace
{
#if defined(Q_OS_UNIX)
// Self-pipe: обработчик сигнала пишет байт в pipe, QSocketNotifier подхватывает
// его в цикле событий и инициирует чистый выход (aboutToQuit → flush отчётов).
// Профайлинг-сессии часто гасят Ctrl+C/kill — без этого CSV кадров терялся бы.
int g_sigFd[2] = {-1, -1};
void unixSignalHandler(int)
{
    const char c = 1;
    const ssize_t w = ::write(g_sigFd[1], &c, 1);
    (void) w;
}
void installGracefulQuit(QGuiApplication *app)
{
    if (::pipe(g_sigFd) != 0) return;
    auto *sn = new QSocketNotifier(g_sigFd[0], QSocketNotifier::Read, app);
    QObject::connect(sn, &QSocketNotifier::activated, app, [app] { app->quit(); });
    struct sigaction sa;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags   = SA_RESTART;
    sa.sa_handler = unixSignalHandler;
    sigaction(SIGINT, &sa, nullptr);
    sigaction(SIGTERM, &sa, nullptr);
}
#endif

// env как bool: пусто/«0»/«false»/«no» → false, иначе → true. def — значение,
// если переменная не задана вовсе.
bool envFlag(const char *name, bool def)
{
    if (qEnvironmentVariableIsEmpty(name)) return def;
    const QByteArray v = qgetenv(name).trimmed().toLower();
    return !(v == "0" || v == "false" || v == "no" || v == "off");
}

QQuickWindow *findRootWindow(QQmlApplicationEngine *engine)
{
    const auto roots = engine->rootObjects();
    for (QObject *o : roots)
        if (auto *w = qobject_cast<QQuickWindow *>(o)) return w;
    return nullptr;
}
}   // namespace

namespace paranoia::profiling
{
void installIfRequested(QGuiApplication *app, QQmlApplicationEngine *engine)
{
    if (!envFlag("PARANOIA_PROFILE", false)) return;   // спящий по умолчанию

    QString outDir = qEnvironmentVariable("PARANOIA_PROFILE_DIR");
    if (outDir.isEmpty())
        outDir = QStandardPaths::writableLocation(QStandardPaths::CacheLocation)
                 + QStringLiteral("/profiling");
    QDir().mkpath(outDir);
    const QString stamp = QDateTime::currentDateTime().toString(QStringLiteral("yyyyMMdd-HHmmss"));

    qInfo().noquote() << "[profiling] harness ON, reports →" << outDir;

#if defined(Q_OS_UNIX)
    installGracefulQuit(app);   // Ctrl+C/SIGTERM → чистый выход со сбросом отчётов
#endif

    if (envFlag("PARANOIA_PROFILE_FRAMES", true)) {
        if (QQuickWindow *win = findRootWindow(engine)) {
            auto        *fp      = new FrameProfiler(app);
            const int    idleMs  = qEnvironmentVariableIntValue("PARANOIA_PROFILE_IDLE_MS");
            fp->attach(win, /*jankFactor=*/1.5, /*idleCeilingMs=*/idleMs > 0 ? idleMs : 100.0);
            const QString csv = outDir + QStringLiteral("/frames-") + stamp + QStringLiteral(".csv");
            QObject::connect(app, &QGuiApplication::aboutToQuit, fp, [fp, csv] { fp->flush(csv); });
        } else {
            qWarning("[profiling] FrameProfiler: root QQuickWindow not found, skipping");
        }
    }

    if (envFlag("PARANOIA_PROFILE_WATCHDOG", true)) {
        const int stallMs = qEnvironmentVariableIntValue("PARANOIA_PROFILE_STALL_MS");
        auto     *wd      = new MainThreadWatchdog(app);
        wd->start(/*heartbeatMs=*/50, /*stallMs=*/stallMs > 0 ? stallMs : 250,
                  /*captureStacks=*/envFlag("PARANOIA_PROFILE_STACKS", true));
        QObject::connect(app, &QGuiApplication::aboutToQuit, wd, [wd] {
            qInfo("[profiling] watchdog: %llu GUI stall(s) over session",
                  static_cast<unsigned long long>(wd->stallCount()));
            wd->stop();
        });
    }
}
}   // namespace paranoia::profiling
