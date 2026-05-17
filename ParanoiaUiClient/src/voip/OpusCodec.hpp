#pragma once

#include <QByteArray>

struct OpusEncoder;
struct OpusDecoder;

namespace paranoia::voip
{

    /// Голосовой формат, фиксированный для всех Paranoia-звонков.
    struct AudioFormat {
        static constexpr int kSampleRate = 48000;
        static constexpr int kChannels   = 1;
        /// Длина одного фрейма в семплах = 20 ms @ 48 kHz.
        static constexpr int kFrameSamples = 960;
        /// Размер одного фрейма в байтах при s16 PCM mono.
        static constexpr int kFrameBytes = kFrameSamples * kChannels * 2;
    };

    /// Тонкая C++-обёртка над libopus encoder.
    ///
    /// VOIP application mode, фрейм 20 ms, DTX и FEC включены, мини-buffer на
    /// 2 фрейма исходящего byte-stream'а если придёт половина фрейма.
    class OpusEncoderWrap
    {
    public:
        OpusEncoderWrap();
        ~OpusEncoderWrap();

        OpusEncoderWrap(const OpusEncoderWrap &)            = delete;
        OpusEncoderWrap &operator=(const OpusEncoderWrap &) = delete;

        /// Инициализировать с заданным битрейтом (по умолчанию 24 kbps).
        /// Возвращает true при успехе; иначе ошибка через `lastError()`.
        bool init(int bitrate_bps = 24000);

        /// Закодировать один PCM-фрейм (`AudioFormat::kFrameBytes` байт s16 mono).
        /// Возвращает закодированный Opus-фрейм; пустой при ошибке (см. lastError).
        /// Длина результата — типично 20–80 байт при 24 kbps.
        QByteArray encode(const int16_t *pcm, int sample_count);

        const char *lastError() const noexcept { return last_error_; }

    private:
        OpusEncoder *enc_       = nullptr;
        const char *last_error_ = "";
    };

    /// Тонкая обёртка над libopus decoder с поддержкой PLC (packet loss
    /// concealment) при пустом фрейме.
    class OpusDecoderWrap
    {
    public:
        OpusDecoderWrap();
        ~OpusDecoderWrap();

        OpusDecoderWrap(const OpusDecoderWrap &)            = delete;
        OpusDecoderWrap &operator=(const OpusDecoderWrap &) = delete;

        bool init();

        /// Декодировать Opus-фрейм. Если `opus == nullptr` или `len == 0`,
        /// активируется PLC и `pcm_out` заполняется концеалментом.
        /// Возвращает количество выходных семплов на канал (обычно 960) или -1.
        int decode(const uint8_t *opus, int len, int16_t *pcm_out, int max_samples);

        const char *lastError() const noexcept { return last_error_; }

    private:
        OpusDecoder *dec_       = nullptr;
        const char *last_error_ = "";
    };

} // namespace paranoia::voip
