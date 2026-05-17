#include "VideoCapture.hpp"

#include <QCameraDevice>
#include <QImage>
#include <QMediaDevices>

#include "H264Codec.hpp"

extern "C" {
#include <libavutil/imgutils.h>
#include <libavutil/pixfmt.h>
#include <libswscale/swscale.h>
}

namespace paranoia::voip
{

    namespace
    {

        // Пер-инстанс SwsContext держим вне класса (мини-cache). Чтобы не плодить
        // контексты при изменении формата кадра, кешируем по (src_w, src_h, src_fmt).
        struct SwsCache {
            SwsContext *ctx = nullptr;
            int src_w = 0, src_h = 0;
            AVPixelFormat src_fmt = AV_PIX_FMT_NONE;
            ~SwsCache()
            {
                if (ctx) sws_freeContext(ctx);
            }
            SwsContext *get(int sw, int sh, AVPixelFormat sf, int dw, int dh)
            {
                if (ctx && sw == src_w && sh == src_h && sf == src_fmt) return ctx;
                if (ctx) {
                    sws_freeContext(ctx);
                    ctx = nullptr;
                }
                ctx = sws_getContext(sw, sh, sf, dw, dh, AV_PIX_FMT_YUV420P, SWS_BILINEAR, nullptr, nullptr, nullptr);
                if (ctx) {
                    src_w   = sw;
                    src_h   = sh;
                    src_fmt = sf;
                }
                return ctx;
            }
        };

        AVPixelFormat qtToAvPix(QVideoFrameFormat::PixelFormat qt)
        {
            switch (qt) {
                case QVideoFrameFormat::Format_YUV420P: return AV_PIX_FMT_YUV420P;
                case QVideoFrameFormat::Format_YV12: return AV_PIX_FMT_YUV420P; // обмен U/V обработаем
                case QVideoFrameFormat::Format_NV12: return AV_PIX_FMT_NV12;
                case QVideoFrameFormat::Format_NV21: return AV_PIX_FMT_NV21;
                case QVideoFrameFormat::Format_UYVY: return AV_PIX_FMT_UYVY422;
                case QVideoFrameFormat::Format_YUYV: return AV_PIX_FMT_YUYV422;
                case QVideoFrameFormat::Format_BGRA8888:
                case QVideoFrameFormat::Format_BGRX8888: return AV_PIX_FMT_BGRA;
                case QVideoFrameFormat::Format_ARGB8888:
                case QVideoFrameFormat::Format_XRGB8888: return AV_PIX_FMT_ARGB;
                case QVideoFrameFormat::Format_RGBA8888:
                case QVideoFrameFormat::Format_RGBX8888: return AV_PIX_FMT_RGBA;
                default: return AV_PIX_FMT_NONE;
            }
        }

    } // namespace

    VideoCapture::VideoCapture(QObject *parent)
        : QObject(parent), session_(std::make_unique<QMediaCaptureSession>(this)),
          sink_(std::make_unique<QVideoSink>(this))
    {
        connect(sink_.get(), &QVideoSink::videoFrameChanged, this, &VideoCapture::onVideoFrame);
        session_->setVideoSink(sink_.get());
    }

    VideoCapture::~VideoCapture() { stop(); }

    bool VideoCapture::start()
    {
        if (camera_) return true;
        const auto cams = QMediaDevices::videoInputs();
        if (cams.isEmpty()) {
            emit error(QStringLiteral("no camera devices"));
            return false;
        }
        // Предпочитаем фронталку (selfie), если в Description есть подсказка.
        QCameraDevice chosen = cams.first();
        for (const auto &c : cams) {
            if (c.position() == QCameraDevice::FrontFace) {
                chosen = c;
                break;
            }
        }
        camera_ = std::make_unique<QCamera>(chosen);
        // Подберём формат: ближайший к 720p30, желательно из YUV-семейства.
        QCameraFormat best;
        int best_score = -1;
        for (const auto &f : chosen.videoFormats()) {
            const auto fps  = f.maxFrameRate();
            const auto &res = f.resolution();
            if (res.width() <= 0 || res.height() <= 0) continue;
            const int dx   = std::abs(res.width() - VideoFormat::kWidth);
            const int dy   = std::abs(res.height() - VideoFormat::kHeight);
            const int dfps = static_cast<int>(std::abs(fps - VideoFormat::kFrameRate));
            const bool yuv = (f.pixelFormat() == QVideoFrameFormat::Format_YUV420P ||
                              f.pixelFormat() == QVideoFrameFormat::Format_NV12 ||
                              f.pixelFormat() == QVideoFrameFormat::Format_NV21 ||
                              f.pixelFormat() == QVideoFrameFormat::Format_YUYV ||
                              f.pixelFormat() == QVideoFrameFormat::Format_UYVY);
            // Хотим: маленькая разница по разрешению, маленькая разница по fps,
            // YUV-формат предпочтительнее (быстрее конвертится).
            int score = 100000 - (dx + dy) * 10 - dfps * 100;
            if (yuv) score += 5000;
            if (score > best_score) {
                best_score = score;
                best       = f;
            }
        }
        if (best.resolution().isValid()) { camera_->setCameraFormat(best); }
        session_->setCamera(camera_.get());
        // QCamera::start асинхронный: isActive() сразу после вызова почти
        // всегда false, активность приходит позже через сигналы. Не делаем
        // здесь sync-check — слушаем errorOccurred и считаем start() успешным,
        // если QCamera::error() не выставлен (это самый ранний sync-канал).
        connect(camera_.get(), &QCamera::errorOccurred, this, [this](QCamera::Error err, const QString &msg) {
            if (err == QCamera::NoError) return;
            emit error(
                QStringLiteral("camera error: %1").arg(msg.isEmpty() ? QStringLiteral("code %1").arg(int(err)) : msg));
        });
        camera_->start();
        if (camera_->error() != QCamera::NoError) {
            emit error(QStringLiteral("camera start failed: %1").arg(camera_->errorString()));
            return false;
        }
        return true;
    }

