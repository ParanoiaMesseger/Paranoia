#include "VideoSink.hpp"

#include <QMetaObject>
#include <QVideoFrameFormat>
#include <cstring>

namespace paranoia::voip
{

    VideoSinkBridge::VideoSinkBridge(QObject *parent) : QObject(parent) {}

    VideoSinkBridge::~VideoSinkBridge() = default;

    void VideoSinkBridge::setI420Frame(QByteArray i420, int width, int height)
    {
        // Маршалим в main thread (QVideoSink::setVideoFrame не thread-safe).
        QMetaObject::invokeMethod(this, "applyI420", Qt::QueuedConnection, Q_ARG(QByteArray, i420), Q_ARG(int, width),
                                  Q_ARG(int, height));
    }

    void VideoSinkBridge::applyI420(const QByteArray &i420, int width, int height)
    {
        if (!sink_) return;
        const int expected = width * height * 3 / 2;
        if (i420.size() != expected || width <= 0 || height <= 0) { return; }
        QVideoFrameFormat fmt(QSize(width, height), QVideoFrameFormat::Format_YUV420P);
        QVideoFrame vf(fmt);
        if (!vf.map(QVideoFrame::WriteOnly)) { return; }
        // Копируем плоскости. Источник — линейный буфер без padding'а; цель —
        // bytesPerLine, которые Qt может выровнять.
        const uint8_t *src   = reinterpret_cast<const uint8_t *>(i420.constData());
        const uint8_t *src_y = src;
        const uint8_t *src_u = src_y + width * height;
        const uint8_t *src_v = src_u + (width / 2) * (height / 2);

        uint8_t *dy  = vf.bits(0);
        uint8_t *du  = vf.bits(1);
        uint8_t *dv  = vf.bits(2);
        const int sy = vf.bytesPerLine(0);
        const int su = vf.bytesPerLine(1);
        const int sv = vf.bytesPerLine(2);

        for (int r = 0; r < height; ++r) { std::memcpy(dy + r * sy, src_y + r * width, width); }
        for (int r = 0; r < height / 2; ++r) {
            std::memcpy(du + r * su, src_u + r * (width / 2), width / 2);
            std::memcpy(dv + r * sv, src_v + r * (width / 2), width / 2);
        }
        vf.unmap();
        sink_->setVideoFrame(vf);
    }

} // namespace paranoia::voip
