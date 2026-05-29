#include "H264Codec.hpp"

#include <QDebug>
#include <cstring>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libavutil/pixfmt.h>
#include <libswscale/swscale.h>
}

// FFmpeg <6.1 (напр. libavcodec 58 на Ubuntu 22.04) использует префикс
// FF_PROFILE_*; в 6.1+ его переименовали в AV_PROFILE_*. Чтобы код собирался
// и со старым системным FFmpeg, и с новым — подставляем старое имя.
#ifndef AV_PROFILE_H264_BASELINE
#define AV_PROFILE_H264_BASELINE FF_PROFILE_H264_BASELINE
#endif

namespace paranoia::voip
{

    namespace
    {

        // Список hw-энкодеров по приоритету для текущей платформы. NULL-terminated.
        // Пробуются в порядке; если init не удался — следующий. Software libx264 в
        // конце как универсальный fallback.
        const char *const *preferredEncoderNames()
        {
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
            static const char *names[] = {"h264_videotoolbox", "libx264", "libopenh264", "h264", nullptr};
#elif defined(Q_OS_ANDROID)
            // h264_mediacodec — hw-encoder через JNI; быстрый, но требует включения в
            // FFmpeg-сборке и runtime SDK API. libopenh264 — наш надёжный software
            // fallback (его cross-compile делает scripts/build_openh264_android.sh).
            static const char *names[] = {"h264_mediacodec", "libopenh264", "libx264", "h264", nullptr};
#elif defined(Q_OS_WIN)
            static const char *names[] = {"h264_nvenc",  "h264_qsv", "h264_amf", "libx264",
                                          "libopenh264", "h264",     nullptr};
#elif defined(Q_OS_LINUX)
            // libx264 ставим перед hw-кодеками: на десктопе с интегрированным GPU
            // h264_nvenc «находится» (find_encoder), open2 тоже отдаёт 0, а упасть
            // может позже на первом send_frame — это путает диагностику. Software
            // libx264 надёжнее как первый выбор; hw — fallback при его отсутствии.
            static const char *names[] = {"libx264",      "libopenh264", "h264_nvenc", "h264_vaapi",
                                          "h264_v4l2m2m", "h264",        nullptr};
#else
            static const char *names[] = {"libx264", "libopenh264", "h264", nullptr};
#endif
            return names;
        }

        // Decoder priority: hw decode оправдан в первую очередь на мобильных, где
        // software h264 нагружает CPU. На desktop за глаза хватает software.
        const char *const *preferredDecoderNames()
        {
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
            static const char *names[] = {"h264_videotoolbox", "h264", "libopenh264", nullptr};
#elif defined(Q_OS_ANDROID)
            static const char *names[] = {"h264_mediacodec", "h264", "libopenh264", nullptr};
#else
            static const char *names[] = {"h264", "libopenh264", nullptr};
#endif
            return names;
        }

        QString ffErr(int code)
        {
            char buf[AV_ERROR_MAX_STRING_SIZE] = {0};
            av_strerror(code, buf, sizeof(buf));
            return QString::fromUtf8(buf);
        }

        // Найти следующий Annex B start-code (3- или 4-байтовый) в буфере, начиная с
        // offset. Возвращает позицию первого байта start-кода или -1.
        int findStartCode(const uint8_t *buf, int size, int offset, int &out_sc_len)
        {
            for (int i = offset; i + 3 < size; ++i) {
                if (buf[i] == 0x00 && buf[i + 1] == 0x00) {
                    if (buf[i + 2] == 0x01) {
                        out_sc_len = 3;
                        return i;
                    }
                    if (buf[i + 2] == 0x00 && buf[i + 3] == 0x01) {
                        out_sc_len = 4;
                        return i;
                    }
                }
            }
            return -1;
        }

    } // namespace

    // ── Encoder ─────────────────────────────────────────────────────────────

    H264Encoder::H264Encoder() = default;

    H264Encoder::~H264Encoder()
    {
        if (packet_) av_packet_free(&packet_);
        if (frame_) av_frame_free(&frame_);
        if (ctx_) avcodec_free_context(&ctx_);
    }

