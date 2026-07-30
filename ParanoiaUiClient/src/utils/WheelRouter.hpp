#pragma once

#include <QObject>
#include <QPointF>
#include <QRectF>

// Приложение-уровневый роутер колеса мыши.
//
// Зачем C++: QML WheelHandler НЕ получает hi-res/сглаженные (pixelDelta) события
// колеса, когда рядом Flickable — тот съедает их раньше. На Wayland/libinput
// (обычная мышь) из-за этого не работали НИ листание тем колесом, НИ Ctrl+зум в
// полноэкранном чтении (репро Иванова: в диагностической сборке QML-обработчики
// не логировали вообще — «Строк нет»). Фильтр на qApp видит ВСЕ колёсные события
// до доставки в окно → надёжно на любой платформе и типе колеса.
class WheelRouter : public QObject
{
    Q_OBJECT
public:
    explicit WheelRouter(QObject *parent = nullptr);

    // Из QML: активен ли полноэкранный ридер (тогда Ctrl+колесо → зум).
    Q_INVOKABLE void setReaderActive(bool active);
    // Из QML: экранный прямоугольник полоски тем (колесо над ним → листание тем).
    // Пустой/невалидный — листание выключено (вне чата/нет тем).
    Q_INVOKABLE void setTopicBarRect(const QRectF &screenRect);

signals:
    void zoomStep(int dir);    // +1 приблизить, -1 отдалить
    void topicStep(int dir);   // +1 следующая тема, -1 предыдущая

protected:
    bool eventFilter(QObject *watched, QEvent *event) override;

private:
    bool   m_readerActive = false;
    QRectF m_topicBarRect;
    qreal  m_zoomAccum  = 0;   // аккумулятор дельты (шаг на «щелчок» = 120)
    qreal  m_topicAccum = 0;
};
