#include "CallEngine.hpp"

#include <QMetaObject>
#include <QMutexLocker>
#include <QVideoSink>
#include <QVariant>
#include <cstring>
#include <ParanoiaFFI>
#if defined(Q_OS_ANDROID)
#include <QCoreApplication>
#include <QJniEnvironment>
#include <QJniObject>
#endif
#if defined(Q_OS_IOS)
#include "IosAudioSession.hpp"
#include <QCoreApplication>
#include <QPermissions>
#include <QPointer>
#endif

namespace paranoia::voip
{

    namespace
    {

        void onIncomingFrame(void *userdata, const unsigned char *opus, size_t len, uint64_t sequence)
        {
            if (!userdata) return;
            auto *engine = static_cast<CallEngine *>(userdata);
            QByteArray data;
            if (opus && len > 0) { data = QByteArray(reinterpret_cast<const char *>(opus), static_cast<int>(len)); }
            QMetaObject::invokeMethod(engine, "enqueueIncomingFrame", Qt::QueuedConnection, Q_ARG(QByteArray, data),
                                      Q_ARG(quint64, static_cast<quint64>(sequence)));
        }

        void onIncomingVideoFragment(void *userdata, const unsigned char *nal, size_t len, uint64_t sequence,
                                     unsigned int rtp_timestamp, unsigned char flags)
        {
            if (!userdata) return;
            auto *engine = static_cast<CallEngine *>(userdata);
            QByteArray data;
            if (nal && len > 0) { data = QByteArray(reinterpret_cast<const char *>(nal), static_cast<int>(len)); }
            QMetaObject::invokeMethod(engine, "enqueueIncomingVideoFragment", Qt::QueuedConnection,
                                      Q_ARG(QByteArray, data), Q_ARG(quint64, static_cast<quint64>(sequence)),
                                      Q_ARG(quint32, static_cast<quint32>(rtp_timestamp)),
                                      Q_ARG(quint8, static_cast<quint8>(flags)));
        }

        // Wire-format constants — должны совпадать с Rust voip::packet/voip::nal.
        constexpr quint8 kFlagFrameStart  = 0x02; // bit1
        constexpr quint8 kFlagFragmentEnd = 0x01; // bit0 (переиспользует COMFORT_NOISE)
        // MAX_DATAGRAM − header(16) − AEAD tag(16). 1200 синхронно с
        // `voip::transport::MAX_DATAGRAM` в Rust — большая цифра рвёт UDP в cellular
        // сетях с малым path-MTU.
        constexpr int kMaxFragmentPayload = 1200 - 16 - 16;

        QVideoSink *videoSinkFromOutput(QObject *output)
        { return output ? output->property("videoSink").value<QVideoSink *>() : nullptr; }

        void onStateChange(void *userdata, const char *state)
        {
            if (!userdata || !state) return;
            auto *engine = static_cast<CallEngine *>(userdata);
            QString s    = QString::fromUtf8(state);
            QMetaObject::invokeMethod(
                engine, [engine, s]() { emit engine->errorOccurred(QStringLiteral("ffi-state:") + s); },
                Qt::QueuedConnection);
        }

        // Извлечь port из строки "ip:port" локального адреса, отданного FFI.
        // Если что-то не сходится — 0.
        quint16 parsePort(const QString &addr)
        {
            const int idx = addr.lastIndexOf(':');
            if (idx < 0 || idx + 1 >= addr.size()) return 0;
            bool ok            = false;
            const quint16 port = static_cast<quint16>(addr.mid(idx + 1).toUInt(&ok));
            return ok ? port : 0;
        }

    } // namespace

    CallEngine::CallEngine(QObject *parent) : QObject(parent)
    {
        playbackTimer_.setInterval(20);
        playbackTimer_.setTimerType(Qt::PreciseTimer);
        connect(&playbackTimer_, &QTimer::timeout, this, &CallEngine::onJitterTick);
        mediaStatsTimer_.setInterval(5000);
        connect(&mediaStatsTimer_, &QTimer::timeout, this, [this]() {
            if (!session_) return;
            qInfo().noquote() << "CallEngine: media stats"
                              << "mic" << mic_frame_count_ << "txVoice" << sent_voice_packet_count_ << "rxVoice"
                              << received_voice_packet_count_ << "decoded" << decoded_voice_frame_count_;
        });
#if PARANOIA_HAS_VIDEO
        remote_video_sink_ = std::make_unique<VideoSinkBridge>(this);
#endif
    }

