#include "OpusCodec.hpp"

#include <opus/opus.h>

namespace paranoia::voip
{

    OpusEncoderWrap::OpusEncoderWrap() = default;

    OpusEncoderWrap::~OpusEncoderWrap()
    {
        if (enc_) {
            opus_encoder_destroy(enc_);
            enc_ = nullptr;
        }
    }

    bool OpusEncoderWrap::init(int bitrate_bps)
    {
        int err = OPUS_OK;
        enc_    = opus_encoder_create(AudioFormat::kSampleRate, AudioFormat::kChannels, OPUS_APPLICATION_VOIP, &err);
        if (err != OPUS_OK || !enc_) {
            last_error_ = opus_strerror(err);
            enc_        = nullptr;
            return false;
        }
        opus_encoder_ctl(enc_, OPUS_SET_BITRATE(bitrate_bps));
        opus_encoder_ctl(enc_, OPUS_SET_VBR(1));
        opus_encoder_ctl(enc_, OPUS_SET_INBAND_FEC(1));
        // DTX может вернуть 0-byte frame на тишине. Для первого рабочего VoIP это
        // мешает диагностике и NAT traversal: media-поток выглядит как "один пакет
        // и дальше тишина". Держим непрерывный 20 ms поток; Opus всё равно кодирует
        // тишину очень дёшево.
        opus_encoder_ctl(enc_, OPUS_SET_DTX(0));
        opus_encoder_ctl(enc_, OPUS_SET_PACKET_LOSS_PERC(5));
        opus_encoder_ctl(enc_, OPUS_SET_COMPLEXITY(8));
        opus_encoder_ctl(enc_, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
        return true;
    }

    QByteArray OpusEncoderWrap::encode(const int16_t *pcm, int sample_count)
    {
        if (!enc_ || !pcm || sample_count != AudioFormat::kFrameSamples) {
            last_error_ = "invalid encode input";
            return {};
        }
        // 4000 byte — рекомендация libopus для максимума на фрейм @ 48k.
        QByteArray out(4000, Qt::Uninitialized);
        int bytes = opus_encode(enc_, pcm, sample_count, reinterpret_cast<unsigned char *>(out.data()), out.size());
        if (bytes < 0) {
            last_error_ = opus_strerror(bytes);
            return {};
        }
        last_error_ = "";
        out.resize(bytes);
        return out;
    }

    OpusDecoderWrap::OpusDecoderWrap() = default;

    OpusDecoderWrap::~OpusDecoderWrap()
    {
        if (dec_) {
            opus_decoder_destroy(dec_);
            dec_ = nullptr;
        }
    }

    bool OpusDecoderWrap::init()
    {
        int err = OPUS_OK;
        dec_    = opus_decoder_create(AudioFormat::kSampleRate, AudioFormat::kChannels, &err);
        if (err != OPUS_OK || !dec_) {
            last_error_ = opus_strerror(err);
            dec_        = nullptr;
            return false;
        }
        return true;
    }

    int OpusDecoderWrap::decode(const uint8_t *opus, int len, int16_t *pcm_out, int max_samples)
    {
        if (!dec_ || !pcm_out) {
            last_error_ = "decoder not initialized";
            return -1;
        }
        // FEC=0 (мы не используем in-band FEC отдельной веткой); PLC активируется
        // если opus==nullptr.
        int samples = opus_decode(dec_, opus, len, pcm_out, max_samples, /*decode_fec=*/0);
        if (samples < 0) {
            last_error_ = opus_strerror(samples);
            return -1;
        }
        return samples;
    }

} // namespace paranoia::voip
