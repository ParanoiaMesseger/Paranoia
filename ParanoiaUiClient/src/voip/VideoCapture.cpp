#include "VideoCapture.hpp"

#include <QCameraDevice>
#include <QDebug>
#include <QMediaDevices>
#include <QVideoFrameFormat>
#include <cstring>

#include "H264Codec.hpp"

extern "C" {
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <libavutil/frame.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libavutil/pixfmt.h>
}

namespace paranoia::voip
{

    namespace
    {

        AVPixelFormat qtToAvPix(QVideoFrameFormat::PixelFormat qt)
        {
            switch (qt) {
                case QVideoFrameFormat::Format_YUV420P: return AV_PIX_FMT_YUV420P;
                case QVideoFrameFormat::Format_YV12: return AV_PIX_FMT_YUV420P; // swap U/V handled by caller
                case QVideoFrameFormat::Format_NV12: return AV_PIX_FMT_NV12;
                case QVideoFrameFormat::Format_NV21: return AV_PIX_FMT_NV21;
                case QVideoFrameFormat::Format_UYVY: return AV_PIX_FMT_UYVY422;
                case QVideoFrameFormat::Format_YUYV: return AV_PIX_FMT_YUYV422;
                case QVideoFrameFormat::Format_BGRA8888:
                case QVideoFrameFormat::Format_BGRX8888: return AV_PIX_FMT_BGRA;
                case QVideoFrameFormat::Format_ARGB8888:
                case QVideoFrameFormat::Format_XRGB8888: return AV_PIX_FMT_ARGB;
                case QVideoFrameFormat::Format_RGBA8888:
                case QVideoFrameFormat::Format_RGBX8888: return AV_PIX_FMT_RGBA;
                default: return AV_PIX_FMT_NONE;
            }
        }

        /// Минимальный libavfilter-граф для нашего video-pipeline'а:
        /// input (любой пиксельный формат камеры) → format(yuv420p) → optional
        /// hflip/vflip/transpose → scale (aspect-preserve) → pad до целевого
        /// разрешения (letterbox чёрным) → output (yuv420p).
        ///
        /// Граф собирается один раз при первом валидном кадре и переиспользуется,
        /// пока не изменятся src dims, src pix_fmt, rotation или mirror. Тогда
        /// `configure` пересоздаёт граф.
        class FilterGraph
        {
        public:
            FilterGraph() = default;
            ~FilterGraph() { reset(); }
            FilterGraph(const FilterGraph &)            = delete;
            FilterGraph &operator=(const FilterGraph &) = delete;