    CallEngine::~CallEngine() { stop(); }

    QVideoSink *CallEngine::localVideoSink() const
    {
#if PARANOIA_HAS_VIDEO
        return video_capture_ ? video_capture_->previewSink() : local_preview_sink_.data();
#else
        return nullptr;
#endif
    }

    QVideoSink *CallEngine::remoteVideoSink() const
    {
#if PARANOIA_HAS_VIDEO
        return remote_video_sink_ ? remote_video_sink_->videoSink() : nullptr;
#else
        return nullptr;
#endif
    }

    void CallEngine::setLocalVideoOutput(QObject *output)
    {
#if PARANOIA_HAS_VIDEO
        local_preview_sink_ = videoSinkFromOutput(output);
        if (video_capture_) video_capture_->setPreviewSink(local_preview_sink_.data());
#else
        Q_UNUSED(output);
#endif
    }

    void CallEngine::setRemoteVideoOutput(QObject *output)
    {
#if PARANOIA_HAS_VIDEO
        if (remote_video_sink_) remote_video_sink_->setVideoSink(videoSinkFromOutput(output));
#else
        Q_UNUSED(output);
#endif
    }

    void CallEngine::setState(const QString &s)
    {
        if (state_ == s) return;
        state_ = s;
        emit stateChanged();
    }

    void CallEngine::teardownAll()
    {
        playbackTimer_.stop();
        mediaStatsTimer_.stop();
        if (capture_) {
            capture_->stop();
            capture_.reset();
        }
#if defined(Q_OS_ANDROID)
        {
            QJniEnvironment env;
            const auto ctx = QNativeInterface::QAndroidApplication::context();
            if (ctx.isValid()) {
                QJniObject::callStaticMethod<void>("app/paranoia/client/ParanoiaAndroidUtils", "setVoiceCallMode",
                                                   "(Landroid/content/Context;ZZ)V", ctx.object<jobject>(),
                                                   jboolean(JNI_FALSE), jboolean(JNI_FALSE));
                if (env->ExceptionCheck()) env->ExceptionClear();
            }
        }
#elif defined(Q_OS_IOS)
        iosAudioSessionDeactivate();
#endif
#if PARANOIA_HAS_VIDEO
        if (video_capture_) {
            video_capture_->stop();
            video_capture_.reset();
        }
        h264_encoder_.reset();
        h264_decoder_.reset();
        reassembly_buffer_.clear();
        reassembly_active_     = false;
        reassembly_ts_         = 0;
        received_video_packet_ = false;
        h264_decoder_failed_   = false;
#endif
        if (session_) {
            paranoia_call_session_stop(session_);
            session_ = nullptr;
        }
        if (playback_) {
            playback_->stop();
            playback_.reset();
        }
        {
            QMutexLocker lock(&jitter_mutex_);
            jitter_.clear();
            jitter_expected_.reset();
            jitter_plc_streak_ = 0;
        }
        local_port_                  = 0;
        received_audio_packet_       = false;
        sent_audio_packet_           = false;
        decoded_audio_packet_        = false;
        mic_frame_count_             = 0;
        sent_voice_packet_count_     = 0;
        received_voice_packet_count_ = 0;
        decoded_voice_frame_count_   = 0;
        if (remote_video_active_) {
            remote_video_active_ = false;
            emit remoteVideoActiveChanged();
        }
        if (media_received_) {
            media_received_ = false;
            emit mediaReceivedChanged();
        }
        if (video_attached_) {
            video_attached_ = false;
            emit videoActiveChanged();
        }
        emit preparedChanged();
        setState(QStringLiteral("idle"));
    }

