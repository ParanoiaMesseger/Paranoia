#include "VideoTranscoder.hpp"

#include <QDebug>
#include <QThread>
#include <algorithm>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/audio_fifo.h>
#include <libavutil/channel_layout.h>
#include <libavutil/display.h>
#include <libavutil/imgutils.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
}

#include <QTransform>

namespace
{
    // Угол поворота из display-matrix потока (portrait-видео телефонов).
    // 0, если матрицы нет. Используется и для переноса в выход, и для постера.
    double streamRotation(const AVStream *st)
    {
        if (!st || !st->codecpar)
            return 0.0;
        const AVPacketSideData *dm = av_packet_side_data_get(
            st->codecpar->coded_side_data, st->codecpar->nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX);
        if (dm && dm->size >= 9 * sizeof(int32_t))
            return av_display_rotation_get(reinterpret_cast<const int32_t *>(dm->data));
        return 0.0;
    }
}

namespace paranoia::media
{
    namespace
    {
        void setErr(QString *error, const QString &msg)
        {
            qWarning() << "[VideoTranscoder]" << msg;
            if (error)
                *error = msg;
        }

        QString avErr(int code)
        {
            char buf[AV_ERROR_MAX_STRING_SIZE] = {0};
            av_strerror(code, buf, sizeof(buf));
            return QString::fromUtf8(buf);
        }

        // Округлить до чётного (требование yuv420p/H.264).
        int even(int v) { return v & ~1; }

        // Целевой размер: длинная сторона <= maxDim, пропорции сохранены, чётно.
        void targetSize(int srcW, int srcH, int maxDim, int &dstW, int &dstH)
        {
            dstW = srcW;
            dstH = srcH;
            if (maxDim > 0 && std::max(srcW, srcH) > maxDim) {
                double scale = static_cast<double>(maxDim) / std::max(srcW, srcH);
                dstW         = static_cast<int>(srcW * scale + 0.5);
                dstH         = static_cast<int>(srcH * scale + 0.5);
            }
            dstW = std::max(2, even(dstW));
            dstH = std::max(2, even(dstH));
        }

        // Битрейт по разрешению, если не задан явно (~ 0.1 бит/пиксель/кадр @30).
        int autoVideoBitrate(int w, int h)
        {
            long long px = static_cast<long long>(w) * h;
            // 720p(~921k) → ~2 Мбит/с, 480p → ~1 Мбит/с, 1080p → ~4 Мбит/с.
            long long bps = px * 2; // эмпирический коэффициент
            bps           = std::clamp<long long>(bps, 400'000, 6'000'000);
            return static_cast<int>(bps);
        }

        const AVCodec *findH264Encoder()
        {
            // libopenh264 гарантированно собран в наш ffmpeg (BSD). Это и есть
            // используемый звонками энкодер — единый кодек на весь продукт.
            if (const AVCodec *c = avcodec_find_encoder_by_name("libopenh264"))
                return c;
            return avcodec_find_encoder(AV_CODEC_ID_H264);
        }
    } // namespace

    // ───────────────────────── poster frame ─────────────────────────

