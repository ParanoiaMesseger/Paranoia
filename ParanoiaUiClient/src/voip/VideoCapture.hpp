#pragma once

#include <QByteArray>
#include <QCamera>
#include <QCameraDevice>
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

        /// Переключиться на «следующую» доступную камеру (front ↔ back).
        /// Полезно для смены фронт/тыл во время видеозвонка. Если камера
        /// одна — no-op. Возвращает true если переключение произошло.
        bool switchCamera();

        /// Есть ли в системе больше одной камеры (для скрытия/показа
        /// кнопки переключения в UI).
        static bool hasMultipleCameras();

        QVideoSink *previewSink() const { return preview_sink_.data(); }
        void setPreviewSink(QVideoSink *sink) { preview_sink_ = sink; }

    signals:
        /// Готов очередной кадр: i420 байты (size = w*h*3/2 целевого формата).
        /// `pts_90khz` — RTP timestamp в 90 кГц шкале, монотонно растёт.
        void frameReady(const QByteArray &i420, qint64 pts_90khz);
        /// Эмитится один раз после первого валидного кадра — сообщает
        /// фактические размеры выходного потока (720×1280 portrait /
        /// 1280×720 landscape). H.264-энкодеру нужно знать эти димы для init.
        void dimensionsReady(int width, int height);
        void error(const QString &message);

    private slots:
        void onVideoFrame(const QVideoFrame &frame);

    private:
        bool startCamera(const QCameraDevice &device);

        struct FilterState;

        std::unique_ptr<QMediaCaptureSession> session_;
        std::unique_ptr<QCamera> camera_;
        std::unique_ptr<QVideoSink> sink_;  // сюда падают кадры с камеры
        QPointer<QVideoSink> preview_sink_; // тот же кадр в preview (для QML)
        qint64 first_frame_us_      = -1;   // pts базового отсчёта (microseconds)
        QByteArray current_camera_id_;
        std::unique_ptr<FilterState> filter_;
        // Выходные димы определяются на первом кадре исходя из эффективной
        // ориентации источника (rotation + mirror). 0×0 пока не задано.
        int dst_w_ = 0;
        int dst_h_ = 0;
    };

} // namespace paranoia::voip