    quint16 CallEngine::prepare(const QString &localBind, const QString &masterKeyB64, const QString &sessionIdB64,
                                int role)
    {
        if (session_) {
            emit errorOccurred(QStringLiteral("call already prepared"));
            return 0;
        }
        if (!encoder_.init() || !decoder_.init()) {
            emit errorOccurred(QStringLiteral("opus init failed"));
            return 0;
        }
        playback_ = std::make_unique<AudioPlayback>(this);
        connect(playback_.get(), &AudioPlayback::error, this, &CallEngine::errorOccurred);
        if (!playback_->start()) {
            playback_.reset();
            return 0;
        }

        const QByteArray local = localBind.toUtf8();
        const QByteArray mk    = masterKeyB64.toUtf8();
        const QByteArray sid   = sessionIdB64.toUtf8();

        session_ =
            paranoia_call_session_start_unbound(local.constData(), mk.constData(), sid.constData(), role,
                                                &onIncomingFrame, &onIncomingVideoFragment, &onStateChange, this);
        if (!session_) {
            emit errorOccurred(
                QStringLiteral("paranoia_call_session_start_unbound failed: %1").arg(ParanoiaFFI::last_error()));
            playback_->stop();
            playback_.reset();
            return 0;
        }

        char *la = paranoia_call_session_local_addr(session_);
        if (la) {
            const QString addr = QString::fromUtf8(la);
            paranoia_free_string(la);
            local_port_ = parsePort(addr);
        }
        // Тикаем jitter сразу — фреймы могут начать приходить ещё до setPeer
        // (auto-discovery от удалённой стороны).
        playbackTimer_.start();
        mediaStatsTimer_.start();
        emit preparedChanged();
        setState(QStringLiteral("prepared"));
        qInfo().noquote() << "CallEngine: prepared UDP media socket port" << local_port_;
        return local_port_;
    }

    QString CallEngine::stunDiscover(const QString &stunServer, int timeoutMs)
    {
        if (!session_) {
            emit errorOccurred(QStringLiteral("stunDiscover before prepare"));
            return {};
        }
        if (stunServer.isEmpty() || timeoutMs <= 0) return {};
        const QByteArray srv = stunServer.toUtf8();
        char *res =
            paranoia_call_session_stun_discover(session_, srv.constData(), static_cast<unsigned int>(timeoutMs));
        if (!res) return {};
        QString out = QString::fromUtf8(res);
        paranoia_free_string(res);
        return out;
    }

    QString CallEngine::turnAllocate(const QString &turnServer, int timeoutMs)
    {
        if (!session_) {
            emit errorOccurred(QStringLiteral("turnAllocate before prepare"));
            return {};
        }
        if (turnServer.isEmpty() || timeoutMs <= 0) return {};
        const QByteArray srv = turnServer.toUtf8();
        char *res =
            paranoia_call_session_turn_allocate(session_, srv.constData(), static_cast<unsigned int>(timeoutMs));
        if (!res) return {};
        QString out = QString::fromUtf8(res);
        paranoia_free_string(res);
        return out;
    }

    bool CallEngine::setTurnPeer(const QString &turnServer, const QString &peerRelayAddr)
    {
        if (!session_) {
            emit errorOccurred(QStringLiteral("setTurnPeer before prepare"));
            return false;
        }
        if (turnServer.isEmpty() || peerRelayAddr.isEmpty()) return false;
        const QByteArray srv  = turnServer.toUtf8();
        const QByteArray peer = peerRelayAddr.toUtf8();
        if (paranoia_call_session_set_turn_peer(session_, srv.constData(), peer.constData()) != 0) {
            emit errorOccurred(QStringLiteral("set_turn_peer failed: %1").arg(ParanoiaFFI::last_error()));
            return false;
        }
        qInfo().noquote() << "CallEngine: media peer switched to TURN" << peerRelayAddr << "via" << turnServer;
        return true;
    }

    bool CallEngine::setPeer(const QString &peerAddr)
    {
        if (!session_) {
            emit errorOccurred(QStringLiteral("setPeer before prepare"));
            return false;
        }
        const QByteArray p = peerAddr.toUtf8();
        if (paranoia_call_session_set_peer(session_, p.constData()) != 0) {
            emit errorOccurred(QStringLiteral("set_peer failed: %1").arg(ParanoiaFFI::last_error()));
            return false;
        }
        qInfo().noquote() << "CallEngine: media peer set to" << peerAddr;
        return true;
    }

    void CallEngine::markMediaReceived()
    {
        if (media_received_) return;
        media_received_ = true;
        emit mediaReceivedChanged();
    }

