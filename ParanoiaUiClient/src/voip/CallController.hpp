#pragma once

#include <QByteArray>
#include <QList>
#include <QPair>
#include <QSet>
#include <QTimer>
#include <QVariantMap>

#include "CallEngine.hpp"
#include "CallSignalingClient.hpp"

// Forward declaration FFI.
struct ParanoiaHandle;

namespace paranoia::voip
{
    /// Категория сетевого пути звонка. Используется и для выбора лучшего
    /// доступного маршрута, и для UI-индикатора. Меньше значение — лучше
    /// (предпочтительнее). Порядок:
    ///   1. Lan — оба собеседника в одной локальной сети (минимальная latency).
    ///   2. Stun — direct P2P через интернет с проколом NAT (STUN reflexive).
    ///   3. OurTurn — через наш TURN relay (адрес derived из активной сессии).
    ///   4. BackupTurn — через один из резервных TURN-серверов (UI list).
    /// `None` — нет ещё выбранного пути.
    enum class CallPath : int {
        None       = 0,
        Lan        = 1,
        Stun       = 2,
        OurTurn    = 3,
        BackupTurn = 4,
    };
    Q_NAMESPACE

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
        /// Текущий выбранный путь tx-трафика (что мы шлём peer'у). Соответствует
        /// `CallPath`-int'у; QML использует через `Call.currentPath`. Меняется
        /// по мере того как connectivity check'и обнаруживают доступные маршруты.
        Q_PROPERTY(int currentPath READ currentPath NOTIFY currentPathChanged)
        /// Текущий путь rx-трафика (откуда нам приходит media). Может отличаться
        /// от tx (асимметричный путь): мы можем слать direct, но peer шлёт нам
        /// через TURN, и наоборот. Обновляется опросом Rust auto-discovered peer'а.
        Q_PROPERTY(int rxPath READ rxPath NOTIFY currentPathChanged)
        /// Человекочитаемая метка tx-пути.
        Q_PROPERTY(QString currentPathLabel READ currentPathLabel NOTIFY currentPathChanged)
        /// Имя текущего активного TURN-сервера (или пусто) — для индикатора.
        Q_PROPERTY(QString activeTurnServer READ activeTurnServer NOTIFY currentPathChanged)
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
        /// Дополнительные TURN-сервера (формат "host:port"). Используются как
        /// упорядоченный backup-список: первичный (`turn_server_`) пробуется
        /// сначала, при недостижимости — следующий из этого списка.
        void setBackupTurnServers(const QStringList &servers) { backup_turn_servers_ = servers; }
        QStringList backupTurnServers() const { return backup_turn_servers_; }

        QString callState() const { return state_; }
        QString currentPeer() const { return peer_; }
        QString currentCallId() const { return call_id_; }
        bool wantVideo() const { return want_video_; }
        bool remoteHasVideo() const { return remote_has_video_; }
        void setWantVideo(bool v);
        int currentPath() const { return static_cast<int>(current_path_); }
        int rxPath() const { return static_cast<int>(rx_path_); }
        QString currentPathLabel() const;
        QString activeTurnServer() const { return active_turn_server_; }

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
        void currentPathChanged();
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
        /// Async TURN-allocate: запускается сразу при prepare параллельно с
        /// STUN-discover. Результат — наш relay-кандидат, отправляется peer'у
        /// Ice trickle'ом, чтобы он успел его получить. На media-route не
        /// переключаемся сразу: trySwitchToTurn ждёт ~grace_ms после running
        /// и переключается только если direct-канал так и не дал media.
        void launchTurnAllocateIfConfigured();
        /// Запустить allocate на конкретном TURN-сервере (primary или backup).
        /// `serverCategory` — OurTurn для основного, BackupTurn для резервных.
        void launchTurnAllocateOn(const QString &server, CallPath serverCategory);
        void ensureTurnRouteForPeer(const QString &server, const QString &peerRelay);
        Q_INVOKABLE void onTurnRelayReady(const QString &server, const QString &relay);
        /// Попытка переключиться на TURN: оба условия должны выполниться —
        /// `local_turn_relay_` есть и peer прислал свой TURN candidate. Если
        /// media уже идёт direct'ом — не трогаем. Иначе ставим setTurnPeer.
        Q_INVOKABLE void trySwitchToTurn();

