#include "MainThreadWatchdog.hpp"

#include <QThread>
#include <QTimer>
#include <QtGlobal>

#include <chrono>

// Снимок стека GUI-потока доступен только на Linux с glibc (execinfo).
#if defined(Q_OS_LINUX) && defined(__GLIBC__)
#define PARANOIA_WATCHDOG_BACKTRACE 1
#include <csignal>
#include <execinfo.h>
#include <pthread.h>
#include <unistd.h>
#else
#define PARANOIA_WATCHDOG_BACKTRACE 0
#endif

namespace {

inline qint64 nowMs()
{
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

#if PARANOIA_WATCHDOG_BACKTRACE
// pthread GUI-потока и номер realtime-сигнала для снятия его стека. Сам снимок
// делается в обработчике сигнала по async-signal-safe пути: backtrace() в
// локальный буфер + backtrace_symbols_fd() напрямую в STDERR. backtrace
// прогревается на старте, чтобы первый вызов в хендлере не ушёл в ленивую
// загрузку libgcc (не async-signal-safe).
pthread_t g_guiThread = 0;
int       g_sig       = 0;

void stackSignalHandler(int)
{
    void      *frames[64];
    const int  n = backtrace(frames, 64);
    const char hdr[] = "\n[profiling] === GUI thread stack at stall ===\n";
    const ssize_t w = ::write(STDERR_FILENO, hdr, sizeof(hdr) - 1);
    (void) w;
    backtrace_symbols_fd(frames, n, STDERR_FILENO);
}
#endif

}   // namespace

MainThreadWatchdog::MainThreadWatchdog(QObject *parent) : QObject(parent) {}

MainThreadWatchdog::~MainThreadWatchdog()
{
    stop();
}

void MainThreadWatchdog::start(int heartbeatMs, int stallMs, bool captureStacks)
{
    if (m_running.load()) return;

    m_lastBeatMs.store(nowMs());

    // Пульс на GUI-потоке: пока цикл событий жив, таймер регулярно обновляет
    // отметку. Заблокированный GUI-поток таймер не обработает → отметка стареет.
    m_heartbeat = new QTimer(this);
    m_heartbeat->setTimerType(Qt::PreciseTimer);
    m_heartbeat->setInterval(qMax(10, heartbeatMs / 2));
    connect(m_heartbeat, &QTimer::timeout, this, [this] { m_lastBeatMs.store(nowMs()); });
    m_heartbeat->start();

#if PARANOIA_WATCHDOG_BACKTRACE
    const bool stacks = captureStacks;
    if (stacks) {
        g_guiThread = pthread_self();
        g_sig       = SIGRTMIN + 6;
        struct sigaction sa;
        sigemptyset(&sa.sa_mask);
        sa.sa_flags   = SA_RESTART;
        sa.sa_handler = stackSignalHandler;
        sigaction(g_sig, &sa, nullptr);
        // Прогрев backtrace (ленивая загрузка libgcc вне обработчика).
        void     *warm[4];
        const int wn = backtrace(warm, 4);
        (void) wn;
    }
#else
    const bool stacks = false;
    Q_UNUSED(captureStacks)
#endif

    m_running.store(true);

    // Сторожевой поток: тугой цикл опроса, без своего цикла событий.
    m_thread = QThread::create([this, heartbeatMs, stallMs, stacks] {
        bool   inStall    = false;
        qint64 stallStart = 0;
        while (m_running.load()) {
            QThread::msleep(static_cast<unsigned long>(qMax(5, heartbeatMs)));
            const qint64 gap = nowMs() - m_lastBeatMs.load();
            if (gap >= stallMs) {
                if (!inStall) {
                    inStall    = true;
                    stallStart = nowMs();
                    m_stalls.fetch_add(1);
                    qWarning("[profiling] GUI stall: blocked >%lld ms", static_cast<long long>(gap));
#if PARANOIA_WATCHDOG_BACKTRACE
                    if (stacks && g_guiThread)
                        pthread_kill(g_guiThread, g_sig);
#endif
                }
            } else if (inStall) {
                inStall = false;
                qWarning("[profiling] GUI resumed after ~%lld ms stall",
                         static_cast<long long>(nowMs() - stallStart));
            }
        }
    });
    m_thread->setObjectName(QStringLiteral("ParanoiaWatchdog"));
    m_thread->start();

    qInfo("[profiling] MainThreadWatchdog: heartbeat=%dms stall>=%dms stacks=%d", heartbeatMs,
          stallMs, stacks ? 1 : 0);
}

void MainThreadWatchdog::stop()
{
    if (!m_running.exchange(false)) return;
    if (m_heartbeat) {
        m_heartbeat->stop();
        m_heartbeat->deleteLater();
        m_heartbeat = nullptr;
    }
    if (m_thread) {
        m_thread->wait(2000);
        delete m_thread;
        m_thread = nullptr;
    }
}
