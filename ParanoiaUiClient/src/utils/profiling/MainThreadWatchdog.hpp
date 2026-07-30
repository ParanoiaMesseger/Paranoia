#pragma once
#include <QObject>

#include <atomic>

class QThread;
class QTimer;

// Сторож GUI-потока. На GUI-потоке тикает QTimer, обновляя «пульс» (монотонные
// мс). Отдельный фоновый поток раз в heartbeatMs смотрит, как давно был пульс:
// если дольше stallMs — GUI-поток заблокирован (синхронный FFI/крипто/дисковый
// IO/тяжёлый QML-binding). Это первопричина фризов и дёрганых анимаций в
// мессенджере, который ходит в Rust-FFI из GUI-потока.
//
// Логирует начало столла и длительность по выходу. На Linux (glibc) опционально
// снимает стек GUI-потока в момент столла (realtime-сигнал + backtrace) —
// показывает точное место блокировки. Включается через captureStacks.
//
// Активен только в сборке PARANOIA_PROFILING под рантайм-флагом PARANOIA_PROFILE.
class MainThreadWatchdog : public QObject
{
    Q_OBJECT
public:
    explicit MainThreadWatchdog(QObject *parent = nullptr);
    ~MainThreadWatchdog() override;

    // heartbeatMs — период опроса сторожевым потоком; stallMs — порог, после
    // которого молчание GUI-потока считается столлом; captureStacks — снимать
    // ли стек GUI-потока (Linux/glibc).
    void start(int heartbeatMs = 50, int stallMs = 250, bool captureStacks = true);
    void stop();

    quint64 stallCount() const { return m_stalls.load(); }

private:
    QTimer  *m_heartbeat = nullptr;
    QThread *m_thread    = nullptr;

    std::atomic<qint64>  m_lastBeatMs{0};   // монотонные мс последнего пульса GUI
    std::atomic<quint64> m_stalls{0};
    std::atomic<bool>    m_running{false};
};