    bool H264Encoder::init(int width, int height, int fps, int bitrate_bps)
    {
        width_  = width;
        height_ = height;

        QStringList attempts;
        for (const char *const *p = preferredEncoderNames(); *p; ++p) {
            last_error_.clear();
            if (openWithCodec(*p, width, height, fps, bitrate_bps)) {
                codec_name_ = QString::fromUtf8(*p);
                qInfo() << "H264Encoder: using" << codec_name_;
                return true;
            }
            const QString why =
                last_error_.isEmpty() ? QStringLiteral("codec not registered in libavcodec") : last_error_;
            attempts.append(QStringLiteral("%1: %2").arg(QString::fromUtf8(*p), why));
            qInfo().noquote() << "H264Encoder: tried" << *p << "→" << why;
        }
        last_error_ = QStringLiteral("no usable H.264 encoder (")
                          .append(attempts.join(QStringLiteral("; ")))
                          .append(QStringLiteral(")"));
        return false;
    }

    bool H264Encoder::openWithCodec(const char *codec_name, int width, int height, int fps, int bitrate_bps)
    {
        const AVCodec *codec = avcodec_find_encoder_by_name(codec_name);
        if (!codec) { return false; }
        AVCodecContext *ctx = avcodec_alloc_context3(codec);
        if (!ctx) { return false; }
        ctx->width        = width;
        ctx->height       = height;
        ctx->time_base    = {1, VideoFormat::kClockHz}; // 90 kHz RTP timebase
        ctx->framerate    = {fps, 1};
        ctx->pix_fmt      = AV_PIX_FMT_YUV420P; // I420
        ctx->bit_rate     = bitrate_bps;
        ctx->gop_size     = VideoFormat::kGopSize;
        ctx->max_b_frames = 0; // realtime — без B-кадров
        ctx->thread_count = 0; // авто
        // Baseline-профиль: максимальная совместимость, минимальная задержка.
        ctx->profile = AV_PROFILE_H264_BASELINE;
        // Низкая задержка важнее качества: убираем lookahead/B-кадры.
        if (codec_name && std::strcmp(codec_name, "libx264") == 0) {
            av_opt_set(ctx->priv_data, "preset", "veryfast", 0);
            av_opt_set(ctx->priv_data, "tune", "zerolatency", 0);
            av_opt_set(ctx->priv_data, "profile", "baseline", 0);
            // Annex B вывод — нужен для нашего фрагмент-пайплайна.
            av_opt_set(ctx->priv_data, "annexb", "1", 0);
        } else if (codec_name && std::strstr(codec_name, "videotoolbox")) {
            av_opt_set(ctx->priv_data, "realtime", "1", 0);
            av_opt_set(ctx->priv_data, "allow_sw", "1", 0);
        } else if (codec_name && std::strstr(codec_name, "nvenc")) {
            av_opt_set(ctx->priv_data, "preset", "p1", 0); // fastest
            av_opt_set(ctx->priv_data, "tune", "ull", 0);  // ultra-low-latency
            av_opt_set(ctx->priv_data, "zerolatency", "1", 0);
        } else if (codec_name && std::strstr(codec_name, "qsv")) {
            av_opt_set(ctx->priv_data, "preset", "veryfast", 0);
        }

        int ret = avcodec_open2(ctx, codec, nullptr);
        if (ret < 0) {
            last_error_ = QStringLiteral("avcodec_open2(%1) failed: %2").arg(codec_name).arg(ffErr(ret));
            avcodec_free_context(&ctx);
            return false;
        }

        AVFrame *frame = av_frame_alloc();
        if (!frame) {
            avcodec_free_context(&ctx);
            return false;
        }
        frame->format = AV_PIX_FMT_YUV420P;
        frame->width  = width;
        frame->height = height;
        if (av_frame_get_buffer(frame, 32) < 0) {
            av_frame_free(&frame);
            avcodec_free_context(&ctx);
            return false;
        }

        AVPacket *pkt = av_packet_alloc();
        if (!pkt) {
            av_frame_free(&frame);
            avcodec_free_context(&ctx);
            return false;
        }

        ctx_    = ctx;
        frame_  = frame;
        packet_ = pkt;
        // Первый кадр всегда IDR с SPS/PPS — без этого приёмник ждёт следующий
        // keyframe (до 1 секунды) и зря тратит окно «звонок только что соединился».
        force_keyframe_ = true;
        return true;
    }

