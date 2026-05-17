#pragma once

#include <QAudioSource>
#include <QByteArray>
#include <QIODevice>
#include <QObject>
#include <QPointer>
#include <memory>

namespace paranoia::voip
{

    /// Захват PCM с микрофона; режет поток на фреймы по 20 ms (см.
    /// `AudioFormat::kFrameBytes`) и сигналит `frameReady`. Слушает QAudioSource
    /// через свой QIODevice-стрим.
    class AudioCapture : public QObject
    {
        Q_OBJECT
    public:
        explicit AudioCapture(QObject *parent = nullptr);
        ~AudioCapture() override;

        /// Стартует захват; возвращает false если устройство ввода недоступно или
        /// формат не поддерживается. После старта будет приходить `frameReady`
        /// каждые ~20 ms.
        bool start();
        void stop();

    signals:
        /// Готов очередной 20-ms PCM-фрейм (s16 mono 48k, `AudioFormat::kFrameBytes`).
        /// `data` валиден только в рамках слота (для long-living хранения — копия).
        void frameReady(const QByteArray &pcm);
        void error(const QString &message);

    private slots:
        void onIncoming();

    private:
        QAudioFormat format_;
        std::unique_ptr<QAudioSource> source_;
        QPointer<QIODevice> stream_;
        QByteArray buffer_; ///< накопитель до полного фрейма
    };

} // namespace paranoia::voip