    bool CallEngine::attachAudio()
    {
        if (!session_) {
            emit errorOccurred(QStringLiteral("attachAudio before prepare"));
            return false;
        }
        if (capture_) return true;
#if defined(Q_OS_IOS) && QT_CONFIG(permissions)
        {
            QMicrophonePermission permission;
            const auto status = qApp->checkPermission(permission);
            if (status == Qt::PermissionStatus::Undetermined) {
                QPointer<CallEngine> self(this);
                qApp->requestPermission(permission, this, [self](const QPermission &granted) {
                    if (!self) return;
                    if (granted.status() == Qt::PermissionStatus::Granted)
                        self->attachAudio();
                    else
                        emit self->errorOccurred(QStringLiteral("Нет доступа к микрофону."));
                });
                return false;
            }
            if (status == Qt::PermissionStatus::Denied) {
                emit errorOccurred(QStringLiteral("Нет доступа к микрофону."));
                return false;
            }
        }
#endif
#if defined(Q_OS_ANDROID)
        {
            QJniEnvironment env;
            const auto ctx = QNativeInterface::QAndroidApplication::context();
            if (ctx.isValid()) {
                QJniObject::callStaticMethod<void>("app/paranoia/client/ParanoiaAndroidUtils",
                                                   "requestMicrophonePermission", "(Landroid/content/Context;)V",
                                                   ctx.object<jobject>());
                if (env->ExceptionCheck()) env->ExceptionClear();
                // Перевести audio-стек в режим VoIP-звонка ДО старта QAudioSink/Source.
                // Иначе AudioManager считает нас медиа-плеером, приглушает media
                // stream при одновременном recording, и звук не доходит до динамика.
                QJniObject::callStaticMethod<void>("app/paranoia/client/ParanoiaAndroidUtils", "setVoiceCallMode",
                                                   "(Landroid/content/Context;ZZ)V", ctx.object<jobject>(),
                                                   jboolean(JNI_TRUE), jboolean(JNI_TRUE) /* speakerphone */);
                if (env->ExceptionCheck()) env->ExceptionClear();
            }
        }
#elif defined(Q_OS_IOS)
        // Прямой аналог Android-блока выше: переключаем AVAudioSession в
        // PlayAndRecord/VoiceChat с DefaultToSpeaker ДО старта QAudioSource/Sink.
        // Иначе выход уходит в earpiece, а одновременный recording в дефолтной
        // категории приглушает воспроизведение.
        iosAudioSessionConfigureForVoiceCall();
#endif
        capture_ = std::make_unique<AudioCapture>(this);
        connect(capture_.get(), &AudioCapture::frameReady, this, &CallEngine::onPcmFrameFromMic);
        connect(capture_.get(), &AudioCapture::error, this, &CallEngine::errorOccurred);
        if (!capture_->start()) {
            capture_.reset();
            return false;
        }
        setState(QStringLiteral("running"));
        return true;
    }