    QImage VideoTranscoder::extractPosterFrame(const QString &path, QString *error)
    {
        AVFormatContext *ifmt = nullptr;
        int ret = avformat_open_input(&ifmt, path.toUtf8().constData(), nullptr, nullptr);
        if (ret < 0) {
            setErr(error, QStringLiteral("open_input: %1").arg(avErr(ret)));
            return {};
        }
        QImage result;
        AVCodecContext *dec = nullptr;
        SwsContext *sws     = nullptr;
        AVFrame *frame      = av_frame_alloc();
        AVFrame *rgb        = av_frame_alloc();
        AVPacket *pkt       = av_packet_alloc();

        do {
            if (avformat_find_stream_info(ifmt, nullptr) < 0)
                break;
            int vIdx = av_find_best_stream(ifmt, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
            if (vIdx < 0)
                break;
            AVStream *st       = ifmt->streams[vIdx];
            const double rotation = streamRotation(st);
            const AVCodec *cod = avcodec_find_decoder(st->codecpar->codec_id);
            if (!cod)
                break;
            dec = avcodec_alloc_context3(cod);
            if (!dec || avcodec_parameters_to_context(dec, st->codecpar) < 0)
                break;
            if (avcodec_open2(dec, cod, nullptr) < 0)
                break;

            bool got = false;
            while (!got && av_read_frame(ifmt, pkt) >= 0) {
                if (pkt->stream_index == vIdx && avcodec_send_packet(dec, pkt) >= 0) {
                    while (avcodec_receive_frame(dec, frame) >= 0) {
                        int dstW, dstH;
                        targetSize(frame->width, frame->height, 1080, dstW, dstH);
                        sws = sws_getContext(frame->width, frame->height,
                                             static_cast<AVPixelFormat>(frame->format), dstW, dstH,
                                             AV_PIX_FMT_RGB24, SWS_BILINEAR, nullptr, nullptr, nullptr);
                        if (!sws)
                            break;
                        result = QImage(dstW, dstH, QImage::Format_RGB888);
                        uint8_t *dstData[4] = {result.bits(), nullptr, nullptr, nullptr};
                        int dstLines[4]     = {static_cast<int>(result.bytesPerLine()), 0, 0, 0};
                        sws_scale(sws, frame->data, frame->linesize, 0, frame->height, dstData, dstLines);
                        // Применяем поворот источника, чтобы постер был «ровным».
                        if (rotation != 0.0) {
                            QTransform t;
                            t.rotate(-rotation);
                            result = result.transformed(t, Qt::SmoothTransformation);
                        }
                        got = true;
                        break;
                    }
                }
                av_packet_unref(pkt);
            }
        } while (false);

        if (sws)
            sws_freeContext(sws);
        av_frame_free(&frame);
        av_frame_free(&rgb);
        av_packet_free(&pkt);
        if (dec)
            avcodec_free_context(&dec);
        avformat_close_input(&ifmt);

        if (result.isNull())
            setErr(error, QStringLiteral("no decodable video frame"));
        return result;
    }

    // ───────────────────────── transcode ─────────────────────────
    namespace
    {
        struct StreamCtx {
            AVCodecContext *dec = nullptr;
            AVCodecContext *enc = nullptr;
            int outIndex        = -1; // индекс в выходном контексте
        };

        // Кодировать готовый AVFrame (или flush при frame==nullptr) и записать.
        bool encodeWrite(AVFormatContext *ofmt, AVCodecContext *enc, int outIdx, AVFrame *frame,
                         AVPacket *pkt, QString *error)
        {
            int ret = avcodec_send_frame(enc, frame);
            if (ret < 0) {
                setErr(error, QStringLiteral("send_frame: %1").arg(avErr(ret)));
                return false;
            }
            while (ret >= 0) {
                ret = avcodec_receive_packet(enc, pkt);
                if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF)
                    return true;
                if (ret < 0) {
                    setErr(error, QStringLiteral("receive_packet: %1").arg(avErr(ret)));
                    return false;
                }
                pkt->stream_index = outIdx;
                av_packet_rescale_ts(pkt, enc->time_base, ofmt->streams[outIdx]->time_base);
                ret = av_interleaved_write_frame(ofmt, pkt);
                av_packet_unref(pkt);
                if (ret < 0) {
                    setErr(error, QStringLiteral("write_frame: %1").arg(avErr(ret)));
                    return false;
                }
            }
            return true;
        }
    } // namespace