    void H264Encoder::requestKeyframe() { force_keyframe_ = true; }

    std::vector<QByteArray> H264Encoder::encode(const uint8_t *i420_data, int data_size, int64_t pts_90khz)
    {
        std::vector<QByteArray> out;
        if (!ctx_ || !frame_ || !packet_) {
            last_error_ = QStringLiteral("encoder not initialized");
            return out;
        }
        const int expected = width_ * height_ * 3 / 2;
        if (data_size != expected) {
            last_error_ = QStringLiteral("encode: bad i420 size %1, expected %2").arg(data_size).arg(expected);
            return out;
        }

        if (av_frame_make_writable(frame_) < 0) {
            last_error_ = QStringLiteral("av_frame_make_writable failed");
            return out;
        }

        // Копируем плоскости I420 в кадр FFmpeg.
        const uint8_t *y = i420_data;
        const uint8_t *u = y + width_ * height_;
        const uint8_t *v = u + (width_ / 2) * (height_ / 2);
        av_image_copy_plane(frame_->data[0], frame_->linesize[0], y, width_, width_, height_);
        av_image_copy_plane(frame_->data[1], frame_->linesize[1], u, width_ / 2, width_ / 2, height_ / 2);
        av_image_copy_plane(frame_->data[2], frame_->linesize[2], v, width_ / 2, width_ / 2, height_ / 2);
        frame_->pts       = pts_90khz;
        frame_->pict_type = force_keyframe_ ? AV_PICTURE_TYPE_I : AV_PICTURE_TYPE_NONE;
        if (force_keyframe_) {
#ifdef AV_FRAME_FLAG_KEY
            frame_->flags |= AV_FRAME_FLAG_KEY;
#else
            frame_->key_frame = 1;
#endif
            force_keyframe_   = false;
        } else {
#ifdef AV_FRAME_FLAG_KEY
            frame_->flags &= ~AV_FRAME_FLAG_KEY;
#else
            frame_->key_frame = 0;
#endif
        }

        int ret = avcodec_send_frame(ctx_, frame_);
        if (ret < 0) {
            last_error_ = QStringLiteral("avcodec_send_frame: %1").arg(ffErr(ret));
            return out;
        }

        for (;;) {
            ret = avcodec_receive_packet(ctx_, packet_);
            if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) { break; }
            if (ret < 0) {
                last_error_ = QStringLiteral("avcodec_receive_packet: %1").arg(ffErr(ret));
                return out;
            }
            // Annex B bitstream — разрезаем на NAL'ы.
            auto nals = splitAnnexB(packet_->data, packet_->size);
            for (auto &nal : nals) { out.push_back(std::move(nal)); }
            av_packet_unref(packet_);
        }
        return out;
    }

    std::vector<QByteArray> H264Encoder::splitAnnexB(const uint8_t *data, int size)
    {
        std::vector<QByteArray> nals;
        int pos    = 0;
        int sc_len = 0;
        int start  = findStartCode(data, size, pos, sc_len);
        while (start >= 0) {
            const int nal_body_start = start + sc_len;
            int sc_next_len          = 0;
            int next                 = findStartCode(data, size, nal_body_start, sc_next_len);
            const int nal_end        = (next >= 0) ? next : size;
            const int nal_len        = nal_end - nal_body_start;
            if (nal_len > 0) { nals.emplace_back(reinterpret_cast<const char *>(data + nal_body_start), nal_len); }
            if (next < 0) break;
            start  = next;
            sc_len = sc_next_len;
        }
        // Если bitstream не содержит Annex B-start-кодов (некоторые hw-кодеки в
        // AVCC формате) — отдаём как один блок.
        if (nals.empty() && size > 0) { nals.emplace_back(reinterpret_cast<const char *>(data), size); }
        return nals;
    }

    // ── Decoder ─────────────────────────────────────────────────────────────

    H264Decoder::H264Decoder() = default;

    H264Decoder::~H264Decoder()
    {
        if (sws_) {
            sws_freeContext(sws_);
            sws_ = nullptr;
        }
        if (packet_) av_packet_free(&packet_);
        if (frame_) av_frame_free(&frame_);
        if (ctx_) avcodec_free_context(&ctx_);
    }

    bool H264Decoder::init()
    {
        QStringList attempts;
        for (const char *const *p = preferredDecoderNames(); *p; ++p) {
            last_error_.clear();
            if (openWithCodec(*p)) {
                codec_name_ = QString::fromUtf8(*p);
                qInfo() << "H264Decoder: using" << codec_name_;
                return true;
            }
            const QString why =
                last_error_.isEmpty() ? QStringLiteral("codec not registered in libavcodec") : last_error_;
            attempts.append(QStringLiteral("%1: %2").arg(QString::fromUtf8(*p), why));
            qInfo().noquote() << "H264Decoder: tried" << *p << "→" << why;
        }
        last_error_ = QStringLiteral("no usable H.264 decoder (")
                          .append(attempts.join(QStringLiteral("; ")))
                          .append(QStringLiteral(")"));
        return false;
    }

    bool H264Decoder::openWithCodec(const char *codec_name)
    {
        const AVCodec *codec = avcodec_find_decoder_by_name(codec_name);
        if (!codec) { return false; }
        AVCodecContext *ctx = avcodec_alloc_context3(codec);
        if (!ctx) { return false; }
        ctx->thread_count = 0; // авто
        ctx->thread_type  = FF_THREAD_FRAME | FF_THREAD_SLICE;
        int ret           = avcodec_open2(ctx, codec, nullptr);
        if (ret < 0) {
            last_error_ = QStringLiteral("avcodec_open2(%1) failed: %2").arg(codec_name).arg(ffErr(ret));
            avcodec_free_context(&ctx);
            return false;
        }
        AVFrame *frame = av_frame_alloc();
        AVPacket *pkt  = av_packet_alloc();
        if (!frame || !pkt) {
            if (frame) av_frame_free(&frame);
            if (pkt) av_packet_free(&pkt);
            avcodec_free_context(&ctx);
            return false;
        }
        ctx_    = ctx;
        frame_  = frame;
        packet_ = pkt;
        return true;
    }

    bool H264Decoder::decode(const uint8_t *nal_with_startcode, int len)
    {
        if (!ctx_ || !packet_ || !frame_ || !nal_with_startcode || len <= 0) { return false; }
        // av_packet_from_data ожидает буфер с av_malloc — проще сделать
        // unref/копию через av_new_packet.
        av_packet_unref(packet_);
        if (av_new_packet(packet_, len) < 0) {
            last_error_ = QStringLiteral("av_new_packet failed");
            return false;
        }
        std::memcpy(packet_->data, nal_with_startcode, len);

        int ret = avcodec_send_packet(ctx_, packet_);
        if (ret < 0) {
            // EAGAIN допустимо (decoder ещё в receive-режиме) — игнорируем.
            if (ret != AVERROR(EAGAIN)) { last_error_ = QStringLiteral("avcodec_send_packet: %1").arg(ffErr(ret)); }
        }
        // Берём ровно один кадр и сразу выходим. Если оставить цикл и попытаться
        // выгрести следующий — avcodec_receive_frame на старте вызывает
        // av_frame_unref(frame_), что сбрасывает только что декодированный кадр
        // (format=-1, width=0) ещё ДО того как функция вернёт EAGAIN. Это валит
        // getDecoded()/sws_getContext позже (av_assert0(desc) в swscale).
        ret = avcodec_receive_frame(ctx_, frame_);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) { return false; }
        if (ret < 0) {
            last_error_ = QStringLiteral("avcodec_receive_frame: %1").arg(ffErr(ret));
            return false;
        }
        // Sanity: кадр может прийти «пустым» если декодер выдал SEI/прочие
        // дескрипторы без актуального изображения. Без этих полей swscale падает.
        if (frame_->format == AV_PIX_FMT_NONE || frame_->width <= 0 || frame_->height <= 0) { return false; }
        has_frame_ = true;
        return true;
    }

    bool H264Decoder::getDecoded(uint8_t *out_i420, int out_size, int &out_width, int &out_height)
    {
        if (!has_frame_ || !frame_) return false;
        // Декодер может оставить frame в неполном состоянии, если последняя
        // avcodec_receive_frame вернула ошибку после успешного предыдущего вызова,
        // или если до этого подавали только SPS/PPS без VCL NAL'ов. Передача
        // format=-1 или width/height=0 в swscale валит процесс через
        // `av_assert0(desc)` в swscale_internal.h. Проверяем явно.
        const int src_fmt_int = frame_->format;
        if (src_fmt_int == AV_PIX_FMT_NONE || frame_->width <= 0 || frame_->height <= 0) {
            has_frame_ = false;
            return false;
        }
        const auto src_fmt = static_cast<AVPixelFormat>(src_fmt_int);
        out_width          = frame_->width;
        out_height         = frame_->height;
        const int needed   = out_width * out_height * 3 / 2;
        if (out_size < needed) {
            last_error_ = QStringLiteral("out buffer %1 < needed %2").arg(out_size).arg(needed);
            return false;
        }

        if (src_fmt == AV_PIX_FMT_YUV420P) {
            // Прямое копирование плоскостей.
            uint8_t *y = out_i420;
            uint8_t *u = y + out_width * out_height;
            uint8_t *v = u + (out_width / 2) * (out_height / 2);
            av_image_copy_plane(y, out_width, frame_->data[0], frame_->linesize[0], out_width, out_height);
            av_image_copy_plane(u, out_width / 2, frame_->data[1], frame_->linesize[1], out_width / 2, out_height / 2);
            av_image_copy_plane(v, out_width / 2, frame_->data[2], frame_->linesize[2], out_width / 2, out_height / 2);
            has_frame_ = false;
            return true;
        }

        // Иначе конвертируем через swscale (NV12 hw-кадр, YUV420P10LE и т. д.).
        if (!sws_isSupportedInput(src_fmt)) {
            last_error_ = QStringLiteral("unsupported decoded pixel format %1").arg(static_cast<int>(src_fmt));
            has_frame_  = false;
            return false;
        }
        if (!sws_ || sws_src_format_ != src_fmt_int || sws_width_ != frame_->width || sws_height_ != frame_->height) {
            if (sws_) {
                sws_freeContext(sws_);
                sws_ = nullptr;
            }
            sws_ = sws_getContext(frame_->width, frame_->height, src_fmt, frame_->width, frame_->height,
                                  AV_PIX_FMT_YUV420P, SWS_BILINEAR, nullptr, nullptr, nullptr);
            if (!sws_) {
                last_error_ = QStringLiteral("sws_getContext failed (src fmt %1, %2x%3)")
                                  .arg(static_cast<int>(src_fmt))
                                  .arg(frame_->width)
                                  .arg(frame_->height);
                return false;
            }
            sws_src_format_ = src_fmt_int;
            sws_width_      = frame_->width;
            sws_height_     = frame_->height;
        }

        uint8_t *dst_data[4] = {nullptr, nullptr, nullptr, nullptr};
        int dst_linesize[4]  = {0, 0, 0, 0};
        dst_data[0]          = out_i420;
        dst_data[1]          = dst_data[0] + out_width * out_height;
        dst_data[2]          = dst_data[1] + (out_width / 2) * (out_height / 2);
        dst_linesize[0]      = out_width;
        dst_linesize[1]      = out_width / 2;
        dst_linesize[2]      = out_width / 2;
        int converted = sws_scale(sws_, frame_->data, frame_->linesize, 0, frame_->height, dst_data, dst_linesize);
        has_frame_    = false;
        return converted == out_height;
    }

} // namespace paranoia::voip