    bool CallEngine::attachVideo()
    {
#if PARANOIA_HAS_VIDEO
        if (!session_) {
            emit errorOccurred(QStringLiteral("attachVideo before prepare"));
            return false;
        }
        if (video_attached_) return true;
#if defined(Q_OS_IOS) && QT_CONFIG(permissions)
        {
            QCameraPermission permission;
            const auto status = qApp->checkPermission(permission);
            if (status == Qt::PermissionStatus::Undetermined) {
                QPointer<CallEngine> self(this);
                qApp->requestPermission(permission, this, [self](const QPermission &granted) {
                    if (!self) return;
                    if (granted.status() == Qt::PermissionStatus::Granted)
                        self->attachVideo();
                    else
                        emit self->errorOccurred(QStringLiteral("Нет доступа к камере."));
                });
                return false;
            }
            if (status == Qt::PermissionStatus::Denied) {
                emit errorOccurred(QStringLiteral("Нет доступа к камере."));
                return false;
            }
        }
#endif
#if defined(Q_OS_ANDROID)
        {
            QJniEnvironment env;
            const auto ctx = QNativeInterface::QAndroidApplication::context();
            if (ctx.isValid()) {
                // CAMERA permission запрашивается через тот же путь.
                QJniObject::callStaticMethod<void>("app/paranoia/client/ParanoiaAndroidUtils",
                                                   "requestCameraPermission", "(Landroid/content/Context;)V",
                                                   ctx.object<jobject>());
                if (env->ExceptionCheck()) env->ExceptionClear();
            }
        }
#endif
        // Декодер для входящих кадров — должен существовать ещё до того, как
        // удалённая сторона начнёт слать пакеты (они могут прилететь до того,
        // как мы локально включим камеру).
        if (!h264_decoder_) {
            h264_decoder_ = std::make_unique<H264Decoder>();
            if (!h264_decoder_->init()) {
                emit errorOccurred(QStringLiteral("h264 decoder init failed: %1").arg(h264_decoder_->lastError()));
                h264_decoder_.reset();
                return false;
            }
        }
        if (!h264_encoder_) {
            h264_encoder_ = std::make_unique<H264Encoder>();
            if (!h264_encoder_->init()) {
                emit errorOccurred(QStringLiteral("h264 encoder init failed: %1").arg(h264_encoder_->lastError()));
                h264_encoder_.reset();
                return false;
            }
        }
        video_capture_ = std::make_unique<VideoCapture>(this);
        video_capture_->setPreviewSink(local_preview_sink_.data());
        connect(video_capture_.get(), &VideoCapture::frameReady, this, &CallEngine::onCameraFrameI420);
        connect(video_capture_.get(), &VideoCapture::error, this, &CallEngine::errorOccurred);
        if (!video_capture_->start()) {
            video_capture_.reset();
            return false;
        }
        video_attached_ = true;
        emit videoActiveChanged();
        return true;
#else
        emit errorOccurred(QStringLiteral("video not compiled in this build"));
        return false;
#endif
    }

    void CallEngine::detachVideo()
    {
#if PARANOIA_HAS_VIDEO
        if (!video_attached_) return;
        if (video_capture_) {
            video_capture_->stop();
            video_capture_.reset();
        }
        h264_encoder_.reset();
        video_attached_ = false;
        emit videoActiveChanged();
#endif
    }

    void CallEngine::requestKeyframe()
    {
#if PARANOIA_HAS_VIDEO
        if (h264_encoder_) h264_encoder_->requestKeyframe();
#endif
    }

    bool CallEngine::start(const QString &localBind, const QString &peerAddr, const QString &masterKeyB64,
                           const QString &sessionIdB64, int role)
    {
        if (prepare(localBind, masterKeyB64, sessionIdB64, role) == 0 && !session_) { return false; }
        if (!setPeer(peerAddr)) {
            teardownAll();
            return false;
        }
        if (!attachAudio()) {
            teardownAll();
            return false;
        }
        return true;
    }

    void CallEngine::stop() { teardownAll(); }

    void CallEngine::onPcmFrameFromMic(const QByteArray &pcm)
    {
        if (!session_) return;
        if (pcm.size() != AudioFormat::kFrameBytes) return;
        ++mic_frame_count_;
        if (!sent_audio_packet_) {
            sent_audio_packet_ = true;
            qInfo().noquote() << "CallEngine: captured first microphone frame bytes" << pcm.size();
        }
        const auto *samples      = reinterpret_cast<const int16_t *>(pcm.constData());
        const QByteArray encoded = encoder_.encode(samples, AudioFormat::kFrameSamples);
        if (encoded.isEmpty()) {
            if (encoder_.lastError()[0] != '\0') {
                emit errorOccurred(
                    QStringLiteral("opus encode error: %1").arg(QString::fromUtf8(encoder_.lastError())));
            }
            return;
        }
        const int rc = paranoia_call_session_push_opus(
            session_, reinterpret_cast<const unsigned char *>(encoded.constData()), encoded.size());
        if (rc != 0)
            emit errorOccurred(QStringLiteral("push_opus failed: %1").arg(ParanoiaFFI::last_error()));
        else
            ++sent_voice_packet_count_;
    }