        // ── ICE connectivity probing (см. C5) ─────────────────────────────
        /// Добавить direct-кандидата peer'а (формат "ip:port"), классифицировать
        /// (Lan/Stun) и запустить STUN-probe через сокет сессии. Probe-результат
        /// прилетает в `onProbeResult` на main thread.
        void registerDirectCandidate(const QString &candidate);
        /// Классифицировать peer-кандидата по типу адреса. Использует список
        /// локальных подсетей (NetUtil::localCandidates) для определения LAN.
        CallPath classifyDirectCandidate(const QString &candidate) const;
        /// Запустить async STUN binding на конкретный peer-адрес через сокет
        /// сессии. На ответ peer'а от его собственного session socket
        /// (отвечает на binding по transport.rs::run_session) — peer считается
        /// reachable.
        void startProbe(const QString &address);
        /// Получен результат пробы — на main thread. Обновляет таблицу,
        /// зовёт promoteBestPath.
        Q_INVOKABLE void onProbeResult(const QString &address, bool reachable);
        /// Выбрать лучший доступный путь среди известных кандидатов и
        /// (TURN-аллокаций + peer-TURN кандидатов) и переключить media-peer на него.
        void promoteBestPath();
        /// Периодически (каждые 10с) перепроверяет вышестоящие пути —
        /// если LAN внезапно стал доступен, переезжаем туда.
        Q_INVOKABLE void onReprobeTick();
        /// Обновить current_path_/active_turn_server_; эмитит сигнал если меняется.
        void setCurrentPath(CallPath path, const QString &turnServer = QString());
        /// Сброс probing-стейта в начале нового звонка / при resetCallState.
        void resetProbingState();
        /// Список доступных TURN-серверов в порядке приоритета (primary first).
        QStringList orderedTurnServers() const;

        std::shared_ptr<ParanoiaFFI> handle_ = nullptr;
        QPointer<CallEngine> engine_;
        QPointer<CallSignalingClient> signaling_;
        QString self_username_;
        QMap<QString, QString> peer_user_ids_;
        QMap<QString, QString> display_peers_;
        QString stun_server_;
        QString turn_server_;
        QStringList backup_turn_servers_;

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

        // ── ICE probing state ─────────────────────────────────────────────
        /// Direct-кандидаты peer'а (без TURN), полученные через Offer/Answer/Ice.
        /// Ключ — нормализованный "host:port". Значение — последний известный
        /// статус probe'а.
        struct DirectCandidateInfo {
            CallPath category   = CallPath::None;
            bool reachable      = false;
            bool inFlight       = false;
            qint64 lastProbeMs  = -1;
            qint64 lastOkMs     = -1;
        };
        QMap<QString, DirectCandidateInfo> direct_candidates_;

        /// TURN-аллокации (наш relay-адрес на каждом серверe из ordered-списка).
        /// Ключ — turn-server "host:port".
        struct TurnAllocInfo {
            CallPath category   = CallPath::OurTurn; // или BackupTurn
            QString localRelay;                       // наш relay-адрес (allocate success)
            bool allocateInFlight  = false;
            bool allocateFailed    = false;
            QString peerRelay;                        // peer's relay, прислан в ICE
        };
        QMap<QString, TurnAllocInfo> turn_allocs_;

        /// Текущий выбранный tx-путь (что мы шлём).
        CallPath current_path_ = CallPath::None;
        /// Rx-путь (откуда нам приходит media). Опрашивается из Rust по
        /// поллингу peer-адреса, обновляется когда auto-discover меняет peer.
        CallPath rx_path_ = CallPath::None;
        /// Если current_path_ ∈ {OurTurn, BackupTurn} — имя TURN-сервера.
        QString active_turn_server_;
        /// Адрес, который сейчас выставлен engine_->setPeer (для дедупа).
        QString active_peer_addr_;
        /// Последний наблюдённый Rust peer-адрес (для дедупа в rx_path detection).
        QString last_observed_peer_;

        /// Таймаут звонка (single-shot): входящий, который никто не принял/отклонил
        /// и инициатор не отбил (его app мог упасть → нет Hangup), не должен звенеть
        /// вечно — иначе state застревает в "incoming", callActive не сбрасывается,
        /// и in-app сигналинг продолжает опрашивать офферы в фоне (мешая фон-сервису).
        /// На истечении: incoming → reject(timeout); outgoing → hangup(timeout).
        QTimer ring_timeout_timer_;
        /// Periodic re-probe тиков для попытки переехать на лучший путь.
        QTimer reprobe_timer_;
        /// Polls Rust peer (auto-discovered source) для определения rx_path.
        QTimer rx_path_poll_timer_;
        /// Обновить rx_path_ по текущему peer-адресу из Rust.
        Q_INVOKABLE void pollRxPath();
        /// Timestamp (ms since epoch) когда стартовал prepare текущего звонка.
        /// Используется в trySwitchToTurn чтобы дать direct grace-window
        /// перед переключением на TURN.
        qint64 call_started_ms_ = 0;
        /// Пользователь хочет включить камеру для этого звонка. Может меняться
        /// до и во время звонка через `setWantVideo`/`toggleVideo`.
        bool want_video_ = false;
        /// Удалённая сторона объявила/согласилась на видео.
        bool remote_has_video_ = false;
    };

} // namespace paranoia::voip
