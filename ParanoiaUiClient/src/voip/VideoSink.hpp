#pragma once

#include <QPointer>
#include <QVideoFrame>
#include <QVideoSink>

namespace paranoia::voip
{

    /// Обёртка над `QVideoSink`, в которую `CallEngine` кидает декодированные
    /// I420-кадры (от remote-стороны звонка). `QVideoSink` берётся из QML
    /// `VideoOutput.videoSink`, потому что в Qt 6 это read-only свойство.
    ///
    /// Поток: setI420Frame() безопасно вызывать из любого потока — внутри
    /// маршалится в основной поток через `QMetaObject::invokeMethod`. Сам
    /// `QVideoSink` обновляется только в основном потоке Qt.
    class VideoSinkBridge : public QObject
    {
        Q_OBJECT
    public:
        explicit VideoSinkBridge(QObject *parent = nullptr);
        ~VideoSinkBridge() override;

        QVideoSink *videoSink() const { return sink_.data(); }
        void setVideoSink(QVideoSink *sink) { sink_ = sink; }

        /// Установить I420-кадр. Безопасно из любого потока.
        void setI420Frame(QByteArray i420, int width, int height);

    public slots:
        /// Внутренний слот, через который setI420Frame доставляет кадр в main thread.
        void applyI420(const QByteArray &i420, int width, int height);

    private:
        QPointer<QVideoSink> sink_;
    };

} // namespace paranoia::voip
