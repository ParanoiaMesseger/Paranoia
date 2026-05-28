#include "CallEngine.hpp"

#include <QDateTime>
#include <QMetaObject>
#include <QMutexLocker>
#include <QVideoSink>
#include <QVariant>
#include <QtConcurrent>
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
            auto *ctx = static_cast<CallEngine::CallbackContext *>(userdata);
            auto *engine    = ctx->engine;
            const quint64 g = ctx->generation;
            QByteArray data;
            if (opus && len > 0) { data = QByteArray(reinterpret_cast<const char *>(opus), static_cast<int>(len)); }
            QMetaObject::invokeMethod(engine, "enqueueIncomingFrame", Qt::QueuedConnection, Q_ARG(QByteArray, data),
                                      Q_ARG(quint64, static_cast<quint64>(sequence)), Q_ARG(quint64, g));
        }

        void onIncomingVideoFragment(void *userdata, const unsigned char *nal, size_t len, uint64_t sequence,
                                     unsigned int rtp_timestamp, unsigned char flags)
        {
            if (!userdata) return;
            auto *ctx = static_cast<CallEngine::CallbackContext *>(userdata);
            auto *engine    = ctx->engine;
            const quint64 g = ctx->generation;
            QByteArray data;
            if (nal && len > 0) { data = QByteArray(reinterpret_cast<const char *>(nal), static_cast<int>(len)); }
            QMetaObject::invokeMethod(engine, "enqueueIncomingVideoFragment", Qt::QueuedConnection,
                                      Q_ARG(QByteArray, data), Q_ARG(quint64, static_cast<quint64>(sequence)),
                                      Q_ARG(quint32, static_cast<quint32>(rtp_timestamp)),
                                      Q_ARG(quint8, static_cast<quint8>(flags)), Q_ARG(quint64, g));
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
            auto *ctx = static_cast<CallEngine::CallbackContext *>(userdata);
            auto *engine = ctx->engine;
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
#if PARANOIA_HAS_VIDEO
        remote_video_sink_ = std::make_unique<VideoSinkBridge>(this);
#endif

        // Каждую секунду проверяем: если давно (>1.5s) не было видео-кадров от
        // peer'а, считаем что он выключил камеру и сбрасываем remoteVideoActive
        // → QML показывает placeholder с инициалом вместо замёрзшего кадра.
        remoteVideoIdleTimer_.setInterval(1000);
        connect(&remoteVideoIdleTimer_, &QTimer::timeout, this, [this]() {
            if (!remote_video_active_) return;
            const qint64 now = QDateTime::currentMSecsSinceEpoch();
            if (now - last_remote_video_ts_ms_ > 1500) {
                remote_video_active_ = false;
                emit remoteVideoActiveChanged();
            }
        });
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
        remoteVideoIdleTimer_.stop();
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
        reassembly_ = {};
        received_video_packet_ = false;
        h264_decoder_failed_   = false;
#endif
        // Бампим генерацию ДО session_stop — это инвалидирует любые ещё
        // не выполненные frame_cb/video_cb в Qt event-queue (см. подробный
        // комментарий выше: иначе jitter_expected_ съезжает на seq предыдущего
        // звонка и накапливается задержка).
        ++session_generation_;
        // paranoia_call_session_stop блокирует поток (rt.block_on(join))
        // до завершения Rust-task'а. На UI-потоке это «замораживает»
        // интерфейс на сотни миллисекунд — особенно заметно при отмене
        // исходящего звонка или отклонении входящего. Выносим в worker'у
        // QtConcurrent: ресурсы Rust освободятся в фоне, UI отзывчивый.
        // Безопасно: зомби-callback'и из этой сессии не пройдут проверку
        // generation в enqueueIncomingFrame.
        if (session_) {
            auto *session_to_stop = session_;
            session_               = nullptr;
            (void)QtConcurrent::run([session_to_stop]() { paranoia_call_session_stop(session_to_stop); });
        }
        // Сохраняем контекст до следующего prepare(): отложенный invokeMethod
        // может всё ещё содержать указатель на эти байты, нельзя сразу
        // free()'ить. Освободим в prepare() через retired_callback_contexts_.clear().
        if (callback_context_) {
            retired_callback_contexts_.push_back(std::move(callback_context_));
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
        local_port_              = 0;
        mic_muted_               = false;
        received_audio_packet_   = false;
        last_remote_video_ts_ms_ = 0;
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
        if (local_video_portrait_) {
            local_video_portrait_ = false;
            emit localVideoPortraitChanged();
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

        // Platform-specific audio mode ДОЛЖЕН быть переключён ДО создания
        // QAudioSink. На Huawei (и других строгих Android-вендорах) смена
        // AudioManager.mode на MODE_IN_COMMUNICATION уже работающий media-stream
        // AAudio-sink убивает с IOError → sink навсегда StoppedState, reads=0,
        // звук не играет. Тот же фикс нужен иосу — категорию переключаем
        // ДО старта QAudioSink, иначе sink стартует в дефолтной категории
        // (Playback) и в момент смены может слететь.
#if defined(Q_OS_ANDROID)
        {
            QJniEnvironment env;
            const auto ctx = QNativeInterface::QAndroidApplication::context();
            if (ctx.isValid()) {
                QJniObject::callStaticMethod<void>("app/paranoia/client/ParanoiaAndroidUtils", "setVoiceCallMode",
                                                   "(Landroid/content/Context;ZZ)V", ctx.object<jobject>(),
                                                   jboolean(JNI_TRUE), jboolean(JNI_TRUE) /* speakerphone */);
                if (env->ExceptionCheck()) env->ExceptionClear();
            }
        }
#elif defined(Q_OS_IOS)
        iosAudioSessionConfigureForVoiceCall();
#endif

        playback_ = std::make_unique<AudioPlayback>(this);
        connect(playback_.get(), &AudioPlayback::error, this, &CallEngine::errorOccurred);
        if (!playback_->start()) {
            playback_.reset();
            return 0;
        }

        const QByteArray local = localBind.toUtf8();
        const QByteArray mk    = masterKeyB64.toUtf8();
        const QByteArray sid   = sessionIdB64.toUtf8();

        // Новое «поколение» для этой сессии. Аллоцируем контекст в куче и
        // передаём его указатель в Rust как userdata; в нём live и engine, и
        // generation. Старые retired-контексты освобождаются здесь — к моменту
        // следующего prepare все отложенные invokeMethod от предыдущей сессии
        // уже отработали через Qt event loop. Замечание: generation также
        // бампится в teardownAll(), поэтому ещё инкрементируем здесь, чтобы
        // новая сессия имела явно отличное поколение от zombie-callback'ов.
        retired_callback_contexts_.clear();
        ++session_generation_;
        callback_context_.reset(new CallbackContext{this, session_generation_});

        session_ =
            paranoia_call_session_start_unbound(local.constData(), mk.constData(), sid.constData(), role,
                                                &onIncomingFrame, &onIncomingVideoFragment, &onStateChange,
                                                callback_context_.get());
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
        remoteVideoIdleTimer_.start();
        emit preparedChanged();
        setState(QStringLiteral("prepared"));
        qInfo().noquote() << "CallEngine: prepared UDP media socket port" << local_port_;
        return local_port_;
    }

    QString CallEngine::stunDiscover(const QString &stunServer, int timeoutMs)
    {
        // Тихо возвращаем пусто если session ещё/уже не существует. STUN
        // discovery вызывается из probing-pipeline'а CallController'а — он
        // может выполниться в гонке с teardown'ом (например, пользователь
        // сбросил звонок пока probe в QtConcurrent-таске). Эмит errorOccurred
        // здесь приводил к красному всплывашке "stunDiscover before prepare".
        if (!session_) return {};
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
        // См. stunDiscover — тихо возвращаем пусто при отсутствующей сессии.
        // Probing-pipeline может вызывать allocate уже после teardown.
        if (!session_) return {};
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
        if (!session_) return false; // см. stunDiscover
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

    QString CallEngine::currentPeer() const
    {
        if (!session_) return {};
        char *res = paranoia_call_session_get_peer(session_);
        if (!res) return {};
        QString out = QString::fromUtf8(res);
        paranoia_free_string(res);
        return out;
    }

    bool CallEngine::setPeer(const QString &peerAddr)
    {
        // Без сессии — тихо отказываем (probing/race-сценарии после teardown).
        if (!session_) return false;
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
            // Voice call mode уже включён в prepare() — здесь только просим
            // RECORD_AUDIO permission (требуется до старта QAudioSource).
            QJniEnvironment env;
            const auto ctx = QNativeInterface::QAndroidApplication::context();
            if (ctx.isValid()) {
                QJniObject::callStaticMethod<void>("app/paranoia/client/ParanoiaAndroidUtils",
                                                   "requestMicrophonePermission", "(Landroid/content/Context;)V",
                                                   ctx.object<jobject>());
                if (env->ExceptionCheck()) env->ExceptionClear();
            }
        }
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
        // H.264 энкодер инициализируется ОТЛОЖЕННО: размеры выхода (720×1280
        // portrait / 1280×720 landscape) известны только после первого кадра
        // камеры, когда мы понимаем эффективную ориентацию источника. Сам
        // VideoCapture::dimensionsReady сигналит выбранные dst-димы — там и
        // инитим.
        video_capture_ = std::make_unique<VideoCapture>(this);
        video_capture_->setPreviewSink(local_preview_sink_.data());
        connect(video_capture_.get(), &VideoCapture::frameReady, this, &CallEngine::onCameraFrameI420);
        connect(video_capture_.get(), &VideoCapture::dimensionsReady, this,
                [this](int w, int h) {
                    const bool portrait = (h > w);
                    if (local_video_portrait_ != portrait) {
                        local_video_portrait_ = portrait;
                        emit localVideoPortraitChanged();
                    }
                    if (h264_encoder_) {
                        // dimensionsReady пришёл повторно с теми же димами —
                        // ничего не делаем (см. VideoCapture::switchCamera: dst
                        // фиксируется на первом кадре). Если димы внезапно
                        // отличаются — это инвариант, который мы не поддерживаем,
                        // и encoder остался бы с прежними. Лучше явно logать.
                        return;
                    }
                    h264_encoder_ = std::make_unique<H264Encoder>();
                    if (!h264_encoder_->init(w, h)) {
                        emit errorOccurred(
                            QStringLiteral("h264 encoder init failed: %1").arg(h264_encoder_->lastError()));
                        h264_encoder_.reset();
                        return;
                    }
                });
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

    bool CallEngine::switchCamera()
    {
#if PARANOIA_HAS_VIDEO
        if (!video_capture_) return false;
        if (!video_capture_->switchCamera()) return false;
        // После смены камеры размер/ориентация кадра может измениться —
        // просим энкодер выдать I-frame, чтобы получатель быстро восстановился.
        if (h264_encoder_) h264_encoder_->requestKeyframe();
        return true;
#else
        return false;
#endif
    }

    bool CallEngine::hasMultipleCameras() const
    {
#if PARANOIA_HAS_VIDEO
        return VideoCapture::hasMultipleCameras();
#else
        return false;
#endif
    }

    void CallEngine::setMicMuted(bool muted)
    {
        if (mic_muted_ == muted) return;
        mic_muted_ = muted;
        emit micMutedChanged();
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
        // Mute = шлём тот же 20 мс PCM, но обнулённый. Opus всё равно кодирует
        // (тишина — около 7 байт), pipeline продолжает работать как keepalive,
        // удалённая сторона не теряет sync и слышит ровную тишину.
        QByteArray silence;
        const int16_t *samples = nullptr;
        if (mic_muted_) {
            silence = QByteArray(AudioFormat::kFrameBytes, '\0');
            samples = reinterpret_cast<const int16_t *>(silence.constData());
        } else {
            samples = reinterpret_cast<const int16_t *>(pcm.constData());
        }
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
    }

    void CallEngine::enqueueIncomingFrame(const QByteArray &opus, quint64 sequence, quint64 generation)
    {
        if (generation != session_generation_) {
            // Зомби-пакет от уже остановленной сессии — нельзя пускать в jitter,
            // иначе jitter_expected_ скакнёт на seq из старой сессии и все
            // новые пакеты текущего звонка начнут отбрасываться как «поздние».
            return;
        }
        if (!received_audio_packet_) {
            received_audio_packet_ = true;
            markMediaReceived();
        }
        QMutexLocker lock(&jitter_mutex_);
        // Late drop: уже прошли seq, выкидываем.
        if (jitter_expected_.has_value() && sequence < *jitter_expected_) return;
        // Overflow: буфер полный и нет такого seq — выкидываем самый старый.
        if (jitter_.size() >= kJitterMaxDepth && !jitter_.contains(sequence)) {
            auto it = jitter_.begin();
            if (it != jitter_.end()) jitter_.erase(it);
        }
        if (!jitter_.contains(sequence)) jitter_.insert(sequence, opus);
    }

    CallEngine::JitterPop CallEngine::popFromJitter()
    {
        QMutexLocker lock(&jitter_mutex_);
        if (!jitter_expected_.has_value()) {
            if (static_cast<int>(jitter_.size()) < kJitterInitialDelay) return {};
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
        const bool haveLater = !jitter_.isEmpty() && jitter_.firstKey() > exp;
        if (!haveLater) return {};
        jitter_expected_ = exp + 1;
        if (++jitter_plc_streak_ > kJitterMaxPlcStreak) {
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
                                                  quint8 flags, quint64 generation)
    {
#if PARANOIA_HAS_VIDEO
        if (generation != session_generation_) {
            return; // зомби-фрагмент от старой сессии
        }
        if (!received_video_packet_) {
            received_video_packet_ = true;
            markMediaReceived();
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
        constexpr int kMaxNalBytes      = 4 * 1024 * 1024;
        constexpr int kMaxPendingFrags  = 256;

        // Смена timestamp → старый NAL дропаем целиком (потеряли FRAGMENT_END
        // прошлого кадра, или начался следующий). Декодер увидит «потерянный
        // кадр» — следующий keyframe восстановит.
        if (reassembly_.active && rtp_timestamp != reassembly_.rtp_ts) {
            reassembly_ = {};
        }
        if (first) {
            reassembly_ = {};
            reassembly_.active        = true;
            reassembly_.rtp_ts        = rtp_timestamp;
            reassembly_.start_seq     = sequence;
            reassembly_.next_expected = sequence;
            reassembly_.nal.reserve(fragment.size() * 2);
        } else if (!reassembly_.active) {
            // Continuation без FRAME_START. Мог потеряться (а мог и просто
            // приехать раньше — UDP reorder); складываем в pending, чтобы
            // если FRAME_START всё же придёт позже на этом же rtp_ts, мы
            // склеили. Защита от мусора: pending ограничен.
            return;
        } else if (sequence < reassembly_.start_seq) {
            // Поздний фрагмент с seq до начала текущего кадра — выбрасываем.
            return;
        }

        if (last) {
            reassembly_.has_end = true;
            reassembly_.end_seq = sequence;
        }

        // Защита от роста: считаем сумму уже накопленных + pending + текущего.
        const qsizetype pending_bytes = [&]() {
            qsizetype s = 0;
            for (auto it = reassembly_.pending.begin(); it != reassembly_.pending.end(); ++it)
                s += it.value().size();
            return s;
        }();
        if (reassembly_.nal.size() + pending_bytes + fragment.size() > kMaxNalBytes ||
            reassembly_.pending.size() >= kMaxPendingFrags) {
            reassembly_ = {};
            return;
        }

        // Кладём текущий фрагмент. Если он точно совпадает с next_expected —
        // склеиваем сразу и подтягиваем accumulated pending.
        if (sequence == reassembly_.next_expected) {
            reassembly_.nal.append(fragment);
            ++reassembly_.next_expected;
            // Подтянуть подряд идущие из pending.
            while (true) {
                auto it = reassembly_.pending.find(reassembly_.next_expected);
                if (it == reassembly_.pending.end()) break;
                reassembly_.nal.append(it.value());
                reassembly_.pending.erase(it);
                ++reassembly_.next_expected;
            }
        } else {
            // Out-of-order: придёт раньше своего места. Сохраняем.
            reassembly_.pending.insert(sequence, fragment);
        }

        // Готов ли кадр? Условие: видели FRAGMENT_END и контигуальное
        // покрытие [start_seq, end_seq] завершилось (next_expected > end_seq).
        if (!reassembly_.has_end) return;
        if (reassembly_.next_expected <= reassembly_.end_seq) return; // ждём недостающие

        // Готов NAL — отдаём декодеру с Annex B start-code.
        QByteArray annexb;
        annexb.reserve(reassembly_.nal.size() + 4);
        annexb.append('\x00').append('\x00').append('\x00').append('\x01');
        annexb.append(reassembly_.nal);
        reassembly_ = {};

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
        last_remote_video_ts_ms_ = QDateTime::currentMSecsSinceEpoch();
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
        Q_UNUSED(generation);
#endif
    }

} // namespace paranoia::voip
