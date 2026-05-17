#include "AudioPlayback.hpp"

#include <QDebug>
#include <QMediaDevices>
#include <algorithm>

#include "OpusCodec.hpp"

namespace paranoia::voip
{

    /// QIODevice, который сам подтягивает данные при readData. Безопасен для
    /// записи из стороннего потока через push().
    class PlaybackDevice : public QIODevice
    {
    public:
        explicit PlaybackDevice(QObject *parent = nullptr) : QIODevice(parent) {}

        void push(const QByteArray &pcm)
        {
            QMutexLocker lock(&mutex_);
            // Жёсткий потолок 400 ms = 20 фреймов; при переполнении выкидываем
            // самое старое, чтобы не отставать.
            constexpr int kMax = AudioFormat::kFrameBytes * 20;
            buffer_.append(pcm);
            if (buffer_.size() > kMax) { buffer_.remove(0, buffer_.size() - kMax); }
        }

    protected:
        qint64 readData(char *data, qint64 maxlen) override
        {
            QMutexLocker lock(&mutex_);
            const qint64 n = std::min<qint64>(maxlen, buffer_.size());
            if (n > 0) {
                std::memcpy(data, buffer_.constData(), n);
                buffer_.remove(0, static_cast<int>(n));
            }
            const qint64 silence = maxlen - n;
            if (silence > 0) {
                // Под-затыкаем тишиной, чтобы QAudioSink не дрейфил по
                // underrun'ам — для voice это лучше, чем разрывы.
                std::memset(data + n, 0, silence);
            }
            return maxlen;
        }
        qint64 writeData(const char *, qint64) override { return -1; }

    private:
        QMutex mutex_;
        QByteArray buffer_;
    };

    AudioPlayback::AudioPlayback(QObject *parent) : QObject(parent)
    {
        format_.setSampleRate(AudioFormat::kSampleRate);
        format_.setChannelCount(AudioFormat::kChannels);
        format_.setSampleFormat(QAudioFormat::Int16);
    }

    AudioPlayback::~AudioPlayback() { stop(); }

    bool AudioPlayback::start()
    {
        if (sink_) return true;
        // Дефолтный output в OS часто оказывается HDMI-монитором без динамиков
        // (на десктопе подключили монитор и забыли переключить выход) или
        // отключённым Bluetooth-устройством. Печатаем все доступные устройства
        // в лог и при необходимости подменяем default на что-то «звонящее».
        const auto outputs = QMediaDevices::audioOutputs();
        if (outputs.isEmpty()) {
            emit error(QStringLiteral("no audio output devices available"));
            return false;
        }
        QAudioDevice device = QMediaDevices::defaultAudioOutput();
        {
            QStringList descriptions;
            for (const auto &d : outputs) descriptions.append(d.description());
            qInfo().noquote() << "AudioPlayback: available outputs:" << descriptions.join(QStringLiteral(" | "));
        }
        const QString defaultDesc = device.description();
        const bool defaultIsHdmi  = defaultDesc.contains(QStringLiteral("HDMI"), Qt::CaseInsensitive) ||
                                   defaultDesc.contains(QStringLiteral("DisplayPort"), Qt::CaseInsensitive) ||
                                   defaultDesc.contains(QStringLiteral("Digital"), Qt::CaseInsensitive);
        if (defaultIsHdmi) {
            for (const auto &candidate : outputs) {
                const QString desc = candidate.description();
                if (desc.contains(QStringLiteral("Analog"), Qt::CaseInsensitive) ||
                    desc.contains(QStringLiteral("Headphone"), Qt::CaseInsensitive) ||
                    desc.contains(QStringLiteral("Speaker"), Qt::CaseInsensitive) ||
                    desc.contains(QStringLiteral("Built-in"), Qt::CaseInsensitive)) {
                    qInfo().noquote() << "AudioPlayback: overriding HDMI default with" << desc;
                    device = candidate;
                    break;
                }
            }
        }
        if (device.isNull()) {
            emit error(QStringLiteral("no usable audio output device"));
            return false;
        }
        if (!device.isFormatSupported(format_)) {
            emit error(QStringLiteral("output device does not support 48 kHz s16 mono"));
            return false;
        }
        qInfo().noquote() << "AudioPlayback: starting output" << device.description() << "format"
                          << format_.sampleRate() << "Hz" << format_.channelCount() << "channel(s)";
        sink_ = std::make_unique<QAudioSink>(device, format_, this);
        connect(sink_.get(), &QAudioSink::stateChanged, this, [this](QAudio::State state) {
            if (!sink_) return;
            if (state == QAudio::StoppedState && sink_->error() != QAudio::NoError) {
                qWarning().noquote() << "AudioPlayback: sink stopped with error" << sink_->error();
            }
        });
        sink_->setBufferSize(AudioFormat::kFrameBytes * 4);
        // Полная громкость — у QAudioSink дефолт 1.0, но на некоторых платформах
        // (Android в особенности) volume может уезжать в 0 из-за audio policy.
        sink_->setVolume(1.0);
        device_ = new PlaybackDevice(sink_.get());
        if (!device_->open(QIODevice::ReadOnly)) {
            emit error(QStringLiteral("PlaybackDevice open failed"));
            sink_.reset();
            device_ = nullptr;
            return false;
        }
        sink_->start(device_);
        return true;
    }

    void AudioPlayback::stop()
    {
        if (sink_) {
            sink_->stop();
            sink_.reset();
        }
        device_ = nullptr; // owned by sink, гасится в его деструкторе
    }

    void AudioPlayback::pushFrame(const QByteArray &pcm)
    {
        if (device_) { device_->push(pcm); }
    }

} // namespace paranoia::voip