            bool configure(int sw, int sh, AVPixelFormat src_fmt, int dw, int dh, QtVideo::Rotation rot, bool mirror)
            {
                if (graph_ && sw == last_sw_ && sh == last_sh_ && src_fmt == last_fmt_ && dw == last_dw_ &&
                    dh == last_dh_ && rot == last_rot_ && mirror == last_mirror_) {
                    return true;
                }
                reset();

                graph_ = avfilter_graph_alloc();
                if (!graph_) return false;

                const AVFilter *bufsrc  = avfilter_get_by_name("buffer");
                const AVFilter *bufsink = avfilter_get_by_name("buffersink");
                if (!bufsrc || !bufsink) {
                    qWarning() << "FilterGraph: buffer/buffersink not registered (avfilter missing?)";
                    reset();
                    return false;
                }

                // Input buffer: video_size, pix_fmt, time_base, pixel_aspect.
                char buf_args[256];
                std::snprintf(buf_args, sizeof(buf_args),
                              "video_size=%dx%d:pix_fmt=%d:time_base=1/90000:pixel_aspect=1/1", sw, sh,
                              static_cast<int>(src_fmt));
                int ret = avfilter_graph_create_filter(&src_ctx_, bufsrc, "in", buf_args, nullptr, graph_);
                if (ret < 0) {
                    qWarning() << "FilterGraph: failed to create input buffer:" << ret;
                    reset();
                    return false;
                }

                ret = avfilter_graph_create_filter(&sink_ctx_, bufsink, "out", nullptr, nullptr, graph_);
                if (ret < 0) {
                    qWarning() << "FilterGraph: failed to create output buffersink:" << ret;
                    reset();
                    return false;
                }
                const enum AVPixelFormat sink_pix_fmts[] = {AV_PIX_FMT_YUV420P, AV_PIX_FMT_NONE};
                ret = av_opt_set_int_list(sink_ctx_, "pix_fmts", sink_pix_fmts, AV_PIX_FMT_NONE,
                                          AV_OPT_SEARCH_CHILDREN);
                if (ret < 0) {
                    qWarning() << "FilterGraph: failed to set sink pix_fmts:" << ret;
                    reset();
                    return false;
                }

                // Описание цепочки фильтров. Порядок согласно best-practice:
                // 1. format=yuv420p — приводим вход к каноническому планарному YUV;
                //    дальше rotation/scale работает с предсказуемым форматом.
                // 2. transpose+vflip+hflip — поворот и mirror (если нужны).
                // 3. scale — aspect-preserve, чтобы не растягивать содержимое.
                // 4. pad — letterbox чёрными полосами до точного целевого размера.
                QString chain = QStringLiteral("format=yuv420p");

                // transpose values:
                //   0 = 90° CCW + flip, 1 = 90° CW, 2 = 90° CCW, 3 = 90° CW + flip
                // QtVideo::Rotation values are clockwise degrees.
                switch (rot) {
                    case QtVideo::Rotation::Clockwise90:
                        chain += QStringLiteral(",transpose=1");
                        break;
                    case QtVideo::Rotation::Clockwise180:
                        // 180° = vflip + hflip (быстрее, чем два transpose).
                        chain += QStringLiteral(",vflip,hflip");
                        break;
                    case QtVideo::Rotation::Clockwise270:
                        chain += QStringLiteral(",transpose=2");
                        break;
                    case QtVideo::Rotation::None:
                    default:
                        break;
                }
                if (mirror) chain += QStringLiteral(",hflip");

                // scale до dw×dh с force_original_aspect_ratio=decrease — крупнейший
                // размер прижимается к ограничению, второй пропорционально уменьшается.
                // Затем pad добавляет чёрные полосы до точного dw×dh.
                chain += QString::fromLatin1(",scale=%1:%2:force_original_aspect_ratio=decrease:flags=fast_bilinear")
                             .arg(dw)
                             .arg(dh);
                chain += QString::fromLatin1(",pad=%1:%2:(ow-iw)/2:(oh-ih)/2:black").arg(dw).arg(dh);

                AVFilterInOut *outputs = avfilter_inout_alloc();
                AVFilterInOut *inputs  = avfilter_inout_alloc();
                if (!outputs || !inputs) {
                    if (outputs) avfilter_inout_free(&outputs);
                    if (inputs) avfilter_inout_free(&inputs);
                    reset();
                    return false;
                }
                outputs->name       = av_strdup("in");
                outputs->filter_ctx = src_ctx_;
                outputs->pad_idx    = 0;
                outputs->next       = nullptr;
                inputs->name        = av_strdup("out");
                inputs->filter_ctx  = sink_ctx_;
                inputs->pad_idx     = 0;
                inputs->next        = nullptr;

                ret = avfilter_graph_parse_ptr(graph_, chain.toUtf8().constData(), &inputs, &outputs, nullptr);
                avfilter_inout_free(&outputs);
                avfilter_inout_free(&inputs);
                if (ret < 0) {
                    qWarning() << "FilterGraph: parse failed:" << ret << "chain:" << chain;
                    reset();
                    return false;
                }

                ret = avfilter_graph_config(graph_, nullptr);
                if (ret < 0) {
                    qWarning() << "FilterGraph: config failed:" << ret;
                    reset();
                    return false;
                }

                last_sw_     = sw;
                last_sh_     = sh;
                last_fmt_    = src_fmt;
                last_dw_     = dw;
                last_dh_     = dh;
                last_rot_    = rot;
                last_mirror_ = mirror;
                return true;
            }

            // Push src frame, pop dst frame. Both must be allocated by caller.
            bool process(AVFrame *src, AVFrame *dst)
            {
                if (!src_ctx_ || !sink_ctx_) return false;
                int ret = av_buffersrc_add_frame_flags(src_ctx_, src, AV_BUFFERSRC_FLAG_KEEP_REF);
                if (ret < 0) return false;
                ret = av_buffersink_get_frame(sink_ctx_, dst);
                return ret >= 0;
            }

            void reset()
            {
                if (graph_) avfilter_graph_free(&graph_); // frees src_ctx_, sink_ctx_ too
                graph_       = nullptr;
                src_ctx_     = nullptr;
                sink_ctx_    = nullptr;
                last_sw_     = 0;
                last_sh_     = 0;
                last_fmt_    = AV_PIX_FMT_NONE;
                last_dw_     = 0;
                last_dh_     = 0;
                last_rot_    = QtVideo::Rotation::None;
                last_mirror_ = false;
            }

