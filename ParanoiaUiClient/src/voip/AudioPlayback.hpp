#pragma once

#include <QAudioSink>
#include <QIODevice>
#include <QMutex>
#include <QObject>
#include <memory>

namespace paranoia::voip
{

    /// Внутренний QIODevice, отдающий PCM из ring-буфера в QAudioSink.
    class PlaybackDevice;

    /// Воспроизведение PCM в спикер. Принимает фреймы 20 ms s16 mono 48k через
    /// `pushFrame`. Внутри простой кольцевой буфер; при under-run отдаём тишину.
    class AudioPlayback : public QObject
    {
        Q_OBJECT
    public:
        explicit AudioPlayback(QObject *parent = nullptr);
        ~AudioPlayback() override;

        bool start();
        void stop();

        /// Положить PCM-фрейм в буфер воспроизведения. Безопасно из любого
        /// потока (Qt::QueuedConnection не обязателен).
        void pushFrame(const QByteArray &pcm);

    signals:
        void error(const QString &message);

    private:
        QAudioFormat format_;
        std::unique_ptr<QAudioSink> sink_;
        PlaybackDevice *device_ = nullptr; // owned by sink via Qt parent
    };

} // namespace paranoia::voip
