#pragma once

#include <QByteArray>
#include <QMap>
#include <QString>
#include <QTimer>
#include <memory>
#include <optional>
#include <vector>

#include "AudioCapture.hpp"
#include "AudioPlayback.hpp"
#include "OpusCodec.hpp"

#if PARANOIA_HAS_VIDEO
#include "H264Codec.hpp"
#include "VideoCapture.hpp"
#include "VideoSink.hpp"
#endif

// Forward declaration из libparanoia C-FFI (определена в paranoia_lib.h).
struct ParanoiaCallSession;
class QVideoSink;

namespace paranoia::voip
{

    /// Высокоуровневый QObject звонка: связывает захват микрофона, libopus и
    /// FFI-сессию paranoia_call_session.
    ///
    /// Двухфазный flow для NAT hole-punching без полноценного ICE:
    ///   1. `prepare(localBind, masterKeyB64, sessionIdB64, role)` — bind UDP,
    ///      инициализирует декодер/кодек и плейбэк (но НЕ микрофон). Возвращает
    ///      локальный port — его можно вшить в Offer/Answer как кандидат.
    ///   2. `setPeer("ip:port")` — задаёт удалённую сторону (когда узнали из
    ///      сигналинга).
    ///   3. `attachAudio()` — стартует захват микрофона; теперь звук идёт в эфир.
    ///   4. `stop()` — корректно сворачивает всё.
    ///
    /// Удобная обёртка `start(...)` объединяет prepare+setPeer+attachAudio для
    /// случая, когда peer известен заранее (например, при тесте).
    ///
    /// Все state-методы безопасны для вызова из главного потока Qt; callback'и
    /// FFI приходят в фоновых Tokio-потоках и переключаются на главный через
    /// `QMetaObject::invokeMethod`.
    class CallEngine : public QObject
    {
        Q_OBJECT
        Q_PROPERTY(QString state READ state NOTIFY stateChanged)
        Q_PROPERTY(quint16 localPort READ localPort NOTIFY preparedChanged)
        Q_PROPERTY(bool videoActive READ videoActive NOTIFY videoActiveChanged)
        Q_PROPERTY(bool remoteVideoActive READ remoteVideoActive NOTIFY remoteVideoActiveChanged)
        Q_PROPERTY(bool mediaReceived READ mediaReceived NOTIFY mediaReceivedChanged)
        Q_PROPERTY(bool videoSupported READ videoSupported CONSTANT)
        Q_PROPERTY(bool localVideoPortrait READ localVideoPortrait NOTIFY localVideoPortraitChanged)
        Q_PROPERTY(QVideoSink *localVideoSink READ localVideoSink NOTIFY videoActiveChanged)
        Q_PROPERTY(QVideoSink *remoteVideoSink READ remoteVideoSink CONSTANT)
    public:
        explicit CallEngine(QObject *parent = nullptr);
        ~CallEngine() override;

        // Контекст, который передаётся в Rust FFI как `userdata` для frame_cb /
        // video_cb / state_cb. Public — потому что C-style callback в
        // CallEngine.cpp обращается к полям. Перенесён выше private для
        // видимости из anonymous namespace.
        struct CallbackContext {
            CallEngine *engine;
            quint64 generation;
        };

        QString state() const { return state_; }
        quint16 localPort() const { return local_port_; }

        /// `true` если сборка содержит видео-стек (FFmpeg + Qt::Multimedia).
        static constexpr bool videoSupported()
        {
#if PARANOIA_HAS_VIDEO
            return true;
#else
            return false;
#endif
        }

        bool videoActive() const { return video_attached_; }
        bool remoteVideoActive() const { return remote_video_active_; }
        /// Локальная камера выдаёт portrait-кадр (9:16). Известно после
        /// первого кадра — VideoCapture::dimensionsReady. До этого false.
        bool localVideoPortrait() const { return local_video_portrait_; }
        bool mediaReceived() const { return media_received_; }

        /// Текущий sink для локального preview. QML не должен писать его в
        /// `VideoOutput.videoSink`; вместо этого используется `setLocalVideoOutput()`.
        QVideoSink *localVideoSink() const;

        /// Текущий sink для удалённого видео из QML `VideoOutput`.
        QVideoSink *remoteVideoSink() const;

        /// Подключить QML `VideoOutput`. В Qt 6 `VideoOutput.videoSink` read-only,
        /// поэтому C++ читает его из объекта вывода и дальше пишет кадры туда.
        Q_INVOKABLE void setLocalVideoOutput(QObject *output);
        Q_INVOKABLE void setRemoteVideoOutput(QObject *output);

        /// Открыть UDP-сокет и подготовить кодек/плейбэк (без захвата микрофона).
        /// Возвращает локальный port (0 при ошибке).
        Q_INVOKABLE quint16 prepare(const QString &localBind, const QString &masterKeyB64, const QString &sessionIdB64,
                                    int role /*0=initiator,1=responder*/);