        private:
            AVFilterGraph *graph_       = nullptr;
            AVFilterContext *src_ctx_   = nullptr;
            AVFilterContext *sink_ctx_  = nullptr;
            int last_sw_                = 0;
            int last_sh_                = 0;
            AVPixelFormat last_fmt_     = AV_PIX_FMT_NONE;
            int last_dw_                = 0;
            int last_dh_                = 0;
            QtVideo::Rotation last_rot_ = QtVideo::Rotation::None;
            bool last_mirror_           = false;
        };

    } // namespace

    struct VideoCapture::FilterState {
        FilterGraph graph;
        AVFrame *in  = nullptr;
        AVFrame *out = nullptr;
        FilterState()
        {
            in  = av_frame_alloc();
            out = av_frame_alloc();
        }
        ~FilterState()
        {
            if (in) av_frame_free(&in);
            if (out) av_frame_free(&out);
        }
    };

    VideoCapture::VideoCapture(QObject *parent)
        : QObject(parent), session_(std::make_unique<QMediaCaptureSession>(this)),
          sink_(std::make_unique<QVideoSink>(this)), filter_(std::make_unique<FilterState>())
    {
        connect(sink_.get(), &QVideoSink::videoFrameChanged, this, &VideoCapture::onVideoFrame);
        session_->setVideoSink(sink_.get());
    }

    VideoCapture::~VideoCapture() { stop(); }

    bool VideoCapture::hasMultipleCameras() { return QMediaDevices::videoInputs().size() > 1; }

    bool VideoCapture::switchCamera()
    {
        const auto cams = QMediaDevices::videoInputs();
        if (cams.size() < 2) return false;
        int currentIdx = -1;
        for (int i = 0; i < cams.size(); ++i) {
            if (cams[i].id() == current_camera_id_) {
                currentIdx = i;
                break;
            }
        }
        const QCameraDevice &next = cams[(currentIdx + 1) % cams.size()];
        if (camera_) {
            camera_->stop();
            camera_.reset();
        }
        first_frame_us_ = -1;
        // ВАЖНО: dst_w_/dst_h_ НЕ сбрасываем — выходное разрешение и
        // ориентация энкодера фиксируются на первом кадре первой камеры и
        // остаются постоянными до конца сессии. Это нужно потому что:
        //  1) h264_encoder_ был инициализирован под фиксированные димы и
        //     не переинициализируется на лету (hw-кодеки, особенно Android
        //     MediaCodec, не любят смену размеров посреди потока);
        //  2) при смене на камеру с другим аспектом фильтр-graph выполнит
        //     letterbox (scale=...:force_original_aspect_ratio=decrease + pad)
        //     к фиксированному dst — кадр впишется в чёрные поля, а не сломает
        //     pipeline. На реальных устройствах ориентация всё равно
        //     заблокирована — обе камеры выдают portrait, letterbox срабатывает
        //     только в редких краевых случаях.
        // Если когда-нибудь захочется поддерживать смену ориентации — нужно
        // либо реинит энкодера здесь, либо отдельный keyframe-протокол.
        if (filter_) filter_->graph.reset();
        return startCamera(next);
    }

    bool VideoCapture::start()
    {
        if (camera_) return true;
        const auto cams = QMediaDevices::videoInputs();
        if (cams.isEmpty()) {
            emit error(QStringLiteral("no camera devices"));
            return false;
        }
        QCameraDevice chosen = cams.first();
        for (const auto &c : cams) {
            if (c.position() == QCameraDevice::FrontFace) {
                chosen = c;
                break;
            }
        }
        return startCamera(chosen);
    }

