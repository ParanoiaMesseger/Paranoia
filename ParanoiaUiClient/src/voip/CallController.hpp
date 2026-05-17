#pragma once

#include <QByteArray>
#include <QVariantMap>

#include "CallEngine.hpp"
#include "CallSignalingClient.hpp"

// Forward declaration FFI.
struct ParanoiaHandle;

namespace paranoia::voip
{

    /// State machine звонка, склейка `CallSignaling ↔ CallEngine`.
    ///
    /// Состояния:
    /// - `idle`     — нет активного звонка.
    /// - `outgoing` — мы инициировали Offer, ждём Answer.
    /// - `incoming` — нам пришёл Offer, ждём решения пользователя (Accept/Reject).
    /// - `running`  — установлено соединение, идёт обмен аудио.
    ///
    /// Зависимости (выставляются из main.cpp и обновляются при смене активной сессии):
    ///   setHandle(...)      — ParanoiaHandle активного сервера
    ///   setEngine(...)      — CallEngine
    ///   setSignaling(...)   — CallSignalingClient
    ///   setSelfUsername(..) — наш зарегистрированный server id для сигналинга
    class CallController : public QObject
    {
        Q_OBJECT
        Q_PROPERTY(QString callState READ callState NOTIFY callStateChanged)
        Q_PROPERTY(QString currentPeer READ currentPeer NOTIFY currentPeerChanged)
        Q_PROPERTY(QString currentCallId READ currentCallId NOTIFY currentPeerChanged)
        Q_PROPERTY(bool wantVideo READ wantVideo WRITE setWantVideo NOTIFY wantVideoChanged)
        Q_PROPERTY(bool remoteHasVideo READ remoteHasVideo NOTIFY remoteHasVideoChanged)
    public:
        explicit CallController(QObject *parent = nullptr);

        void setHandle(std::shared_ptr<ParanoiaFFI> handle) { handle_ = handle; }
        void setEngine(CallEngine *engine);
        void setSignaling(CallSignalingClient *signaling);
        void setSelfUsername(const QString &u) { self_username_ = u; }
        void setPeerUserIds(const QVariantMap &peerToUserId);
        /// STUN-сервер для добавления reflexive-кандидата. Если пуст — STUN не
        /// используется (звонок работает только в локальной сети / при
        /// открытом IP).
        void setStunServer(const QString &s) { stun_server_ = s; }
        QString stunServer() const { return stun_server_; }
        /// TURN-сервер для relay fallback. Если пуст — fallback отключён.
        void setTurnServer(const QString &s) { turn_server_ = s; }
        QString turnServer() const { return turn_server_; }

        QString callState() const { return state_; }
        QString currentPeer() const { return peer_; }
        QString currentCallId() const { return call_id_; }
        bool wantVideo() const { return want_video_; }
        bool remoteHasVideo() const { return remote_has_video_; }
        void setWantVideo(bool v);

        /// Инициировать исходящий звонок. `peer` — UI-имя собеседника или server id,
        /// `masterKeyB64` — dialog master key для `voip::signaling::seal`.
        /// Если `wantVideo == true` к моменту вызова — Offer уйдёт с
        /// streams=[0,1] и при ответе ответчика с видео — `attachVideo` поднимется.
        Q_INVOKABLE bool startOutgoingCall(const QString &peer, const QString &masterKeyB64);

        /// Принять входящий звонок (после `incomingCall` сигнала). Видео идёт
        /// в эфир, если и `wantVideo`, и offer содержал stream 1.
        Q_INVOKABLE bool acceptIncomingCall();

        /// Включить/выключить камеру во время уже-установленного звонка. На
        /// первом включении удалённая сторона может ещё не быть в курсе — она
        /// просто увидит видео-фрагменты и автоматически начнёт декодировать.
        Q_INVOKABLE bool toggleVideo(bool on);

        /// Отклонить входящий звонок.
        Q_INVOKABLE void rejectIncomingCall(const QString &reason);

        /// Завершить текущий звонок (любой стадии).
        Q_INVOKABLE void hangupCall(const QString &reason = QString());

    signals:
        void callStateChanged();
        void currentPeerChanged();
        void wantVideoChanged();
        void remoteHasVideoChanged();
        /// Пришёл входящий Offer; UI должен открыть CallPage с кнопками
        /// Accept/Reject. `peerWantsVideo` — peer предлагает video в дополнение
        /// к голосу.
        void incomingCall(const QString &peer, const QString &callId, bool peerWantsVideo);
        /// Звонок установлен (обе стороны в `running`).
        void callConnected();
        /// Звонок завершён по любой причине.
        void callEnded(const QString &reason);
        /// Сообщения об ошибках на любом этапе.
        void controllerError(const QString &message);

    private slots:
        void onOffer(const QString &fromPeer, const QString &callId, const QString &sessionIdB64,
                     const QStringList &candidates, bool peerWantsVideo, qint64 createdTsMs);
        void onAnswer(const QString &fromPeer, const QString &callId, bool accept, const QStringList &candidates,
                      bool peerWantsVideo, const QString &reason);
        void onHangup(const QString &fromPeer, const QString &callId, const QString &reason);
        void onIce(const QString &fromPeer, const QString &callId, const QString &candidate);

    private:
        void setState(const QString &s);
        void resetCallState();

        /// Сериализовать payload и вызвать `paranoia_call_signal_send`.
        bool sendSignal(int kind, const QJsonObject &payload);
        QString peerUserIdFor(const QString &peer) const;
        QString displayPeerFor(const QString &userId) const;

        /// Master key для текущего peer'а. CallController хранит его на время
        /// звонка, чтобы не таскать каждый раз через QML.
        QString currentMasterKey() const { return master_key_b64_; }

        /// Async STUN-discover: после prepare запускается в QtConcurrent;
        /// результат прилетает в `onStunResolved` через `QMetaObject::invokeMethod`.
        void launchStunDiscoverIfConfigured();
        Q_INVOKABLE void onStunResolved(const QString &reflexive);
        void scheduleTurnFallbackCheck();
        void launchTurnFallbackIfConfigured();
        void ensureTurnRouteForPeer(const QString &server, const QString &peerRelay);
        Q_INVOKABLE void onTurnRelayReady(const QString &server, const QString &relay);

        std::shared_ptr<ParanoiaFFI> handle_ = nullptr;
        QPointer<CallEngine> engine_;
        QPointer<CallSignalingClient> signaling_;
        QString self_username_;
        QMap<QString, QString> peer_user_ids_;
        QMap<QString, QString> display_peers_;
        QString stun_server_;
        QString turn_server_;

        // Текущий звонок:
        QString state_ = QStringLiteral("idle");
        QString peer_;
        QString peer_user_id_;
        QString call_id_;
        QString master_key_b64_;
        QString session_id_b64_; // base64 16 байт
        // Для входящего: запоминаем кандидата из offer'а — попробуем setPeer им
        // когда пользователь нажмёт Accept.
        QString pending_peer_addr_;
        QString pending_turn_peer_server_;
        QString pending_turn_peer_relay_;
        QString local_turn_relay_;
        bool turn_fallback_started_ = false;
        bool turn_route_active_     = false;
        /// Пользователь хочет включить камеру для этого звонка. Может меняться
        /// до и во время звонка через `setWantVideo`/`toggleVideo`.
        bool want_video_ = false;
        /// Удалённая сторона объявила/согласилась на видео.
        bool remote_has_video_ = false;
    };

} // namespace paranoia::voip