        /// Указать удалённую сторону (формат "ip:port"). Можно вызывать после
        /// prepare(), пока attachAudio ещё не вызван — или вообще не вызывать,
        /// и тогда peer определится по первому валидному входящему пакету.
        Q_INVOKABLE bool setPeer(const QString &peerAddr);

        /// Получить текущий peer-адрес сессии. Это **rx-источник**: Rust auto-discover
        /// обновляет его при каждом валидном AEAD-пакете → отражает откуда
        /// фактически приходит media (direct UDP source / TURN relay address).
        /// Возвращает пусто если peer ещё не определён или сессия не запущена.
        Q_INVOKABLE QString currentPeer() const;

        /// Получить reflexive IP:port этой сессии через STUN. Использует тот же
        /// UDP-сокет — именно поэтому даёт корректный NAT-mapping для этой сессии.
        /// БЛОКИРУЕТ вызывающий поток до ответа или таймаута; вызывать из
        /// фонового потока (QtConcurrent), не из main thread.
        /// Возвращает пустую строку при ошибке.
        Q_INVOKABLE QString stunDiscover(const QString &stunServer, int timeoutMs);

        /// Выполнить TURN Allocate через тот же UDP-сокет и вернуть relay
        /// candidate (`ip:port`). БЛОКИРУЕТ вызывающий поток до ответа или
        /// таймаута; вызывать из фонового потока.
        Q_INVOKABLE QString turnAllocate(const QString &turnServer, int timeoutMs);

        /// Переключить media peer на TURN relay. Перед вызовом должен успешно
        /// отработать `turnAllocate()` на этом же `turnServer`.
        Q_INVOKABLE bool setTurnPeer(const QString &turnServer, const QString &peerRelayAddr);

        /// Стартовать захват микрофона. Звук пойдёт в эфир.
        Q_INVOKABLE bool attachAudio();

        /// Стартовать захват камеры и H.264 энкодер. Видео пойдёт в эфир.
        /// Возвращает false если video не собран (`videoSupported()==false`),
        /// нет камеры или энкодер не инициализирован.
        Q_INVOKABLE bool attachVideo();

        /// Остановить камеру и энкодер. Удалённая сторона перестанет видеть
        /// картинку (звук продолжит идти).
        Q_INVOKABLE void detachVideo();

        /// Переключить активную камеру (front ↔ back). Просит keyframe, чтобы
        /// получатель быстро восстановил картинку. No-op если видео не активно
        /// или в системе только одна камера.
        Q_INVOKABLE bool switchCamera();

        /// Сколько камер найдено в системе. Для скрытия кнопки переключения в UI.
        Q_INVOKABLE bool hasMultipleCameras() const;

        /// Текущее состояние микрофона. Микрофон можно «заглушить» прямо в
        /// эфире — захват продолжается, но кодируется тишина (опус всё равно
        /// продолжает посылать пакеты для keepalive).
        Q_PROPERTY(bool micMuted READ micMuted WRITE setMicMuted NOTIFY micMutedChanged)
        bool micMuted() const { return mic_muted_; }
        Q_INVOKABLE void setMicMuted(bool muted);

        /// Запросить keyframe у локального энкодера (например, после нового
        /// peer'а или явной просьбы удалённой стороны).
        Q_INVOKABLE void requestKeyframe();

        /// Удобная объединённая обёртка prepare + setPeer + attachAudio.
        Q_INVOKABLE bool start(const QString &localBind, const QString &peerAddr, const QString &masterKeyB64,
                               const QString &sessionIdB64, int role /*0=initiator,1=responder*/);
        Q_INVOKABLE void stop();

    signals:
        void stateChanged();
        void preparedChanged();
        void videoActiveChanged();
        void localVideoPortraitChanged();
        void remoteVideoActiveChanged();
        void mediaReceivedChanged();
        void micMutedChanged();
        void errorOccurred(const QString &message);

    public slots:
        /// Вызывается через `QMetaObject::invokeMethod` из произвольного
        /// потока FFI: помещает фрейм в jitter buffer. `generation` — billet
        /// сессии (см. `session_generation_`); фреймы из закрытой сессии
        /// (gen ≠ current) тихо отбрасываются.
        void enqueueIncomingFrame(const QByteArray &opus, quint64 sequence, quint64 generation);

        /// Вызывается из FFI на каждый расшифрованный видеофрагмент.
        /// `generation` имеет ту же роль, что и в [`enqueueIncomingFrame`].
        void enqueueIncomingVideoFragment(const QByteArray &fragment, quint64 sequence, quint32 rtp_timestamp,
                                          quint8 flags, quint64 generation);

    private slots:
        void onPcmFrameFromMic(const QByteArray &pcm);
        void onJitterTick();
#if PARANOIA_HAS_VIDEO
        void onCameraFrameI420(const QByteArray &i420, qint64 pts_90khz);
#endif