    bool VideoCapture::startCamera(const QCameraDevice &chosen)
    {
        current_camera_id_ = chosen.id();
        camera_            = std::make_unique<QCamera>(chosen);
        QCameraFormat best;
        int best_score = -1;
        for (const auto &f : chosen.videoFormats()) {
            const auto fps  = f.maxFrameRate();
            const auto &res = f.resolution();
            if (res.width() <= 0 || res.height() <= 0) continue;
            const int dx   = std::abs(res.width() - VideoFormat::kWidth);
            const int dy   = std::abs(res.height() - VideoFormat::kHeight);
            const int dfps = static_cast<int>(std::abs(fps - VideoFormat::kFrameRate));
            const bool yuv = (f.pixelFormat() == QVideoFrameFormat::Format_YUV420P ||
                              f.pixelFormat() == QVideoFrameFormat::Format_NV12 ||
                              f.pixelFormat() == QVideoFrameFormat::Format_NV21 ||
                              f.pixelFormat() == QVideoFrameFormat::Format_YUYV ||
                              f.pixelFormat() == QVideoFrameFormat::Format_UYVY);
            int score = 100000 - (dx + dy) * 10 - dfps * 100;
            if (yuv) score += 5000;
            if (score > best_score) {
                best_score = score;
                best       = f;
            }
        }
        if (best.resolution().isValid()) { camera_->setCameraFormat(best); }
        session_->setCamera(camera_.get());
        connect(camera_.get(), &QCamera::errorOccurred, this, [this](QCamera::Error err, const QString &msg) {
            if (err == QCamera::NoError) return;
            emit error(
                QStringLiteral("camera error: %1").arg(msg.isEmpty() ? QStringLiteral("code %1").arg(int(err)) : msg));
        });
        camera_->start();
        if (camera_->error() != QCamera::NoError) {
            emit error(QStringLiteral("camera start failed: %1").arg(camera_->errorString()));
            return false;
        }
        return true;
    }

    void VideoCapture::stop()
    {
        if (camera_) {
            camera_->stop();
            camera_.reset();
        }
        first_frame_us_ = -1;
        dst_w_          = 0;
        dst_h_          = 0;
        if (filter_) filter_->graph.reset();
    }

    bool VideoCapture::isActive() const { return camera_ && camera_->isActive(); }

