#include "FrameProfiler.hpp"

#include <QFile>
#include <QQuickWindow>
#include <QScreen>
#include <QTextStream>
#include <QtGlobal>

#include <algorithm>

FrameProfiler::FrameProfiler(QObject *parent) : QObject(parent) {}

void FrameProfiler::attach(QQuickWindow *window, double jankFactor, double idleCeilingMs)
{
    m_window = window;
    double hz = 60.0;
    if (window && window->screen() && window->screen()->refreshRate() > 1.0)
        hz = window->screen()->refreshRate();
    m_frameBudgetMs   = 1000.0 / hz;
    m_jankThresholdMs = m_frameBudgetMs * jankFactor;
    m_idleCeilingMs   = std::max(idleCeilingMs, m_jankThresholdMs * 1.5);
    m_timer.start();

    // frameSwapped эмитится с render-потока (threaded render loop). DirectConnection,
    // чтобы засечь сам момент swap'а, а не его постановку в очередь GUI-потока.
    // Все поля под m_mutex, т.к. слот выполняется на чужом потоке.
    connect(window, &QQuickWindow::frameSwapped, this, &FrameProfiler::onFrameSwapped,
            Qt::DirectConnection);

    qInfo("[profiling] FrameProfiler attached: refresh=%.1f Hz, budget=%.2f ms, jank>%.2f ms, gap>%.0f ms",
          hz, m_frameBudgetMs, m_jankThresholdMs, m_idleCeilingMs);
}

void FrameProfiler::onFrameSwapped()
{
    const qint64 ns = m_timer.nsecsElapsed();
    QMutexLocker lock(&m_mutex);
    if (m_lastNs >= 0) {
        const double ms = double(ns - m_lastNs) / 1.0e6;
        m_intervalsMs.append(ms);
        // Живой лог: гэпы и джанк помечаем по-разному, чтобы не путать простой с дёрганостью.
        if (ms > m_idleCeilingMs)
            qInfo("[profiling] long gap: %.0f ms (idle или фриз — сверь с watchdog)", ms);
        else if (ms > m_jankThresholdMs * 2.0)
            qWarning("[profiling] jank frame: %.1f ms (budget %.1f)", ms, m_frameBudgetMs);
    }
    m_lastNs = ns;
}

void FrameProfiler::flush(const QString &csvPath)
{
    QMutexLocker lock(&m_mutex);
    if (m_intervalsMs.isEmpty()) {
        qInfo("[profiling] FrameProfiler: no frames captured");
        return;
    }

    // Активные кадры (плавность) vs длинные гэпы (простой/фриз) — считаем раздельно.
    QVector<double> active;
    active.reserve(m_intervalsMs.size());
    quint64 janks    = 0;
    quint64 gaps     = 0;
    double  worstGap = 0.0;
    for (double v : m_intervalsMs) {
        if (v > m_idleCeilingMs) {
            ++gaps;
            if (v > worstGap) worstGap = v;
        } else {
            active.append(v);
            if (v > m_jankThresholdMs) ++janks;
        }
    }

    QFile f(csvPath);
    if (f.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) {
        QTextStream ts(&f);
        ts << "frame_index,interval_ms,class\n";
        for (int i = 0; i < m_intervalsMs.size(); ++i) {
            const double v   = m_intervalsMs[i];
            const char  *cls = v > m_idleCeilingMs ? "gap" : (v > m_jankThresholdMs ? "jank" : "ok");
            ts << i << ',' << QString::number(v, 'f', 3) << ',' << cls << '\n';
        }
        f.close();
    } else {
        qWarning().noquote() << "[profiling] cannot write frame CSV:" << csvPath;
    }

    if (active.isEmpty()) {
        qInfo("[profiling] frames=%lld: все интервалы — длинные гэпы (%llu), активных кадров нет",
              static_cast<long long>(m_intervalsMs.size()), static_cast<unsigned long long>(gaps));
        qInfo().noquote() << "[profiling] frame CSV:" << csvPath;
        return;
    }

    std::sort(active.begin(), active.end());
    const auto pct = [&](double p) {
        const int n   = active.size();
        const int idx = std::clamp(int(p / 100.0 * (n - 1)), 0, n - 1);
        return active[idx];
    };
    double sum = 0.0;
    for (double v : active) sum += v;
    const double mean    = sum / active.size();
    const double jankPct = 100.0 * double(janks) / double(active.size());

    qInfo("[profiling] плавность (активных кадров=%d, бюджет=%.2fms): mean=%.2f p50=%.2f p95=%.2f p99=%.2f max=%.2f джанк=%llu (%.1f%%)",
          int(active.size()), m_frameBudgetMs, mean, pct(50), pct(95), pct(99), active.last(),
          static_cast<unsigned long long>(janks), jankPct);
    qInfo("[profiling] длинных гэпов (>%.0fms)=%llu, макс=%.0fms — это простой ИЛИ фриз, сверь с watchdog",
          m_idleCeilingMs, static_cast<unsigned long long>(gaps), worstGap);
    qInfo().noquote() << "[profiling] frame CSV:" << csvPath;
}