    bool VideoTranscoder::transcode(const QString &inputPath, const QString &outputPath,
                                    const std::function<void(double)> &progress, QString *error,
                                    Options opt)
    {
        AVFormatContext *ifmt = nullptr;
        AVFormatContext *ofmt = nullptr;
        int ret               = avformat_open_input(&ifmt, inputPath.toUtf8().constData(), nullptr, nullptr);
        if (ret < 0) {
            setErr(error, QStringLiteral("open_input: %1").arg(avErr(ret)));
            return false;
        }
        if ((ret = avformat_find_stream_info(ifmt, nullptr)) < 0) {
            setErr(error, QStringLiteral("find_stream_info: %1").arg(avErr(ret)));
            avformat_close_input(&ifmt);
            return false;
        }

        bool ok = false;
        StreamCtx vid;
        StreamCtx aud;
        int vInIdx          = -1;
        int aInIdx          = -1;
        SwsContext *sws     = nullptr;
        SwrContext *swr     = nullptr;
        AVAudioFifo *fifo   = nullptr;
        AVFrame *decFrame   = av_frame_alloc();
        AVFrame *scaled     = av_frame_alloc();
        AVFrame *aEncFrame  = av_frame_alloc();
        AVPacket *pkt       = av_packet_alloc();
        AVPacket *outPkt    = av_packet_alloc();
        int64_t aPts        = 0; // монотонный pts аудио-энкодера (в его sample_rate)

        // Общая длительность для прогресса.
        double durationSec = ifmt->duration > 0 ? static_cast<double>(ifmt->duration) / AV_TIME_BASE : 0.0;

        avformat_alloc_output_context2(&ofmt, nullptr, "mp4", outputPath.toUtf8().constData());
        if (!ofmt) {
            setErr(error, QStringLiteral("alloc_output_context (mp4) failed"));
            goto cleanup;
        }

        vInIdx = av_find_best_stream(ifmt, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
        aInIdx = av_find_best_stream(ifmt, AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0);
        if (vInIdx < 0) {
            setErr(error, QStringLiteral("no video stream"));
            goto cleanup;
        }

        // ── Видео: декодер ──
        {
            AVStream *st       = ifmt->streams[vInIdx];
            const AVCodec *cod = avcodec_find_decoder(st->codecpar->codec_id);
            if (!cod) {
                setErr(error, QStringLiteral("no video decoder"));
                goto cleanup;
            }
            vid.dec = avcodec_alloc_context3(cod);
            avcodec_parameters_to_context(vid.dec, st->codecpar);
            vid.dec->pkt_timebase = st->time_base;
            // Многопоточный декод: родной h264-декодер хорошо параллелится по
            // кадрам/слайсам — это половина стоимости транскода. 0 = по числу
            // ядер. Обязательно ДО avcodec_open2.
            vid.dec->thread_count = 0;
            vid.dec->thread_type  = FF_THREAD_FRAME | FF_THREAD_SLICE;
            if ((ret = avcodec_open2(vid.dec, cod, nullptr)) < 0) {
                setErr(error, QStringLiteral("open video decoder: %1").arg(avErr(ret)));
                goto cleanup;
            }

            int dstW, dstH;
            targetSize(vid.dec->width, vid.dec->height, opt.maxDimension, dstW, dstH);

            const AVCodec *venc = findH264Encoder();
            if (!venc) {
                setErr(error, QStringLiteral("no H.264 encoder"));
                goto cleanup;
            }
            vid.enc            = avcodec_alloc_context3(venc);
            vid.enc->width     = dstW;
            vid.enc->height    = dstH;
            vid.enc->pix_fmt   = AV_PIX_FMT_YUV420P;
            vid.enc->bit_rate  = opt.videoBitrateBps > 0 ? opt.videoBitrateBps : autoVideoBitrate(dstW, dstH);
            vid.enc->time_base = st->time_base; // pts кадров passthrough в шкале источника
            vid.enc->framerate = st->avg_frame_rate.num ? st->avg_frame_rate : AVRational{30, 1};
            vid.enc->gop_size  = 60;
            vid.enc->max_b_frames = 0; // openh264 без B-кадров
            // Многопоточный энкод: libopenh264 параллелит кодирование по слайсам
            // через thread_count (iMultipleThreadIdc). Без этого энкод упирается
            // в одно ядро — главный тормоз подготовки видео. libx264 (с его
            // preset'ами) недоступен намеренно — он GPL, а наш ffmpeg собран
            // только с BSD-libopenh264. Потолок 8: лишние слайсы режут качество
            // при том же битрейте без выигрыша по скорости на типовых видео.
            vid.enc->thread_count = std::clamp(QThread::idealThreadCount(), 1, 8);
            vid.enc->sample_aspect_ratio = vid.dec->sample_aspect_ratio;
            if (ofmt->oformat->flags & AVFMT_GLOBALHEADER)
                vid.enc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
            if ((ret = avcodec_open2(vid.enc, venc, nullptr)) < 0) {
                setErr(error, QStringLiteral("open H.264 encoder: %1").arg(avErr(ret)));
                goto cleanup;
            }

            AVStream *out = avformat_new_stream(ofmt, nullptr);
            avcodec_parameters_from_context(out->codecpar, vid.enc);
            out->time_base = vid.enc->time_base;
            vid.outIndex   = out->index;

            // Перенос display-matrix (поворот) исходника в выходной mp4 — иначе
            // portrait-видео телефона проигрывается повёрнутым на 90°. Плеер
            // (Qt/AVFoundation/Android) сам применит поворот при показе.
            const AVPacketSideData *dm = av_packet_side_data_get(
                st->codecpar->coded_side_data, st->codecpar->nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX);
            if (dm && dm->size >= 9 * sizeof(int32_t)) {
                uint8_t *copy = static_cast<uint8_t *>(av_memdup(dm->data, dm->size));
                if (copy
                    && !av_packet_side_data_add(&out->codecpar->coded_side_data,
                                                &out->codecpar->nb_coded_side_data,
                                                AV_PKT_DATA_DISPLAYMATRIX, copy, dm->size, 0))
                    av_free(copy);
            }

            // SWS_FAST_BILINEAR заметно быстрее SWS_BILINEAR при практически
            // неразличимом на видео качестве масштабирования.
            sws = sws_getContext(vid.dec->width, vid.dec->height, vid.dec->pix_fmt, dstW, dstH,
                                 AV_PIX_FMT_YUV420P, SWS_FAST_BILINEAR, nullptr, nullptr, nullptr);
            if (!sws) {
                setErr(error, QStringLiteral("sws_getContext failed"));
                goto cleanup;
            }
            scaled->format = AV_PIX_FMT_YUV420P;
            scaled->width  = dstW;
            scaled->height = dstH;
            if ((ret = av_frame_get_buffer(scaled, 0)) < 0) {
                setErr(error, QStringLiteral("scaled frame buffer: %1").arg(avErr(ret)));
                goto cleanup;
            }
        }

        // ── Аудио: декодер + AAC-энкодер + ресемпл + FIFO (если есть дорожка) ──
        if (aInIdx >= 0) {
            AVStream *st       = ifmt->streams[aInIdx];
            const AVCodec *cod = avcodec_find_decoder(st->codecpar->codec_id);
            const AVCodec *aenc = avcodec_find_encoder(AV_CODEC_ID_AAC);
            if (cod && aenc) {
                aud.dec = avcodec_alloc_context3(cod);
                avcodec_parameters_to_context(aud.dec, st->codecpar);
                aud.dec->pkt_timebase = st->time_base;
                if (avcodec_open2(aud.dec, cod, nullptr) < 0) {
                    avcodec_free_context(&aud.dec);
                    aud.dec = nullptr;
                }
            }
            if (aud.dec) {
                int outRate = aud.dec->sample_rate > 0 ? aud.dec->sample_rate : 48000;
                aud.enc     = avcodec_alloc_context3(aenc);
                aud.enc->sample_fmt  = AV_SAMPLE_FMT_FLTP; // нативный AAC-энкодер
                aud.enc->sample_rate = outRate;
                aud.enc->bit_rate    = opt.audioBitrateBps;
                // Downmix к стерео (или моно, если источник моно).
                int outCh = std::min(2, aud.dec->ch_layout.nb_channels > 0 ? aud.dec->ch_layout.nb_channels : 2);
                av_channel_layout_default(&aud.enc->ch_layout, outCh);
                aud.enc->time_base = AVRational{1, outRate};
                if (ofmt->oformat->flags & AVFMT_GLOBALHEADER)
                    aud.enc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
                if (avcodec_open2(aud.enc, aenc, nullptr) < 0) {
                    avcodec_free_context(&aud.enc);
                    avcodec_free_context(&aud.dec);
                    aud.enc = aud.dec = nullptr;
                } else {
                    AVStream *out = avformat_new_stream(ofmt, nullptr);
                    avcodec_parameters_from_context(out->codecpar, aud.enc);
                    out->time_base = aud.enc->time_base;
                    aud.outIndex   = out->index;

                    swr_alloc_set_opts2(&swr, &aud.enc->ch_layout, aud.enc->sample_fmt, aud.enc->sample_rate,
                                        &aud.dec->ch_layout, aud.dec->sample_fmt, aud.dec->sample_rate, 0, nullptr);
                    if (!swr || swr_init(swr) < 0) {
                        setErr(error, QStringLiteral("swr_init failed (audio dropped)"));
                        if (swr) swr_free(&swr);
                        avcodec_free_context(&aud.enc);
                        avcodec_free_context(&aud.dec);
                        aud.enc = aud.dec = nullptr;
                    } else {
                        fifo = av_audio_fifo_alloc(aud.enc->sample_fmt, aud.enc->ch_layout.nb_channels, 1);
                    }
                }
            }
        }

        if ((ret = avio_open(&ofmt->pb, outputPath.toUtf8().constData(), AVIO_FLAG_WRITE)) < 0) {
            setErr(error, QStringLiteral("avio_open: %1").arg(avErr(ret)));
            goto cleanup;
        }
        {
            // faststart — moov-атом в начало файла для прогрессивного проигрывания.
            AVDictionary *muxOpts = nullptr;
            av_dict_set(&muxOpts, "movflags", "+faststart", 0);
            ret = avformat_write_header(ofmt, &muxOpts);
            av_dict_free(&muxOpts);
            if (ret < 0) {
                setErr(error, QStringLiteral("write_header: %1").arg(avErr(ret)));
                goto cleanup;
            }
        }

        // ── Главный цикл демукс→транскод ──
        while (av_read_frame(ifmt, pkt) >= 0) {
            const bool isVideo = pkt->stream_index == vInIdx;
            const bool isAudio = aud.enc && pkt->stream_index == aInIdx;
            if (isVideo) {
                if (avcodec_send_packet(vid.dec, pkt) >= 0) {
                    while (avcodec_receive_frame(vid.dec, decFrame) >= 0) {
                        if (av_frame_make_writable(scaled) < 0)
                            break;
                        sws_scale(sws, decFrame->data, decFrame->linesize, 0, vid.dec->height,
                                  scaled->data, scaled->linesize);
                        scaled->pts = decFrame->best_effort_timestamp;
                        if (durationSec > 0 && progress && scaled->pts != AV_NOPTS_VALUE) {
                            double t = scaled->pts * av_q2d(ifmt->streams[vInIdx]->time_base);
                            progress(std::clamp(t / durationSec, 0.0, 1.0));
                        }
                        if (!encodeWrite(ofmt, vid.enc, vid.outIndex, scaled, outPkt, error))
                            goto cleanup;
                        av_frame_unref(decFrame);
                    }
                }
            } else if (isAudio) {
                if (avcodec_send_packet(aud.dec, pkt) >= 0) {
                    while (avcodec_receive_frame(aud.dec, decFrame) >= 0) {
                        // Ресемпл в формат энкодера → FIFO.
                        uint8_t **conv = nullptr;
                        int outSamples = swr_get_out_samples(swr, decFrame->nb_samples);
                        av_samples_alloc_array_and_samples(&conv, nullptr, aud.enc->ch_layout.nb_channels,
                                                           outSamples, aud.enc->sample_fmt, 0);
                        int n = swr_convert(swr, conv, outSamples,
                                            const_cast<const uint8_t **>(decFrame->extended_data),
                                            decFrame->nb_samples);
                        if (n > 0) {
                            av_audio_fifo_realloc(fifo, av_audio_fifo_size(fifo) + n);
                            av_audio_fifo_write(fifo, reinterpret_cast<void **>(conv), n);
                        }
                        if (conv)
                            av_freep(&conv[0]);
                        av_freep(&conv);
                        av_frame_unref(decFrame);

                        // Выдаём полные кадры frame_size в энкодер.
                        const int fsize = aud.enc->frame_size > 0 ? aud.enc->frame_size : 1024;
                        while (av_audio_fifo_size(fifo) >= fsize) {
                            av_frame_unref(aEncFrame);
                            aEncFrame->nb_samples = fsize;
                            aEncFrame->format     = aud.enc->sample_fmt;
                            av_channel_layout_copy(&aEncFrame->ch_layout, &aud.enc->ch_layout);
                            aEncFrame->sample_rate = aud.enc->sample_rate;
                            if (av_frame_get_buffer(aEncFrame, 0) < 0)
                                break;
                            av_audio_fifo_read(fifo, reinterpret_cast<void **>(aEncFrame->data), fsize);
                            aEncFrame->pts = aPts;
                            aPts += fsize;
                            if (!encodeWrite(ofmt, aud.enc, aud.outIndex, aEncFrame, outPkt, error))
                                goto cleanup;
                        }
                    }
                }
            }
            av_packet_unref(pkt);
        }

        // Flush аудио-остатка из FIFO.
        if (aud.enc && fifo && av_audio_fifo_size(fifo) > 0) {
            int rem = av_audio_fifo_size(fifo);
            av_frame_unref(aEncFrame);
            aEncFrame->nb_samples = rem;
            aEncFrame->format     = aud.enc->sample_fmt;
            av_channel_layout_copy(&aEncFrame->ch_layout, &aud.enc->ch_layout);
            aEncFrame->sample_rate = aud.enc->sample_rate;
            if (av_frame_get_buffer(aEncFrame, 0) >= 0) {
                av_audio_fifo_read(fifo, reinterpret_cast<void **>(aEncFrame->data), rem);
                aEncFrame->pts = aPts;
                encodeWrite(ofmt, aud.enc, aud.outIndex, aEncFrame, outPkt, error);
            }
        }

        // Flush энкодеров.
        encodeWrite(ofmt, vid.enc, vid.outIndex, nullptr, outPkt, error);
        if (aud.enc)
            encodeWrite(ofmt, aud.enc, aud.outIndex, nullptr, outPkt, error);

        if ((ret = av_write_trailer(ofmt)) < 0) {
            setErr(error, QStringLiteral("write_trailer: %1").arg(avErr(ret)));
            goto cleanup;
        }
        if (progress)
            progress(1.0);
        ok = true;

    cleanup:
        if (sws)
            sws_freeContext(sws);
        if (swr)
            swr_free(&swr);
        if (fifo)
            av_audio_fifo_free(fifo);
        av_frame_free(&decFrame);
        av_frame_free(&scaled);
        av_frame_free(&aEncFrame);
        av_packet_free(&pkt);
        av_packet_free(&outPkt);
        if (vid.dec)
            avcodec_free_context(&vid.dec);
        if (vid.enc)
            avcodec_free_context(&vid.enc);
        if (aud.dec)
            avcodec_free_context(&aud.dec);
        if (aud.enc)
            avcodec_free_context(&aud.enc);
        if (ofmt) {
            if (ofmt->pb)
                avio_closep(&ofmt->pb);
            avformat_free_context(ofmt);
        }
        avformat_close_input(&ifmt);
        return ok;
    }

} // namespace paranoia::media
