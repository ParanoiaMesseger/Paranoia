#pragma once

#include <QCamera>
#include <QMediaCaptureSession>
#include <QObject>
#include <QPointer>
#include <QVideoFrame>
#include <QVideoSink>
#include <memory>

namespace paranoia::voip
{

    /// Захват с камеры: оборачивает `QCamera` + `QMediaCaptureSession`, ловит
    /// каждый кадр через `QVideoSink`, конвертит в I420 (YUV 4:2:0 planar) с
    /// масштабированием до целевого `VideoFormat::kWidth` × `VideoFormat::kHeight`
    /// и эмитит `frameReady(i420_bytes, pts_90khz)`.
    ///
    /// Также пишет локальный preview в `QVideoSink` из QML `VideoOutput`.
    class VideoCapture : public QObject
    {
        Q_OBJECT
    public:
        explicit VideoCapture(QObject *parent = nullptr);
        ~VideoCapture() override;

        /// Запустить камеру. Если ни одна не найдена — false и `error` сигнал.
        bool start();
        void stop();

        bool isActive() const;

        QVideoSink *previewSink() const { return preview_sink_.data(); }
        void setPreviewSink(QVideoSink *sink) { preview_sink_ = sink; }

    signals:
        /// Готов очередной кадр: i420 байты (size = w*h*3/2 целевого формата).
        /// `pts_90khz` — RTP timestamp в 90 кГц шкале, монотонно растёт.
        void frameReady(const QByteArray &i420, qint64 pts_90khz);
        void error(const QString &message);

    private slots:
        void onVideoFrame(const QVideoFrame &frame);

    private:
        std::unique_ptr<QMediaCaptureSession> session_;
        std::unique_ptr<QCamera> camera_;
        std::unique_ptr<QVideoSink> sink_;  // сюда падают кадры с камеры
        QPointer<QVideoSink> preview_sink_; // тот же кадр в preview (для QML)
        qint64 first_frame_us_ = -1;        // pts базового отсчёта (microseconds)
    };

} // namespace paranoia::voip
