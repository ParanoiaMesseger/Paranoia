#include "WheelRouter.hpp"

#include <QEvent>
#include <QGuiApplication>
#include <QWheelEvent>

WheelRouter::WheelRouter(QObject *parent) : QObject(parent)
{
    if (qApp) qApp->installEventFilter(this);
}

void WheelRouter::setReaderActive(bool active)
{
    m_readerActive = active;
    m_zoomAccum    = 0;
}

void WheelRouter::setTopicBarRect(const QRectF &screenRect)
{
    m_topicBarRect = screenRect;
    m_topicAccum   = 0;
}

bool WheelRouter::eventFilter(QObject *watched, QEvent *event)
{
    if (event->type() != QEvent::Wheel) return QObject::eventFilter(watched, event);

    auto *we = static_cast<QWheelEvent *>(event);
    // Нормализуем дельту: обычная мышь — angleDelta (±120 на щелчок); hi-res/
    // сглаженный скролл (тачпад, современные мыши на libinput) — часто angleDelta.y==0
    // и только pixelDelta. Берём то, что есть; pixelDelta масштабируем к «щелчкам».
    qreal d = we->angleDelta().y();
    if (d == 0) d = we->pixelDelta().y() * 4;
    if (d == 0) return QObject::eventFilter(watched, event);

    // Ctrl+колесо в полноэкранном чтении → зум (шаг на «щелчок» 120).
    if (m_readerActive && (we->modifiers() & Qt::ControlModifier)) {
        m_zoomAccum += d;
        while (m_zoomAccum >= 120) {
            emit zoomStep(1);
            m_zoomAccum -= 120;
        }
        while (m_zoomAccum <= -120) {
            emit zoomStep(-1);
            m_zoomAccum += 120;
        }
        return true;   // съедаем — Flickable ридера не прокручивается
    }

    // Колесо над полоской тем → листание тем (вниз = следующая). Только вне ридера.
    if (!m_readerActive && m_topicBarRect.isValid()
        && m_topicBarRect.contains(we->globalPosition())) {
        m_topicAccum += d;
        while (m_topicAccum <= -120) {
            emit topicStep(1);
            m_topicAccum += 120;
        }
        while (m_topicAccum >= 120) {
            emit topicStep(-1);
            m_topicAccum -= 120;
        }
        return true;   // съедаем — лента не прокручивается «под» переключением
    }

    return QObject::eventFilter(watched, event);
}
