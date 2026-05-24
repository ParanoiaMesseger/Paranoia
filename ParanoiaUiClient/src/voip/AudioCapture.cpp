#include "AudioCapture.hpp"

#include <QMediaDevices>

#include "OpusCodec.hpp"

namespace paranoia::voip
{

    AudioCapture::AudioCapture(QObject *parent) : QObject(parent)
    {
        format_.setSampleRate(AudioFormat::kSampleRate);
        format_.setChannelCount(AudioFormat::kChannels);
        format_.setSampleFormat(QAudioFormat::Int16);
        buffer_.reserve(AudioFormat::kFrameBytes * 4);
    }

    AudioCapture::~AudioCapture() { stop(); }

    bool AudioCapture::start()
    {
        if (source_) return true;
        const QAudioDevice device = QMediaDevices::defaultAudioInput();
        if (device.isNull()) {
            emit error(QStringLiteral("no default audio input device"));
            return false;
        }
        if (!device.isFormatSupported(format_)) {
            emit error(QStringLiteral("input device does not support 48 kHz s16 mono"));
            return false;
        }
        source_ = std::make_unique<QAudioSource>(device, format_, this);
        // Буфер на ~100 ms — короче снижает латентность.
        source_->setBufferSize(AudioFormat::kFrameBytes * 5);

        stream_ = source_->start();
        if (!stream_) {
            emit error(QStringLiteral("QAudioSource start() returned null"));
            source_.reset();
            return false;
        }
        connect(stream_, &QIODevice::readyRead, this, &AudioCapture::onIncoming);
        return true;
    }

    void AudioCapture::stop()
    {
        if (stream_) {
            disconnect(stream_, nullptr, this, nullptr);
            stream_ = nullptr;
        }
        if (source_) {
            source_->stop();
            source_.reset();
        }
        buffer_.clear();
    }

    void AudioCapture::onIncoming()
    {
        if (!stream_) return;
        const QByteArray chunk = stream_->readAll();
        if (chunk.isEmpty()) return;
        buffer_.append(chunk);
        while (buffer_.size() >= AudioFormat::kFrameBytes) {
            // Эмитим первые kFrameBytes байт; в буфере остаётся хвост.
            emit frameReady(QByteArray(buffer_.constData(), AudioFormat::kFrameBytes));
            buffer_.remove(0, AudioFormat::kFrameBytes);
        }
    }

} // namespace paranoia::voip