    void VideoCapture::stop()
    {
        if (camera_) {
            camera_->stop();
            camera_.reset();
        }
        first_frame_us_ = -1;
    }

    bool VideoCapture::isActive() const { return camera_ && camera_->isActive(); }

    void VideoCapture::onVideoFrame(const QVideoFrame &cf)
    {
        if (!cf.isValid()) return;

        // Дублируем кадр в preview-sink ДО конвертации — это бесплатно.
        if (preview_sink_) preview_sink_->setVideoFrame(cf);

        QVideoFrame frame = cf;
        if (!frame.map(QVideoFrame::ReadOnly)) { return; }
        const int sw               = frame.width();
        const int sh               = frame.height();
        const auto qtfmt           = frame.pixelFormat();
        const AVPixelFormat srcFmt = qtToAvPix(qtfmt);
        if (srcFmt == AV_PIX_FMT_NONE) {
            frame.unmap();
            return;
        }

        // Базовое время для pts (90 кГц). Используем wall clock в микросекундах
        // и масштабируем: pts_90k = (us - first_us) * 90000 / 1_000_000.
        const qint64 now_us = frame.startTime(); // microseconds since some epoch
        if (first_frame_us_ < 0 || now_us < 0) { first_frame_us_ = (now_us >= 0) ? now_us : 0; }
        const qint64 elapsed_us = (now_us >= 0) ? (now_us - first_frame_us_) : 0;
        const qint64 pts_90k    = (elapsed_us * 90 + 500) / 1000; // round

        const int dw = VideoFormat::kWidth;
        const int dh = VideoFormat::kHeight;

        // Готовим источник для swscale.
        uint8_t *src_data[4] = {nullptr, nullptr, nullptr, nullptr};
        int src_linesize[4]  = {0, 0, 0, 0};
        for (int p = 0; p < frame.planeCount(); ++p) {
            src_data[p]     = const_cast<uint8_t *>(frame.bits(p));
            src_linesize[p] = frame.bytesPerLine(p);
        }
        // YV12 → swap U/V (FFmpeg ждёт YUV420P порядок). Простой свап указателей.
        if (qtfmt == QVideoFrameFormat::Format_YV12 && frame.planeCount() >= 3) {
            std::swap(src_data[1], src_data[2]);
            std::swap(src_linesize[1], src_linesize[2]);
        }

        QByteArray out;
        out.resize(dw * dh * 3 / 2);
        uint8_t *dst_data[4] = {nullptr, nullptr, nullptr, nullptr};
        int dst_linesize[4]  = {0, 0, 0, 0};
        auto *dst            = reinterpret_cast<uint8_t *>(out.data());
        dst_data[0]          = dst;
        dst_data[1]          = dst + dw * dh;
        dst_data[2]          = dst_data[1] + (dw / 2) * (dh / 2);
        dst_linesize[0]      = dw;
        dst_linesize[1]      = dw / 2;
        dst_linesize[2]      = dw / 2;

        thread_local SwsCache cache;
        SwsContext *sws = cache.get(sw, sh, srcFmt, dw, dh);
        if (!sws) {
            frame.unmap();
            return;
        }
        sws_scale(sws, src_data, src_linesize, 0, sh, dst_data, dst_linesize);
        frame.unmap();
        emit frameReady(out, pts_90k);
    }

} // namespace paranoia::voip