    void VideoCapture::onVideoFrame(const QVideoFrame &cf)
    {
        if (!cf.isValid()) return;

        // PTS: 90 кГц RTP-шкала.
        const qint64 now_us = cf.startTime();
        if (first_frame_us_ < 0 || now_us < 0) { first_frame_us_ = (now_us >= 0) ? now_us : 0; }
        const qint64 elapsed_us = (now_us >= 0) ? (now_us - first_frame_us_) : 0;
        const qint64 pts_90k    = (elapsed_us * 90 + 500) / 1000;

        QVideoFrame frame = cf;
        if (!frame.map(QVideoFrame::ReadOnly)) {
            qWarning() << "VideoCapture: failed to map QVideoFrame";
            return;
        }

        const int sw                  = frame.width();
        const int sh                  = frame.height();
        const auto qtfmt              = frame.pixelFormat();
        const AVPixelFormat src_fmt   = qtToAvPix(qtfmt);
        if (src_fmt == AV_PIX_FMT_NONE || sw <= 0 || sh <= 0) {
            frame.unmap();
            return;
        }

        // ── libavfilter pipeline: format → [transpose/flip] → scale → pad → yuv420p
        // Один сквозной проход, минимум копий, hw-friendly через swscale внутри scale-фильтра.
        const QtVideo::Rotation rot   = cf.rotation();
        const bool mirrored           = cf.mirrored();
        const QVideoFrameFormat &sFmt = cf.surfaceFormat();
        // Если у surfaceFormat задан свой rotation/mirror — комбинируем (toImage
        // в Qt 6.10 учитывает только surfaceFormat-преобразования; здесь делаем
        // явно, поверх per-frame).
        QtVideo::Rotation total_rot = rot;
        // (rot += sFmt.rotation()) % 360 — нет арифметики на enum, делаем руками.
        const int rot_total_deg =
            (static_cast<int>(rot) + static_cast<int>(sFmt.rotation())) % 360;
        switch (rot_total_deg) {
            case 90: total_rot  = QtVideo::Rotation::Clockwise90; break;
            case 180: total_rot = QtVideo::Rotation::Clockwise180; break;
            case 270: total_rot = QtVideo::Rotation::Clockwise270; break;
            default: total_rot  = QtVideo::Rotation::None; break;
        }
        const bool total_mirror = mirrored ^ sFmt.isMirrored();

        // Эффективные размеры источника после rotation: для 90°/270° меняем
        // width/height местами. По их аспекту выбираем target-разрешение —
        // 720×1280 (portrait) или 1280×720 (landscape). Это решение
        // фиксируется на первом кадре сессии: ре-init энкодера по ходу
        // звонка опасен (mediacodec не любит смену размеров).
        if (dst_w_ == 0 || dst_h_ == 0) {
            const bool swap_dims     = (total_rot == QtVideo::Rotation::Clockwise90 ||
                                    total_rot == QtVideo::Rotation::Clockwise270);
            const int effective_w    = swap_dims ? sh : sw;
            const int effective_h    = swap_dims ? sw : sh;
            const bool portrait_out  = effective_h > effective_w;
            dst_w_ = portrait_out ? VideoFormat::kHeight : VideoFormat::kWidth; // 720 или 1280
            dst_h_ = portrait_out ? VideoFormat::kWidth : VideoFormat::kHeight; // 1280 или 720
            emit dimensionsReady(dst_w_, dst_h_);
        }
        const int dw = dst_w_;
        const int dh = dst_h_;

        if (!filter_->graph.configure(sw, sh, src_fmt, dw, dh, total_rot, total_mirror)) {
            qWarning() << "VideoCapture: filter graph configure failed";
            frame.unmap();
            return;
        }

        // Заполняем входной AVFrame данными от QVideoFrame. Не копируем — просто
        // выставляем указатели и линeisize'ы.
        AVFrame *in = filter_->in;
        av_frame_unref(in);
        in->format = src_fmt;
        in->width  = sw;
        in->height = sh;
        in->pts    = pts_90k;
        for (int p = 0; p < frame.planeCount() && p < AV_NUM_DATA_POINTERS; ++p) {
            in->data[p]     = const_cast<uint8_t *>(frame.bits(p));
            in->linesize[p] = frame.bytesPerLine(p);
        }
        // YV12 → swap U/V (наш qtfmt-mapping отдаёт YUV420P, но layout у QFrame с YV12).
        if (qtfmt == QVideoFrameFormat::Format_YV12 && frame.planeCount() >= 3) {
            std::swap(in->data[1], in->data[2]);
            std::swap(in->linesize[1], in->linesize[2]);
        }

        AVFrame *out = filter_->out;
        av_frame_unref(out);
        if (!filter_->graph.process(in, out)) {
            frame.unmap();
            return;
        }
        // unmap входа можно после process — выходной кадр у нас уже свой.
        frame.unmap();

        // Копируем планы выхода (yuv420p, dw×dh) в плоский I420-буфер для FFI и
        // в QVideoFrame preview. И то, и другое использует один и тот же
        // буфер — без дублирования работы.
        if (out->format != AV_PIX_FMT_YUV420P || out->width != dw || out->height != dh) {
            qWarning() << "VideoCapture: unexpected filter output format" << out->format << out->width << "x"
                       << out->height;
            return;
        }

        QByteArray packed(dw * dh * 3 / 2, Qt::Uninitialized);
        uint8_t *p = reinterpret_cast<uint8_t *>(packed.data());
        // Y plane
        for (int r = 0; r < dh; ++r) std::memcpy(p + r * dw, out->data[0] + r * out->linesize[0], dw);
        p += dw * dh;
        // U plane
        for (int r = 0; r < dh / 2; ++r) std::memcpy(p + r * (dw / 2), out->data[1] + r * out->linesize[1], dw / 2);
        p += (dw / 2) * (dh / 2);
        // V plane
        for (int r = 0; r < dh / 2; ++r) std::memcpy(p + r * (dw / 2), out->data[2] + r * out->linesize[2], dw / 2);

        // Preview: тот же кадр, без дополнительного процессинга. Конструируем
        // QVideoFrame с YUV420P-форматом и копируем плоскости (Qt может
        // выровнять bytesPerLine, поэтому не memcpy всё разом).
        if (preview_sink_) {
            QVideoFrameFormat pvfmt(QSize(dw, dh), QVideoFrameFormat::Format_YUV420P);
            QVideoFrame pv(pvfmt);
            if (pv.map(QVideoFrame::WriteOnly)) {
                const uint8_t *src = reinterpret_cast<const uint8_t *>(packed.constData());
                uint8_t *py        = pv.bits(0);
                uint8_t *pu        = pv.bits(1);
                uint8_t *pv_       = pv.bits(2);
                const int sy       = pv.bytesPerLine(0);
                const int su       = pv.bytesPerLine(1);
                const int sv       = pv.bytesPerLine(2);
                for (int r = 0; r < dh; ++r) std::memcpy(py + r * sy, src + r * dw, dw);
                src += dw * dh;
                for (int r = 0; r < dh / 2; ++r) std::memcpy(pu + r * su, src + r * (dw / 2), dw / 2);
                src += (dw / 2) * (dh / 2);
                for (int r = 0; r < dh / 2; ++r) std::memcpy(pv_ + r * sv, src + r * (dw / 2), dw / 2);
                pv.unmap();
                preview_sink_->setVideoFrame(pv);
            }
        }

        emit frameReady(packed, pts_90k);
    }

} // namespace paranoia::voip