    void CallEngine::enqueueIncomingFrame(const QByteArray &opus, quint64 sequence)
    {
        ++received_voice_packet_count_;
        if (!received_audio_packet_) {
            received_audio_packet_ = true;
            markMediaReceived();
            qInfo().noquote() << "CallEngine: received first voice packet seq" << sequence << "bytes" << opus.size();
        }
        QMutexLocker lock(&jitter_mutex_);
        // Late-drop: если уже стартовали и seq < expected — выкидываем.
        if (jitter_expected_.has_value() && sequence < *jitter_expected_) return;
        // Overflow: если буфер полон и нового seq в нём ещё нет — выкидываем
        // самый старый, чтобы не отставать.
        if (jitter_.size() >= kJitterMaxDepth && !jitter_.contains(sequence)) {
            auto it = jitter_.begin();
            if (it != jitter_.end()) jitter_.erase(it);
        }
        // Дубликаты — игнорируем (первый победил).
        if (!jitter_.contains(sequence)) { jitter_.insert(sequence, opus); }
    }

    CallEngine::JitterPop CallEngine::popFromJitter()
    {
        QMutexLocker lock(&jitter_mutex_);
        if (!jitter_expected_.has_value()) {
            if (static_cast<int>(jitter_.size()) < kJitterInitialDelay) {
                return {}; // Wait
            }
            jitter_expected_ = jitter_.firstKey();
        }
        const quint64 exp = *jitter_expected_;
        if (jitter_.contains(exp)) {
            QByteArray f       = jitter_.take(exp);
            jitter_expected_   = exp + 1;
            jitter_plc_streak_ = 0;
            JitterPop out;
            out.has_frame = true;
            out.opus      = std::move(f);
            return out;
        }
        // Нет ожидаемого: если есть более новые — PLC; иначе Wait.
        const bool haveLater = !jitter_.isEmpty() && jitter_.firstKey() > exp;
        if (!haveLater) {
            return {}; // Wait
        }
        jitter_expected_ = exp + 1;
        if (++jitter_plc_streak_ > kJitterMaxPlcStreak) {
            // Resync: начинаем заново с самого раннего.
            jitter_expected_.reset();
            jitter_plc_streak_ = 0;
        }
        JitterPop out;
        out.has_frame = true;
        out.plc       = true;
        return out;
    }

    void CallEngine::onJitterTick()
    {
        if (!playback_) return;
        const JitterPop p = popFromJitter();
        if (!p.has_frame) return;
        QByteArray pcm(AudioFormat::kFrameBytes, Qt::Uninitialized);
        auto *outSamples = reinterpret_cast<int16_t *>(pcm.data());
        int samples;
        if (p.plc || p.opus.isEmpty()) {
            samples = decoder_.decode(nullptr, 0, outSamples, AudioFormat::kFrameSamples);
        } else {
            samples = decoder_.decode(reinterpret_cast<const uint8_t *>(p.opus.constData()), p.opus.size(), outSamples,
                                      AudioFormat::kFrameSamples);
        }
        if (samples <= 0) {
            emit errorOccurred(QStringLiteral("opus decode error: %1").arg(QString::fromUtf8(decoder_.lastError())));
            return;
        }
        pcm.resize(samples * AudioFormat::kChannels * 2);
        ++decoded_voice_frame_count_;
        if (!decoded_audio_packet_) {
            decoded_audio_packet_ = true;
            qInfo().noquote() << "CallEngine: decoded first voice frame samples" << samples << "pcm bytes"
                              << pcm.size();
        }
        playback_->pushFrame(pcm);
    }

#if PARANOIA_HAS_VIDEO
    void CallEngine::onCameraFrameI420(const QByteArray &i420, qint64 pts_90khz)
    {
        if (!session_ || !h264_encoder_) return;
        const auto encoded =
            h264_encoder_->encode(reinterpret_cast<const uint8_t *>(i420.constData()), i420.size(), pts_90khz);
        if (encoded.empty()) return;
        // На каждый NAL — фрагментируем, выставляем FRAME_START на первом
        // куске и FRAGMENT_END на последнем. Один rtp_timestamp на весь NAL.
        const quint32 rtp_ts = static_cast<quint32>(pts_90khz & 0xFFFFFFFFu);
        for (const auto &nal : encoded) {
            if (nal.isEmpty()) continue;
            const int total = nal.size();
            int start       = 0;
            while (start < total) {
                const int end = std::min(start + kMaxFragmentPayload, total);
                quint8 flags  = 0;
                if (start == 0) flags |= kFlagFrameStart;
                if (end == total) flags |= kFlagFragmentEnd;
                const int rc = paranoia_call_session_push_h264(
                    session_, reinterpret_cast<const unsigned char *>(nal.constData()) + start,
                    static_cast<size_t>(end - start), flags, rtp_ts);
                if (rc != 0) {
                    emit errorOccurred(QStringLiteral("push_h264 failed"));
                    return;
                }
                start = end;
            }
        }
    }
#endif

