#pragma once
#include <QElapsedTimer>
#include <QMutex>
#include <QObject>
#include <QString>
#include <QVector>

class QQuickWindow;

// Профайлер кадров рендера. Вешается на корневой QQuickWindow и на каждом
// frameSwapped() (render-поток) меряет интервал между предъявлениями кадров.
//
// ВАЖНО про интерпретацию: интервал между кадрами сам по себе НЕ отличает
// «кадр долго рендерился» от «UI простаивал, рендерить было нечего» — в обоих
// случаях интервал большой. Поэтому:
//   * «джанк» = пропуск дедлайна ВО ВРЕМЯ активности: интервал в диапазоне
//     (бюджет×jankFactor; idleCeiling]. Это и есть дёрганость анимации.
//   * «длинный гэп» = интервал > idleCeiling. Это ЛИБО простой (норм), ЛИБО
//     фриз GUI-потока. Отличить может только MainThreadWatchdog (он меряет
//     отзывчивость цикла событий). Поэтому гэпы считаются отдельно и НЕ
//     попадают в джанк/перцентили плавности — иначе max врёт на простое.
//
// По завершении пишет CSV всех интервалов (с классом ok/jank/gap) и печатает
// сводку: плавность по активным кадрам (mean/p50/p95/p99/max, %джанка) + число
// и максимум длинных гэпов со ссылкой на watchdog.
//
// Активен только в сборке PARANOIA_PROFILING под рантайм-флагом PARANOIA_PROFILE.
class FrameProfiler : public QObject
{
    Q_OBJECT
public:
    explicit FrameProfiler(QObject *parent = nullptr);

    // jankFactor — во сколько раз интервал должен превысить бюджет кадра, чтобы
    // считаться джанком. idleCeilingMs — порог, выше которого интервал трактуется
    // как длинный гэп (простой/фриз), а не джанк.
    void attach(QQuickWindow *window, double jankFactor = 1.5, double idleCeilingMs = 100.0);

    // Сбросить CSV сэмплов по пути csvPath и распечатать сводку в лог.
    void flush(const QString &csvPath);

private:
    void onFrameSwapped();   // вызывается на render-потоке (DirectConnection)

    QQuickWindow *m_window          = nullptr;
    double        m_frameBudgetMs   = 1000.0 / 60.0;
    double        m_jankThresholdMs = (1000.0 / 60.0) * 1.5;
    double        m_idleCeilingMs   = 100.0;

    QMutex          m_mutex;          // защищает поля ниже (пишутся с render-потока)
    QElapsedTimer   m_timer;
    qint64          m_lastNs = -1;
    QVector<double> m_intervalsMs;    // все интервалы между кадрами, мс (классификация — в flush)
};
