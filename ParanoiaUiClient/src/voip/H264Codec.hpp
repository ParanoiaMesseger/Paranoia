#pragma once

#include <QString>
#include <vector>

extern "C" {
struct AVCodecContext;
struct AVFrame;
struct AVPacket;
struct SwsContext;
}

namespace paranoia::voip
{

    /// Параметры видео-стрима, фиксированные для всех Paranoia-звонков.
    struct VideoFormat {
        /// Целевое разрешение. Capture может отдавать любое, сжимаем к этому.
        static constexpr int kWidth  = 1280;
        static constexpr int kHeight = 720;
        /// 30 fps.
        static constexpr int kFrameRate = 30;
        /// 90 kHz RTP timestamp clock (стандарт RFC 6184 для H.264).
        static constexpr int kClockHz = 90000;
        /// Целевой битрейт ~1 Mbps — хороший баланс качества/трафика для 720p.
        static constexpr int kBitrateBps = 1'000'000;
        /// Keyframe каждую секунду (30 кадров @ 30 fps). На потерях быстрее
        /// восстанавливаемся — особенно критично на cellular.
        static constexpr int kGopSize = 30;
    };

    /// H.264 энкодер на libavcodec с попыткой использовать платформенный
    /// hardware-accelerated кодек (h264_videotoolbox/macOS, h264_mediacodec/Android,
    /// h264_vaapi/Linux, h264_nvenc/_qsv/_amf на Windows). При неудаче — fallback
    /// на программный libx264, в крайнем случае — на внутренний `libavcodec`.
    ///
    /// Вход: I420 (YUV 4:2:0 planar) PCM-байты от `VideoCapture`.
    /// Выход: Annex B H.264 bitstream (последовательность NAL'ов с
    /// start-кодами `00 00 00 01`).
    class H264Encoder
    {
    public:
        H264Encoder();
        ~H264Encoder();

        H264Encoder(const H264Encoder &)            = delete;
        H264Encoder &operator=(const H264Encoder &) = delete;

        /// Инициализировать энкодер. Сначала пробует hw-кодеки в порядке
        /// предпочтения для текущей платформы; если ни один не запустился —
        /// libx264; если и его нет — fallback на встроенный libavcodec.
        /// Возвращает true при успехе. Имя выбранного кодека доступно через
        /// `codecName()`.
        bool init(int width = VideoFormat::kWidth, int height = VideoFormat::kHeight, int fps = VideoFormat::kFrameRate,
                  int bitrate_bps = VideoFormat::kBitrateBps);

        /// Кодирует один I420-кадр (`y_plane || u_plane || v_plane`, размер
        /// `width*height*3/2` байт). `pts_90khz` — RTP timestamp (90 кГц шкала).
        /// Возвращает список Annex B пакетов (по одному NAL'у в каждом). Если
        /// энкодер ничего не отдал (B-frames, прогрев) — список пуст. Ошибки
        /// в `lastError()`.
        std::vector<QByteArray> encode(const uint8_t *i420_data, int data_size, int64_t pts_90khz);

        /// Запросить keyframe у энкодера на следующий вызов encode() — полезно
        /// при потере пакета или подключении нового пира.
        void requestKeyframe();

        QString codecName() const { return codec_name_; }
        QString lastError() const { return last_error_; }

        int width() const { return width_; }
        int height() const { return height_; }

    private:
        bool openWithCodec(const char *codec_name, int width, int height, int fps, int bitrate_bps);
        /// Разрезать annex-B bitstream от энкодера на отдельные NAL'ы.
        std::vector<QByteArray> splitAnnexB(const uint8_t *data, int size);

        AVCodecContext *ctx_ = nullptr;
        AVFrame *frame_      = nullptr;
        AVPacket *packet_    = nullptr;
        QString codec_name_;
        QString last_error_;
        int width_           = 0;
        int height_          = 0;
        bool force_keyframe_ = false;
    };

    /// H.264 декодер. Зеркально энкодеру: вход — Annex B NAL'ы (или их
    /// слитая последовательность), выход — I420-кадр в `decoded_frame()`.
    ///
    /// Платформа выбирается аналогично энкодеру: hw decoder приоритетен.
    class H264Decoder
    {
    public:
        H264Decoder();
        ~H264Decoder();

        H264Decoder(const H264Decoder &)            = delete;
        H264Decoder &operator=(const H264Decoder &) = delete;

        bool init();

        /// Подать один NAL (или несколько слитых, без start-кодов между ними —
        /// caller должен прицепить `00 00 00 01` если есть несколько).
        /// `nal_with_startcode` — буфер уже в формате Annex B.
        /// Возвращает true если что-то декодировалось → `getDecoded` отдаст
        /// последний готовый кадр.
        bool decode(const uint8_t *nal_with_startcode, int len);

        /// Скопировать последний декодированный кадр в `out_i420` (размер
        /// должен быть >= width*height*3/2). Возвращает true если кадр есть.
        /// Если декодер ещё не получил полный кадр — false.
        bool getDecoded(uint8_t *out_i420, int out_size, int &out_width, int &out_height);

        QString codecName() const { return codec_name_; }
        QString lastError() const { return last_error_; }

    private:
        bool openWithCodec(const char *codec_name);

        AVCodecContext *ctx_ = nullptr;
        AVFrame *frame_      = nullptr;
        AVPacket *packet_    = nullptr;
        /// Если декодер выдаёт NV12/hw-формат, конвертируем в I420 через swscale.
        SwsContext *sws_    = nullptr;
        int sws_src_format_ = -1;
        int sws_width_      = 0;
        int sws_height_     = 0;
        QString codec_name_;
        QString last_error_;
        bool has_frame_ = false;
    };

} // namespace paranoia::voip