    void CallEngine::enqueueIncomingVideoFragment(const QByteArray &fragment, quint64 sequence, quint32 rtp_timestamp,
                                                  quint8 flags)
    {
#if PARANOIA_HAS_VIDEO
        if (!received_video_packet_) {
            received_video_packet_ = true;
            markMediaReceived();
            qInfo().noquote() << "CallEngine: received first video packet seq" << sequence << "bytes"
                              << fragment.size();
        }
        if (!h264_decoder_ && !h264_decoder_failed_) {
            h264_decoder_ = std::make_unique<H264Decoder>();
            if (!h264_decoder_->init()) {
                emit errorOccurred(QStringLiteral("h264 decoder init failed: %1").arg(h264_decoder_->lastError()));
                h264_decoder_.reset();
                h264_decoder_failed_ = true;
            }
        }
        if (!h264_decoder_ || !remote_video_sink_) return;
        const bool first = (flags & kFlagFrameStart) != 0;
        const bool last  = (flags & kFlagFragmentEnd) != 0;

        // Реассембляция: смена timestamp → старый буфер дропаем (потеряли last);
        // FRAME_START → новый NAL; иначе — продолжение.
        if (reassembly_active_ && rtp_timestamp != reassembly_ts_) {
            reassembly_buffer_.clear();
            reassembly_active_ = false;
        }
        if (first) {
            reassembly_buffer_.clear();
            reassembly_buffer_.reserve(fragment.size() * 2);
            reassembly_ts_     = rtp_timestamp;
            reassembly_active_ = true;
        } else if (!reassembly_active_) {
            // Получили продолжение без начала — дропаем.
            reassembly_last_seq_ = sequence;
            return;
        }
        // Защита от роста — 4 MB на NAL.
        if (reassembly_buffer_.size() + fragment.size() > 4 * 1024 * 1024) {
            reassembly_buffer_.clear();
            reassembly_active_ = false;
            return;
        }
        reassembly_buffer_.append(fragment);
        reassembly_last_seq_ = sequence;

        if (!last) return;

        // Готов NAL — отдаём декодеру с Annex B start-code.
        QByteArray annexb;
        annexb.reserve(reassembly_buffer_.size() + 4);
        annexb.append('\x00').append('\x00').append('\x00').append('\x01');
        annexb.append(reassembly_buffer_);
        reassembly_buffer_.clear();
        reassembly_active_ = false;

        if (!h264_decoder_->decode(reinterpret_cast<const uint8_t *>(annexb.constData()), annexb.size())) {
            return; // Декодер ещё накапливает (например, ждёт SPS/PPS).
        }
        // Узнать размер декодированного кадра по width/height из AVFrame —
        // у нас нет прямого доступа, кроме как через getDecoded (туда передаётся
        // out_width/out_height). Используем максимальный буфер на 1080p, который
        // покроет и 720p, и больше.
        constexpr int kMaxFrameBytes = 1920 * 1080 * 3 / 2;
        QByteArray frame_bytes(kMaxFrameBytes, Qt::Uninitialized);
        int width = 0, height = 0;
        if (!h264_decoder_->getDecoded(reinterpret_cast<uint8_t *>(frame_bytes.data()), frame_bytes.size(), width,
                                       height)) {
            return;
        }
        frame_bytes.resize(width * height * 3 / 2);
        if (!remote_video_active_) {
            remote_video_active_ = true;
            emit remoteVideoActiveChanged();
        }
        remote_video_sink_->setI420Frame(std::move(frame_bytes), width, height);
#else
        Q_UNUSED(fragment);
        Q_UNUSED(sequence);
        Q_UNUSED(rtp_timestamp);
        Q_UNUSED(flags);
#endif
    }

} // namespace paranoia::voip