    private:
        void setState(const QString &s);
        void teardownAll();
        void markMediaReceived();
        /// Поп очередного фрейма из jitter buffer. Возвращает:
        /// - непустой QByteArray + has_frame=true — нормальный фрейм
        /// - пустой QByteArray + has_frame=true — PLC (NULL для opus_decode)
        /// - has_frame=false — Wait (ничего не делать)
        struct JitterPop {
            QByteArray opus;
            bool has_frame = false;
            bool plc       = false;
        };
        JitterPop popFromJitter();

        OpusEncoderWrap encoder_;
        OpusDecoderWrap decoder_;
        std::unique_ptr<AudioCapture> capture_;
        std::unique_ptr<AudioPlayback> playback_;
        ::ParanoiaCallSession *session_      = nullptr;
        // Поколение сессии. Инкрементируется на каждый teardown/prepare;
        // используется как «билет» в frame_cb/video_cb, чтобы отбрасывать
        // пакеты, принадлежащие предыдущей сессии — иначе зомби-пакет,
        // успевший попасть в Qt event-queue до session_stop, отравляет jitter
        // buffer следующего звонка.
        quint64 session_generation_          = 0;
        QString state_                       = QStringLiteral("idle");
        quint16 local_port_                  = 0;
        bool mic_muted_                      = false;
        bool video_attached_                 = false;
        bool local_video_portrait_           = false;
        // Гейтинг markMediaReceived() — один раз на сессию.
        bool received_audio_packet_          = false;
        bool remote_video_active_            = false;
        bool media_received_                 = false;

        // Текущий контекст — owned (нужен на время жизни сессии). После
        // teardown'а кладём в `retired_callback_contexts_` чтобы не освобождать
        // память пока в Qt event-queue могут быть отложенные invokeMethod'ы с
        // указателем на этот контекст; при следующем prepare() чистим список.
        std::unique_ptr<CallbackContext> callback_context_;
        std::vector<std::unique_ptr<CallbackContext>> retired_callback_contexts_;

#if PARANOIA_HAS_VIDEO
        std::unique_ptr<VideoCapture> video_capture_;
        std::unique_ptr<H264Encoder> h264_encoder_;
        std::unique_ptr<H264Decoder> h264_decoder_;
        std::unique_ptr<VideoSinkBridge> remote_video_sink_;
        QPointer<QVideoSink> local_preview_sink_;
        // Реассемблер: накапливаем фрагменты NAL по rtp_timestamp с явным
        // упорядочиванием по sequence. Раньше фрагменты с одним rtp_ts
        // склеивались по порядку прихода — на лосси UDP (особенно LTE) видео
        // быстро рассыпалось при любом reorder. Теперь храним пришедшие
        // фрагменты в QMap<seq, bytes> и сливаем в NAL только когда видим
        // сплошной диапазон от FRAME_START до FRAGMENT_END.
        struct VideoReassembly {
            quint32 rtp_ts          = 0;
            bool active             = false;
            quint64 start_seq       = 0; // seq фрагмента с FRAME_START
            quint64 next_expected   = 0; // следующий seq для конкатенации
            bool has_end            = false;
            quint64 end_seq         = 0;
            QByteArray nal;              // накопленный NAL (контигуальная часть от start_seq)
            QMap<quint64, QByteArray> pending; // ещё не приклеенные фрагменты (out-of-order)
        };
        VideoReassembly reassembly_;
        bool received_video_packet_  = false;
        bool h264_decoder_failed_    = false;
        // Sequence counter для исходящих видеопакетов на стороне Qt (но реальная
        // нумерация делается в Rust transport — здесь не используется, оставляем
        // флаг, чтобы при потере соединения попросить keyframe).
#endif

        // Jitter buffer на стороне Qt (упрощённый порт voip::jitter из Rust):
        // sequence → opus. Защищён мьютексом — заполняется через
        // enqueueIncomingFrame (main thread, но дешевле зафиксировать).
        QMutex jitter_mutex_;
        QMap<quint64, QByteArray> jitter_;
        std::optional<quint64> jitter_expected_;
        int jitter_plc_streak_ = 0;
        // Конфиг jitter: стартуем с первого фрейма. Иначе при DTX/потерях можно
        // навсегда зависнуть до decode, хотя первый voice packet уже пришёл.
        static constexpr int kJitterInitialDelay = 1;
        static constexpr int kJitterMaxDepth     = 16;
        static constexpr int kJitterMaxPlcStreak = 12;

        QTimer playbackTimer_; // тикает каждые 20 ms
        // Сбрасывает remote_video_active_=false если давно не приходили
        // видео-кадры. Без этого после выключения камеры удалённой стороной
        // картинка «замирает» — последний кадр остаётся в QVideoSink.
        QTimer remoteVideoIdleTimer_;
        qint64 last_remote_video_ts_ms_ = 0;
    };

} // namespace paranoia::voip
