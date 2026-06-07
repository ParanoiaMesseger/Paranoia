#include "CallController.hpp"

#include <QDateTime>
#include <QDebug>
#include <QHostAddress>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMetaObject>
#include <QNetworkInterface>
#include <QPointer>
#include <QUuid>
#include <QTimer>
#include <QUrl>
#include <QtConcurrent>

#include "NetUtil.hpp"
#include "paranoia_lib.h"

#include <ParanoiaFFI>

namespace paranoia::voip
{

    namespace
    {

        QString randomSessionIdB64()
        {
            QByteArray bytes(16, Qt::Uninitialized);
            auto *gen = QRandomGenerator::system();
            for (int i = 0; i < bytes.size(); ++i) { bytes[i] = static_cast<char>(gen->bounded(256)); }
            return QString::fromUtf8(bytes.toBase64());
        }

        QString freshCallId() { return QUuid::createUuid().toString(QUuid::WithoutBraces); }

        QString logId(const QString &value)
        {
            if (value.isEmpty()) return QStringLiteral("<empty>");
            return value.size() <= 12 ? value : value.left(8) + QStringLiteral("...");
        }

        bool isIpv6Endpoint(const QString &candidate) { return candidate.trimmed().startsWith(QLatin1Char('[')); }

        bool isTurnCandidate(const QString &candidate)
        { return candidate.trimmed().startsWith(QStringLiteral("turn:"), Qt::CaseInsensitive); }

        bool parseTurnCandidate(const QString &candidate, QString &server, QString &relay)
        {
            const QString trimmed = candidate.trimmed();
            if (!isTurnCandidate(trimmed)) return false;
            const QString body = trimmed.mid(5);
            const int sep     = body.indexOf(QLatin1Char('|'));
            if (sep <= 0 || sep + 1 >= body.size()) return false;
            server = body.left(sep).trimmed();
            relay  = body.mid(sep + 1).trimmed();
            return !server.isEmpty() && !relay.isEmpty();
        }

        QString formatTurnCandidate(const QString &server, const QString &relay)
        { return QStringLiteral("turn:%1|%2").arg(server, relay); }

        QString hostFromEndpoint(const QString &endpoint)
        {
            QUrl url(endpoint);
            QString host = url.host();
            if (!host.isEmpty()) return host;
            QString server = endpoint.trimmed();
            if (server.startsWith(QStringLiteral("//"))) server.remove(0, 2);
            const int slash = server.indexOf(QLatin1Char('/'));
            if (slash >= 0) server = server.left(slash);
            if (server.startsWith(QLatin1Char('['))) {
                const int close = server.indexOf(QLatin1Char(']'));
                if (close > 0) return server.mid(1, close - 1);
            }
            const int colon = server.indexOf(QLatin1Char(':'));
            if (colon >= 0) server = server.left(colon);
            return server.trimmed();
        }

        QString normalizeRelayAddress(const QString &turnServer, const QString &relay)
        {
            const QString trimmed = relay.trimmed();
            const bool v4Any = trimmed.startsWith(QStringLiteral("0.0.0.0:"));
            const bool v6Any = trimmed.startsWith(QStringLiteral("[::]:"));
            if (!v4Any && !v6Any) return trimmed;
            const int idx = trimmed.lastIndexOf(QLatin1Char(':'));
            if (idx < 0 || idx + 1 >= trimmed.size()) return trimmed;
            const QString host = hostFromEndpoint(turnServer);
            if (host.isEmpty()) return trimmed;
            return QStringLiteral("%1:%2").arg(host, trimmed.mid(idx + 1));
        }

        QString selectPeerCandidate(const QStringList &candidates)
        {
            // Кандидаты приходят отсортированными у отправителя (см. NetUtil::candidateRank),
            // но сетевой стек peer'а мог их перетасовать. Здесь: первый non-TURN
            // не-пустой кандидат — берётся как initial peer. IPv6 теперь
            // допустим, так как локальный сокет dual-stack (см. bind_call_socket
            // в Rust). Для cross-network на LTE-операторах IPv4-only кандидат
            // часто недостижим без TURN; IPv6 GUA даёт честный P2P-путь.
            // Приоритет IPv4 над IPv6: сначала ищем v4, если нет — берём v6.
            QString firstIpv6;
            for (const auto &candidate : candidates) {
                if (candidate.isEmpty() || isTurnCandidate(candidate)) continue;
                if (isIpv6Endpoint(candidate)) {
                    if (firstIpv6.isEmpty()) firstIpv6 = candidate;
                    continue;
                }
                return candidate; // первый IPv4 — победитель
            }
            return firstIpv6;
        }

        QString firstTurnCandidate(const QStringList &candidates)
        {
            for (const auto &candidate : candidates) {
                if (isTurnCandidate(candidate)) return candidate;
            }
            return {};
        }

        QString describeCandidates(const QStringList &candidates)
        { return candidates.isEmpty() ? QStringLiteral("<none>") : candidates.join(QStringLiteral(", ")); }

    } // namespace

    CallController::CallController(QObject *parent) : QObject(parent)
    {
        // Re-probe тик: каждые 10с пробуем кандидаты выше current_path_,
        // чтобы переехать если LAN/STUN внезапно стали доступны (NAT-rebind,
        // переключение сетей). Стартуем при выборе первого пути, останавливаем
        // в resetCallState. См. C5.
        reprobe_timer_.setInterval(10000);
        reprobe_timer_.setTimerType(Qt::CoarseTimer);
        connect(&reprobe_timer_, &QTimer::timeout, this, &CallController::onReprobeTick);

        // Poll Rust auto-discovered peer-адреса каждые 500мс. Из него вычисляется
        // rx_path: если peer-адрес совпадает с одним из turn_allocs_[].peerRelay
        // → rx идёт через TURN; иначе direct. Это позволяет визуализировать
        // асимметричный путь (tx через TURN, rx direct и наоборот).
        rx_path_poll_timer_.setInterval(500);
        rx_path_poll_timer_.setTimerType(Qt::CoarseTimer);
        connect(&rx_path_poll_timer_, &QTimer::timeout, this, &CallController::pollRxPath);
    }

    void CallController::setEngine(CallEngine *engine) { engine_ = engine; }

    void CallController::setSignaling(CallSignalingClient *signaling)
    {
        if (signaling_) { disconnect(signaling_, nullptr, this, nullptr); }
        signaling_ = signaling;
        if (!signaling) return;
        connect(signaling, &CallSignalingClient::offerReceived, this, &CallController::onOffer);
        connect(signaling, &CallSignalingClient::answerReceived, this, &CallController::onAnswer);
        connect(signaling, &CallSignalingClient::hangupReceived, this, &CallController::onHangup);
        connect(signaling, &CallSignalingClient::iceReceived, this, &CallController::onIce);
    }

    void CallController::setPeerUserIds(const QVariantMap &peerToUserId)
    {
        peer_user_ids_.clear();
        display_peers_.clear();
        for (auto it = peerToUserId.constBegin(); it != peerToUserId.constEnd(); ++it) {
            const QString peer   = it.key();
            const QString userId = it.value().toString();
            if (peer.isEmpty() || userId.isEmpty()) continue;
            peer_user_ids_.insert(peer, userId);
            display_peers_.insert(userId, peer);
        }
    }

    QString CallController::peerUserIdFor(const QString &peer) const
    {
        const QString userId = peer_user_ids_.value(peer);
        return userId.isEmpty() ? peer : userId;
    }

    QString CallController::displayPeerFor(const QString &userId) const
    {
        const QString peer = display_peers_.value(userId);
        return peer.isEmpty() ? userId : peer;
    }

    void CallController::setState(const QString &s)
    {
        if (state_ == s) return;
        state_ = s;
        emit callStateChanged();
    }

    void CallController::resetCallState()
    {
        peer_.clear();
        peer_user_id_.clear();
        call_id_.clear();
        master_key_b64_.clear();
        session_id_b64_.clear();
        pending_peer_addr_.clear();
        pending_turn_peer_server_.clear();
        pending_turn_peer_relay_.clear();
        local_turn_relay_.clear();
        turn_fallback_started_ = false;
        turn_route_active_     = false;
        call_started_ms_       = 0;
        resetProbingState();
        if (remote_has_video_) {
            remote_has_video_ = false;
            emit remoteHasVideoChanged();
        }
        setState(QStringLiteral("idle"));
        emit currentPeerChanged();
    }

    void CallController::setWantVideo(bool v)
    {
        const bool changed = (want_video_ != v);
        if (changed) {
            want_video_ = v;
            emit wantVideoChanged();
        }
        if (state_ != QStringLiteral("running") || !engine_) return;
        // Камера могла не подняться при accept/answer (например, нет доступа или
        // не нашёлся энкодер) — тогда want_video_ уже true, но videoActive() false.
        // Не выходим по совпадению флага: синхронизируем фактическое состояние
        // движка с пожеланием пользователя.
        if (v && !engine_->videoActive()) {
            if (!engine_->attachVideo()) {
                // Откат: камера не запустилась — снимем флаг, иначе пользователь
                // не сможет повторно «нажать» Вкл. камеру через toggleVideo.
                // Конкретную причину уже сообщил движок через errorOccurred —
                // дублировать обобщённое сообщение не нужно.
                if (want_video_) {
                    want_video_ = false;
                    emit wantVideoChanged();
                }
            }
        } else if (!v && engine_->videoActive()) {
            engine_->detachVideo();
        }
    }

    bool CallController::toggleVideo(bool on)
    {
        if (on && !CallEngine::videoSupported()) {
            emit controllerError(CallController::tr("Видео не собрано в этой версии"));
            return false;
        }
        setWantVideo(on);
        if (state_ != QStringLiteral("running") || !engine_) return true;
        return engine_->videoActive() == on;
    }

    namespace
    {
        // Async-callback из Rust tokio-задачи: вызывается в фоне, поэтому
        // переключаемся на main thread через invokeMethod на target QObject.
        struct AsyncSignalContext {
            QPointer<CallController> controller;
            int kind;
            QString call_id;
        };

        extern "C" void onCallSignalSendDone(void *userdata, int status, const char *error_message)
        {
            auto *ctx = static_cast<AsyncSignalContext *>(userdata);
            if (!ctx) return;
            const QString errMsg = (status != 0 && error_message) ? QString::fromUtf8(error_message) : QString();
            const int kind                      = ctx->kind;
            const QString call_id               = ctx->call_id;
            QPointer<CallController> controller = ctx->controller;
            delete ctx;

            if (status == 0 || !controller) return;
            QMetaObject::invokeMethod(
                controller.data(),
                [controller, kind, call_id, errMsg]() {
                    if (!controller) return;
                    qWarning().noquote() << "CallController: async signal kind" << kind << "call" << call_id.left(8)
                                         << "failed:" << errMsg;
                    emit controller->controllerError(QStringLiteral("call_signal_send failed: %1").arg(errMsg));
                },
                Qt::QueuedConnection);
        }
    } // namespace

    bool CallController::sendSignal(int kind, const QJsonObject &payload)
    {
        if (!handle_) {
            emit controllerError(QStringLiteral("no handle for call signal"));
            return false;
        }
        const QString toUserId = peer_user_id_.isEmpty() ? peer_ : peer_user_id_;
        if (self_username_.isEmpty()) {
            emit controllerError(QStringLiteral("self user id is empty"));
            return false;
        }
        if (peer_.isEmpty() || toUserId.isEmpty() || master_key_b64_.isEmpty()) {
            emit controllerError(QStringLiteral("no active call context"));
            return false;
        }
        const QByteArray json = QJsonDocument(payload).toJson(QJsonDocument::Compact);

        // Async send: UI не блокируется HTTP-запросом. Callback прилетит из
        // фонового tokio-потока; в нём — controllerError при ошибке.
        auto *ctx       = new AsyncSignalContext;
        ctx->controller = this;
        ctx->kind       = kind;
        ctx->call_id    = payload.value(QStringLiteral("call_id")).toString();

        const int rc = handle_->callSignalSendAsync(self_username_, toUserId, master_key_b64_,
                                                    static_cast<unsigned char>(kind), json,
                                                    &onCallSignalSendDone, ctx);
        if (rc != 0) {
            const QString message = QStringLiteral("call_signal_send_async failed: %1").arg(ParanoiaFFI::last_error());
            qWarning().noquote() << "CallController:" << message << "kind" << kind << "from" << logId(self_username_)
                                 << "to" << logId(toUserId);
            delete ctx;
            emit controllerError(message);
            return false;
        }
        return true;
    }

    bool CallController::startOutgoingCall(const QString &peer, const QString &masterKeyB64)
    {
        if (!handle_ || !engine_ || !signaling_) {
            emit controllerError(QStringLiteral("controller not configured"));
            return false;
        }
        if (state_ != QStringLiteral("idle")) {
            emit controllerError(QStringLiteral("call already in progress"));
            return false;
        }
        if (self_username_.isEmpty()) {
            emit controllerError(QStringLiteral("self user id is empty"));
            return false;
        }

        peer_           = peer;
        peer_user_id_   = peerUserIdFor(peer);
        master_key_b64_ = masterKeyB64;
        call_id_        = freshCallId();
        session_id_b64_ = randomSessionIdB64();
        setState(QStringLiteral("outgoing"));
        emit currentPeerChanged();

        // Подготовить UDP-сокет — узнаём наш локальный port для кандидатов.
        const quint16 port =
            engine_->prepare(QStringLiteral("0.0.0.0:0"), master_key_b64_, session_id_b64_, /*role=*/0);
        if (port == 0 || engine_->state() != QStringLiteral("prepared")) {
            emit controllerError(QStringLiteral("CallEngine prepare failed"));
            engine_->stop();
            resetCallState();
            return false;
        }
        call_started_ms_ = QDateTime::currentMSecsSinceEpoch();

        QJsonObject payload;
        payload.insert(QStringLiteral("call_id"), call_id_);
        payload.insert(QStringLiteral("session_id"), session_id_b64_);
        QJsonArray streams;
        streams.append(0); // voice always
        if (want_video_ && CallEngine::videoSupported()) {
            streams.append(1); // request video
        }
        payload.insert(QStringLiteral("streams"), streams);
        const QStringList localCandidates = NetUtil::localCandidates(port);
        QJsonArray candidates;
        for (const auto &c : localCandidates) candidates.append(c);
        payload.insert(QStringLiteral("candidates"), candidates);
        payload.insert(QStringLiteral("from_username"), self_username_);
        payload.insert(QStringLiteral("created_ts_ms"), QDateTime::currentMSecsSinceEpoch());
        qInfo().noquote() << "CallController: outgoing offer peer" << peer_ << "user" << logId(peer_user_id_) << "call"
                          << logId(call_id_) << "candidates" << describeCandidates(localCandidates);
        if (localCandidates.isEmpty()) {
            qWarning().noquote() << "CallController: outgoing offer has no IPv4 media candidates";
        }

        if (!sendSignal(/*kind=Offer*/ 0, payload)) {
            engine_->stop();
            resetCallState();
            return false;
        }
        // Параллельно запускаем STUN-discover и TURN-allocate — reflexive и
        // relay-кандидаты улетят peer'у отдельными Ice trickle сообщениями.
        // Раньше TURN ждал 7s после running и срабатывал только если direct
        // не пробился — это давало 7-10s задержку до медиа. Теперь allocate
        // стартует сразу; реальное переключение setTurnPeer выполняется через
        // trySwitchToTurn с короткой grace window (~1.5s) только если direct
        // действительно не дал media.
        launchStunDiscoverIfConfigured();
        launchTurnAllocateIfConfigured();
        return true;
    }

    void CallController::onOffer(const QString &fromPeer, const QString &callId, const QString &sessionIdB64,
                                 const QStringList &candidates, bool peerWantsVideo, qint64 /*createdTsMs*/)
    {
        if (state_ != QStringLiteral("idle")) {
            // Уже занят — пошлём Hangup, чтобы peer знал, что мы не доступны.
            // Делаем это «вручную», не трогая текущее состояние.
            if (handle_) {
                QJsonObject p;
                p.insert(QStringLiteral("call_id"), callId);
                p.insert(QStringLiteral("reason"), QStringLiteral("busy"));
                const QByteArray json = QJsonDocument(p).toJson(QJsonDocument::Compact);
                // master_key для отказа не критичен — без правильного ключа
                // сторона не сможет расшифровать; используем уже знаемый ключ если
                // он у нас был ранее. Для простоты: если master_key_b64_ пуст — не отвечаем.
                if (!master_key_b64_.isEmpty())
                    handle_->callSignalSendAsync(self_username_, fromPeer, master_key_b64_, 2 /*Hangup*/, json,
                                                 nullptr, nullptr);
            }
            return;
        }
        peer_              = fromPeer;
        peer_user_id_      = fromPeer;
        peer_              = displayPeerFor(fromPeer);
        call_id_           = callId;
        session_id_b64_    = sessionIdB64;
        pending_peer_addr_ = selectPeerCandidate(candidates);
        pending_turn_peer_server_.clear();
        pending_turn_peer_relay_.clear();
        QString turnServer;
        QString turnRelay;
        if (parseTurnCandidate(firstTurnCandidate(candidates), turnServer, turnRelay)) {
            pending_turn_peer_server_ = turnServer;
            pending_turn_peer_relay_  = normalizeRelayAddress(turnServer, turnRelay);
        }
        // C5: регистрируем ВСЕ direct-кандидаты (не только первый) для пробинга.
        // Пробы стартуют после accept (engine prepared); пока engine_->state()==idle,
        // registerDirectCandidate просто запомнит в direct_candidates_.
        for (const auto &c : candidates) {
            if (c.isEmpty() || isTurnCandidate(c)) continue;
            registerDirectCandidate(c);
        }
        if (remote_has_video_ != peerWantsVideo) {
            remote_has_video_ = peerWantsVideo;
            emit remoteHasVideoChanged();
        }
        // master_key для собеседника берём из CallSignalingClient — тот же набор
        // ключей он использует для расшифровки конвертов.
        if (signaling_) {
            master_key_b64_ = signaling_->masterKeyFor(fromPeer);
            if (master_key_b64_.isEmpty() && peer_ != fromPeer) { master_key_b64_ = signaling_->masterKeyFor(peer_); }
        }
        qInfo().noquote() << "CallController: incoming offer from" << logId(fromPeer) << "display" << peer_ << "call"
                          << logId(callId) << "candidates" << describeCandidates(candidates) << "selected"
                          << (pending_peer_addr_.isEmpty() ? QStringLiteral("<none>") : pending_peer_addr_);
        if (!candidates.isEmpty() && pending_peer_addr_.isEmpty()) {
            qWarning().noquote() << "CallController: incoming offer has no usable IPv4 media candidate";
        }
        if (master_key_b64_.isEmpty()) {
            qWarning().noquote() << "CallController: incoming offer has no master key for" << logId(fromPeer)
                                 << "display" << peer_;
        }
        setState(QStringLiteral("incoming"));
        emit currentPeerChanged();
        emit incomingCall(peer_, callId, peerWantsVideo);
    }

    bool CallController::acceptIncomingCall()
    {
        if (state_ != QStringLiteral("incoming")) {
            emit controllerError(QStringLiteral("no incoming call to accept"));
            return false;
        }
        if (master_key_b64_.isEmpty()) {
            emit controllerError(QStringLiteral("master key for caller is unknown"));
            return false;
        }
        if (!engine_) {
            emit controllerError(QStringLiteral("no call engine"));
            return false;
        }

        const quint16 port =
            engine_->prepare(QStringLiteral("0.0.0.0:0"), master_key_b64_, session_id_b64_, /*role=*/1);
        if (port == 0 || engine_->state() != QStringLiteral("prepared")) {
            emit controllerError(QStringLiteral("CallEngine prepare failed"));
            engine_->stop();
            resetCallState();
            return false;
        }
        call_started_ms_ = QDateTime::currentMSecsSinceEpoch();

        // Шлём Answer с нашими кандидатами.
        const bool acceptVideo = want_video_ && remote_has_video_ && CallEngine::videoSupported();
        QJsonObject answer;
        answer.insert(QStringLiteral("call_id"), call_id_);
        answer.insert(QStringLiteral("accept"), true);
        const QStringList localCandidates = NetUtil::localCandidates(port);
        QJsonArray candidates;
        for (const auto &c : localCandidates) candidates.append(c);
        answer.insert(QStringLiteral("candidates"), candidates);
        QJsonArray streams;
        streams.append(0);
        if (acceptVideo) streams.append(1);
        answer.insert(QStringLiteral("streams"), streams);
        answer.insert(QStringLiteral("reason"), QString());
        qInfo().noquote() << "CallController: answering call" << logId(call_id_) << "candidates"
                          << describeCandidates(localCandidates) << "peer"
                          << (pending_peer_addr_.isEmpty() ? QStringLiteral("<none>") : pending_peer_addr_);
        if (localCandidates.isEmpty()) {
            qWarning().noquote() << "CallController: answer has no IPv4 media candidates";
        }
        if (!sendSignal(/*kind=Answer*/ 1, answer)) {
            engine_->stop();
            resetCallState();
            return false;
        }

        // Подключаемся к первому кандидату из offer'а (если он есть). Если нет —
        // подождём auto-discovery от инициатора.
        // ВАЖНО: pending_peer_addr_ мог быть обновлён в onIce ICE-trickle'ом до
        // Accept'а (часто reflexive peer'а, который недоступен в исходном offer'е).
        // Регистрируем его как probing-кандидат тоже — иначе мы пытаемся
        // setPeer на reflexive, но он не пробуется, и при первой неудаче TURN
        // мы остаёмся на TURN навсегда, даже если reflexive начнёт работать.
        if (!pending_peer_addr_.isEmpty()) {
            engine_->setPeer(pending_peer_addr_);
            active_peer_addr_ = pending_peer_addr_;
            registerDirectCandidate(pending_peer_addr_);
        }
        // Теперь когда engine prepared — запускаем probing уже зарегистрированных
        // direct-кандидатов (могли быть зарегистрированы в onOffer/onIce пока
        // мы ещё были incoming). startProbe внутри idempotent (inFlight guard).
        for (auto it = direct_candidates_.begin(); it != direct_candidates_.end(); ++it) {
            startProbe(it.key());
        }
        if (!pending_turn_peer_server_.isEmpty() && !pending_turn_peer_relay_.isEmpty()) {
            ensureTurnRouteForPeer(pending_turn_peer_server_, pending_turn_peer_relay_);
        }
        if (!engine_->attachAudio()) {
            engine_->stop();
            resetCallState();
            return false;
        }
        if (acceptVideo) { engine_->attachVideo(); }
        setState(QStringLiteral("running"));
        emit callConnected();
        // STUN+TURN параллельно — наш reflexive улучшит шансы прямого
        // соединения через NAT, наш relay даст peer'у TURN-fallback на случай
        // невозможности direct (CGNAT, symmetric NAT). Реальный switch на
        // TURN — через trySwitchToTurn с grace window от prepare.
        launchStunDiscoverIfConfigured();
        launchTurnAllocateIfConfigured();
        return true;
    }

    void CallController::rejectIncomingCall(const QString &reason)
    {
        if (state_ != QStringLiteral("incoming")) return;
        QJsonObject answer;
        answer.insert(QStringLiteral("call_id"), call_id_);
        answer.insert(QStringLiteral("accept"), false);
        answer.insert(QStringLiteral("candidates"), QJsonArray());
        answer.insert(QStringLiteral("reason"), reason);
        sendSignal(1, answer);
        emit callEnded(QStringLiteral("rejected"));
        resetCallState();
    }

    void CallController::hangupCall(const QString &reason)
    {
        if (state_ == QStringLiteral("idle")) return;
        QJsonObject p;
        p.insert(QStringLiteral("call_id"), call_id_);
        p.insert(QStringLiteral("reason"), reason);
        sendSignal(2, p);
        if (engine_) engine_->stop();
        emit callEnded(reason.isEmpty() ? QStringLiteral("hangup") : reason);
        resetCallState();
    }

    void CallController::onAnswer(const QString &fromPeer, const QString &callId, bool accept,
                                  const QStringList &candidates, bool peerWantsVideo, const QString &reason)
    {
        const QString expectedPeer = peer_user_id_.isEmpty() ? peer_ : peer_user_id_;
        if (state_ != QStringLiteral("outgoing") || fromPeer != expectedPeer || callId != call_id_) return;
        if (!accept) {
            if (engine_) engine_->stop();
            emit callEnded(reason.isEmpty() ? QStringLiteral("declined") : reason);
            resetCallState();
            return;
        }
        if (!engine_) {
            emit controllerError(QStringLiteral("no engine to attach"));
            return;
        }
        if (remote_has_video_ != peerWantsVideo) {
            remote_has_video_ = peerWantsVideo;
            emit remoteHasVideoChanged();
        }
        const QString peerCandidate = selectPeerCandidate(candidates);
        QString turnServer;
        QString turnRelay;
        const bool hasTurnCandidate = parseTurnCandidate(firstTurnCandidate(candidates), turnServer, turnRelay);
        qInfo().noquote() << "CallController: answer from" << logId(fromPeer) << "call" << logId(callId) << "candidates"
                          << describeCandidates(candidates) << "selected"
                          << (peerCandidate.isEmpty() ? QStringLiteral("<none>") : peerCandidate);
        if (!candidates.isEmpty() && peerCandidate.isEmpty()) {
            qWarning().noquote() << "CallController: answer has no usable IPv4 media candidate";
        }
        if (!peerCandidate.isEmpty()) {
            engine_->setPeer(peerCandidate);
            active_peer_addr_ = peerCandidate;
        }
        // C5: регистрируем все direct-кандидаты для probing.
        for (const auto &c : candidates) {
            if (c.isEmpty() || isTurnCandidate(c)) continue;
            registerDirectCandidate(c);
        }
        if (hasTurnCandidate) { ensureTurnRouteForPeer(turnServer, normalizeRelayAddress(turnServer, turnRelay)); }
        if (!engine_->attachAudio()) {
            hangupCall(QStringLiteral("engine_attach_failed"));
            return;
        }
        // Если обе стороны согласны на видео — включаем камеру.
        if (want_video_ && peerWantsVideo && CallEngine::videoSupported()) { engine_->attachVideo(); }
        setState(QStringLiteral("running"));
        emit callConnected();
        // Все решения о switch'е на TURN делает promoteBestPath — он смотрит
        // на завершённость direct probes и не downgrade'ит media-канал на TURN
        // пока есть шанс на direct.
        promoteBestPath();
    }

    void CallController::onHangup(const QString &fromPeer, const QString &callId, const QString &reason)
    {
        if (state_ == QStringLiteral("idle")) return;
        const QString expectedPeer = peer_user_id_.isEmpty() ? peer_ : peer_user_id_;
        if (fromPeer != expectedPeer || callId != call_id_) return;
        qInfo().noquote() << "CallController: remote hangup from" << logId(fromPeer) << "call" << logId(callId)
                          << "reason" << (reason.isEmpty() ? QStringLiteral("<empty>") : reason);
        if (engine_) engine_->stop();
        emit callEnded(reason.isEmpty() ? QStringLiteral("remote_hangup") : reason);
        resetCallState();
    }

    void CallController::onIce(const QString &fromPeer, const QString &callId, const QString &candidate)
    {
        const QString expectedPeer = peer_user_id_.isEmpty() ? peer_ : peer_user_id_;
        if (fromPeer != expectedPeer || callId != call_id_) return;
        if (!engine_ || candidate.isEmpty()) return;
        QString turnServer;
        QString turnRelay;
        if (parseTurnCandidate(candidate, turnServer, turnRelay)) {
            const QString relay = normalizeRelayAddress(turnServer, turnRelay);
            qInfo().noquote() << "CallController: TURN candidate from" << logId(fromPeer) << "call" << logId(callId)
                              << relay << "via" << turnServer;
            ensureTurnRouteForPeer(turnServer, relay);
            return;
        }
        // IPv6 ICE кандидаты допустимы: сокет dual-stack (см. bind_call_socket
        // в Rust), peer может оказаться на IPv6-only LTE (DNS64/NAT64).
        // Регистрируем кандидата в probing-pipeline: classify + start STUN probe.
        // promoteBestPath сам решит переключаться или нет, и не сделает
        // downgrade с TURN на bad direct (turn_route_active_ остаётся active).
        // Ice trickle может прилететь раньше, чем callee нажал Accept — engine_
        // ещё не prepared. В этом случае откладываем как legacy pending_peer_addr_
        // (для acceptIncomingCall — он использует это как initial setPeer),
        // а в direct_candidates_ всё равно добавляем, чтобы probing запустился
        // ПОСЛЕ accept (startProbe внутри проверяет engine state).
        const QString engineState = engine_->state();
        if (engineState != QStringLiteral("prepared") && engineState != QStringLiteral("running")) {
            pending_peer_addr_ = candidate;
            // Регистрируем — пробинг готов запуститься как только engine prepared.
            // Probing внутри startProbe пропустит вызов из idle-state, но
            // candidate уже будет в direct_candidates_; в acceptIncomingCall
            // запускается probing-loop по всем зарегистрированным.
            registerDirectCandidate(candidate);
            return;
        }
        qInfo().noquote() << "CallController: ICE candidate from" << logId(fromPeer) << "call" << logId(callId)
                          << candidate;
        // Раньше: безусловный setPeer(candidate) — последний кандидат всегда
        // побеждал. Теперь: регистрируем в pipeline, пробим, promoteBestPath
        // сам выберет лучший путь и не downgrade'нет с уже работающего TURN.
        registerDirectCandidate(candidate);
        // Если ещё нет ни одного пути и engine только что prepared — для
        // быстрого старта выставим peer сразу, чтобы auto-discover мог сработать.
        // promoteBestPath потом upgrade'нет когда probe подтвердит reachable.
        if (current_path_ == CallPath::None && active_peer_addr_.isEmpty()) {
            engine_->setPeer(candidate);
            active_peer_addr_ = candidate;
        }
    }

    void CallController::launchStunDiscoverIfConfigured()
    {
        if (stun_server_.isEmpty() || !engine_) return;
        const QString server = stun_server_;
        // QPointer защищает от dangling-указателя если engine_ удалится за время
        // STUN-операции (теоретически — practically он живёт всю программу).
        QPointer<CallEngine> engine   = engine_;
        QPointer<CallController> self = this;
        auto future                   = QtConcurrent::run([engine, self, server]() {
            if (!engine || !self) return;
            const QString reflexive = engine->stunDiscover(server, /*timeoutMs=*/3000);
            if (!self || reflexive.isEmpty()) return;
            QMetaObject::invokeMethod(self.data(), "onStunResolved", Qt::QueuedConnection, Q_ARG(QString, reflexive));
        });
        Q_UNUSED(future);
    }

    void CallController::onStunResolved(const QString &reflexive)
    {
        if (reflexive.isEmpty()) return;
        // Отдаём reflexive-кандидат удалённой стороне отдельным Ice trickle.
        // Кандидат в `candidate` поле, наша сторона у peer'а уже знает call_id.
        if (state_ != QStringLiteral("outgoing") && state_ != QStringLiteral("incoming") &&
            state_ != QStringLiteral("running")) {
            return;
        }
        QJsonObject ice;
        ice.insert(QStringLiteral("call_id"), call_id_);
        ice.insert(QStringLiteral("candidate"), reflexive);
        sendSignal(/*kind=Ice*/ 3, ice);
    }

    void CallController::launchTurnAllocateIfConfigured()
    {
        if (turn_server_.isEmpty() || !engine_ || turn_fallback_started_) return;
        // Allocate использует Rust session handle — без prepare его ещё нет.
        // Это нормальная ситуация для callee, у которого Ice trickle с peer'овским
        // TURN candidate прилетает в state=incoming: повторный запуск произойдёт
        // в acceptIncomingCall.
        if (engine_->state() == QStringLiteral("idle")) return;
        turn_fallback_started_ = true;
        // Делегируем единой реализации launchTurnAllocateOn — она правильно
        // вызывает onTurnRelayReady даже при пустом relay (failed allocate),
        // что включает auto-fallback на следующий TURN из ordered-списка.
        launchTurnAllocateOn(turn_server_, CallPath::OurTurn);
    }

    void CallController::ensureTurnRouteForPeer(const QString &server, const QString &peerRelay)
    {
        if (!engine_ || server.isEmpty() || peerRelay.isEmpty()) return;
        // Запоминаем peer'овский TURN candidate всегда — переключение делается в
        // trySwitchToTurn (требует ещё своего relay + проверки mediaReceived).
        pending_turn_peer_server_ = server;
        pending_turn_peer_relay_  = peerRelay;
        // Регистрируем peer-relay в turn_allocs_ для этого сервера — promoteBestPath
        // подберёт когда наш собственный allocate на том же сервере завершится.
        TurnAllocInfo &info = turn_allocs_[server];
        info.peerRelay      = peerRelay;
        if (info.category == CallPath::None) {
            // Категория определяется тем, какой это сервер в нашем ordered-списке.
            const QStringList ordered = orderedTurnServers();
            const int idx = ordered.indexOf(server);
            info.category = (idx == 0) ? CallPath::OurTurn : CallPath::BackupTurn;
        }
        // На случай если для сессии не был сконфигурирован свой TURN-сервер —
        // используем тот, что прислал peer (он у нас тот же, напр. paranoia.example.com).
        if (turn_server_.isEmpty()) turn_server_ = server;
        // Allocate уже стартует в prepare-flow, но если по какой-то причине не
        // запускался (например, мы получили peer TURN раньше своего allocate-
        // запуска) — поднимем сейчас.
        if (!turn_fallback_started_) launchTurnAllocateIfConfigured();
        // Решение о переключении на TURN — только в promoteBestPath, который
        // ждёт завершения direct probes (см. C5).
        promoteBestPath();
    }

    void CallController::onTurnRelayReady(const QString &server, const QString &relay)
    {
        // Обновляем turn_allocs_ независимо от состояния звонка — даже если
        // звонок завершился, мы не хотим утечки stale-state'а в следующий звонок.
        TurnAllocInfo &info  = turn_allocs_[server];
        info.allocateInFlight = false;
        if (relay.isEmpty()) {
            info.allocateFailed = true;
            qWarning().noquote() << "CallController: TURN allocate failed for" << server;
            // Если это primary и есть backups — пробуем следующий.
            const QStringList ordered = orderedTurnServers();
            const int idx             = ordered.indexOf(server);
            if (idx >= 0 && idx + 1 < ordered.size()) {
                const QString next = ordered[idx + 1];
                const CallPath cat = (idx + 1 == 0) ? CallPath::OurTurn : CallPath::BackupTurn;
                qInfo().noquote() << "CallController: trying backup TURN" << next;
                launchTurnAllocateOn(next, cat);
            }
            return;
        }
        if (state_ != QStringLiteral("outgoing") && state_ != QStringLiteral("incoming") &&
            state_ != QStringLiteral("running")) {
            return;
        }
        const QString normalized = normalizeRelayAddress(server, relay);
        info.localRelay          = normalized;
        if (info.category == CallPath::None) {
            const QStringList ordered = orderedTurnServers();
            const int idx             = ordered.indexOf(server);
            info.category             = (idx == 0) ? CallPath::OurTurn : CallPath::BackupTurn;
        }
        // Это первый «наш» relay — синхронизируем legacy-поле для совместимости.
        if (local_turn_relay_.isEmpty() || server == turn_server_) {
            local_turn_relay_ = normalized;
        }
        // Анонсируем peer'у наш relay через ICE trickle.
        QJsonObject ice;
        ice.insert(QStringLiteral("call_id"), call_id_);
        ice.insert(QStringLiteral("candidate"), formatTurnCandidate(server, normalized));
        sendSignal(/*kind=Ice*/ 3, ice);

        // Если у нас уже есть peer-relay на этом сервере — рассмотрим переключение.
        // ВАЖНО: promoteBestPath имеет proper guards (защита от premature switch
        // когда direct probes ещё в полёте). Раньше тут параллельно вызывался
        // trySwitchToTurn (legacy), который не знал про probes и переключал
        // на TURN сразу — это ломало direct-канал (см. C5 анализ).
        if (!info.peerRelay.isEmpty()) {
            promoteBestPath();
        }
    }

    void CallController::trySwitchToTurn()
    {
        if (turn_route_active_ || !engine_) return;
        if (local_turn_relay_.isEmpty()) return;
        if (pending_turn_peer_server_.isEmpty() || pending_turn_peer_relay_.isEmpty()) return;
        // Direct-канал уже доносит media — TURN-хоп не нужен.
        if (engine_->mediaReceived()) return;
        // Grace window от момента prepare: даём direct-кандидату ~1.5s
        // на пробив. Если за это время media не пошло — switch.
        constexpr qint64 kTurnGraceMs = 1500;
        const qint64 elapsed = call_started_ms_ ? (QDateTime::currentMSecsSinceEpoch() - call_started_ms_) : LLONG_MAX;
        if (elapsed < kTurnGraceMs) {
            QPointer<CallController> self = this;
            QTimer::singleShot(static_cast<int>(kTurnGraceMs - elapsed) + 50, this, [self]() {
                if (self) self->trySwitchToTurn();
            });
            return;
        }
        if (engine_->setTurnPeer(pending_turn_peer_server_, pending_turn_peer_relay_)) {
            turn_route_active_ = true;
            pending_turn_peer_server_.clear();
            pending_turn_peer_relay_.clear();
            engine_->requestKeyframe();
        }
    }

    // ── C5: ICE connectivity probing + path priority ───────────────────────

    QString CallController::currentPathLabel() const
    {
        switch (current_path_) {
            case CallPath::None: return QStringLiteral("—");
            case CallPath::Lan: return CallController::tr("Локальная сеть");
            case CallPath::Stun: return CallController::tr("Прямое (через интернет)");
            case CallPath::OurTurn:
                return active_turn_server_.isEmpty() ? CallController::tr("TURN-relay")
                                                     : CallController::tr("TURN: %1").arg(active_turn_server_);
            case CallPath::BackupTurn:
                return active_turn_server_.isEmpty()
                           ? CallController::tr("Резервный TURN-relay")
                           : CallController::tr("Резервный TURN: %1").arg(active_turn_server_);
        }
        return QStringLiteral("—");
    }

    QStringList CallController::orderedTurnServers() const
    {
        QStringList out;
        if (!turn_server_.isEmpty()) out.append(turn_server_);
        for (const auto &b : backup_turn_servers_) {
            if (!b.isEmpty() && !out.contains(b, Qt::CaseInsensitive)) out.append(b);
        }
        return out;
    }

    void CallController::setCurrentPath(CallPath path, const QString &turnServer)
    {
        if (current_path_ == path && active_turn_server_ == turnServer) return;
        current_path_       = path;
        active_turn_server_ = turnServer;
        emit currentPathChanged();
        qInfo().noquote() << "CallController: current path ->" << currentPathLabel();
    }

    void CallController::resetProbingState()
    {
        direct_candidates_.clear();
        turn_allocs_.clear();
        active_peer_addr_.clear();
        last_observed_peer_.clear();
        const bool pathChanged = (current_path_ != CallPath::None || rx_path_ != CallPath::None);
        current_path_ = CallPath::None;
        rx_path_      = CallPath::None;
        active_turn_server_.clear();
        if (pathChanged) emit currentPathChanged();
        reprobe_timer_.stop();
        rx_path_poll_timer_.stop();
    }

    void CallController::pollRxPath()
    {
        if (!engine_ || state_ == QStringLiteral("idle")) {
            rx_path_poll_timer_.stop();
            return;
        }
        const QString peer = engine_->currentPeer();
        // rx_path определяется только при mediaReceived=true: до этого peer может
        // быть просто адресом который мы set'нули через setPeer/setTurnPeer
        // (может быть unreachable, например Tecno's mobile internal 100.82.x.x).
        // Чтобы индикатор не врал и promoteBestPath не "застревал" на мнимом
        // direct, держим rx_path=None пока хоть один media-пакет не пришёл.
        const bool mediaConfirmedNow = engine_->mediaReceived();
        if (peer == last_observed_peer_ && (rx_path_ != CallPath::None || !mediaConfirmedNow)) return;
        last_observed_peer_ = peer;
        CallPath newRx = CallPath::None;
        if (!mediaConfirmedNow) {
            // peer есть, но media ещё не подтверждён — индикатор остаётся "Подключение".
            if (rx_path_ != CallPath::None) {
                rx_path_ = CallPath::None;
                emit currentPathChanged();
            }
            return;
        }
        if (peer.isEmpty()) {
            newRx = CallPath::None;
        } else {
            // Проверяем TURN-сервера: если peer match'ит peerRelay какого-то allocation
            // → rx идёт через TURN (мы получаем data indication с этим relay-адресом).
            for (auto it = turn_allocs_.constBegin(); it != turn_allocs_.constEnd(); ++it) {
                if (it.value().peerRelay == peer) {
                    newRx = it.value().category;
                    break;
                }
            }
            if (newRx == CallPath::None) {
                // Не TURN — значит direct. Категорию берём из направленной классификации.
                newRx = classifyDirectCandidate(peer);
                if (newRx == CallPath::None) newRx = CallPath::Stun; // fallback
            }
        }
        const bool rxChanged = (rx_path_ != newRx);
        rx_path_ = newRx;
        // current_path_ синхронизируется с Rust peer'ом ТОЛЬКО когда media
        // реально течёт (mediaReceived=true). До этого peer — это просто
        // address который мы set'нули (setPeer/setTurnPeer); он может
        // указывать на недоступный адрес (например Tecno's mobile internal
        // 100.82.x.x). Если бы мы обновляли current_path_ без подтверждения,
        // promoteBestPath видел бы current_path_=Direct и из-за no-downgrade
        // rule никогда не переключал бы на TURN. В итоге звонок зависал в
        // мнимом "direct" без реальной связи.
        bool currentChanged = false;
        const bool mediaConfirmed = engine_->mediaReceived();
        if (mediaConfirmed && newRx != CallPath::None && current_path_ != newRx) {
            QString turnSrv;
            if (newRx == CallPath::OurTurn || newRx == CallPath::BackupTurn) {
                for (auto it = turn_allocs_.constBegin(); it != turn_allocs_.constEnd(); ++it) {
                    if (it.value().peerRelay == peer) {
                        turnSrv = it.key();
                        break;
                    }
                }
            }
            current_path_       = newRx;
            active_turn_server_ = turnSrv;
            active_peer_addr_   = peer;
            turn_route_active_  = (newRx == CallPath::OurTurn || newRx == CallPath::BackupTurn);
            currentChanged      = true;
        }
        if (rxChanged) {
            qInfo().noquote() << "CallController: rx path ->"
                              << (newRx == CallPath::None      ? "None"
                                  : newRx == CallPath::Lan     ? "LAN"
                                  : newRx == CallPath::Stun    ? "Direct (P2P)"
                                  : newRx == CallPath::OurTurn ? "OurTurn"
                                                               : "BackupTurn")
                              << "(peer=" << peer << ", mediaConfirmed=" << mediaConfirmed << ")";
        }
        if (rxChanged || currentChanged) emit currentPathChanged();
    }

    namespace
    {
        /// Распарсить "ip:port" / "[v6]:port". Возвращает host (без порта).
        QString hostOfEndpoint(const QString &endpoint)
        {
            const QString s = endpoint.trimmed();
            if (s.startsWith('[')) {
                const int close = s.indexOf(']');
                if (close > 0) return s.mid(1, close - 1);
                return s;
            }
            const int lastColon = s.lastIndexOf(':');
            if (lastColon < 0) return s;
            return s.left(lastColon);
        }

        /// Является ли IPv4 в одной из наших локальных подсетей.
        bool sameLanAsLocal(const QHostAddress &peer)
        {
            const QAbstractSocket::NetworkLayerProtocol peerProto = peer.protocol();
            for (const auto &iface : QNetworkInterface::allInterfaces()) {
                const auto flags = iface.flags();
                if (!(flags & QNetworkInterface::IsUp)) continue;
                if (!(flags & QNetworkInterface::IsRunning)) continue;
                if (flags & QNetworkInterface::IsLoopBack) continue;
                for (const auto &entry : iface.addressEntries()) {
                    const QHostAddress local = entry.ip();
                    if (local.protocol() != peerProto) continue;
                    const int prefix = entry.prefixLength();
                    if (prefix <= 0) continue;
                    if (peer.isInSubnet(local, prefix)) return true;
                }
            }
            return false;
        }
    } // namespace

    CallPath CallController::classifyDirectCandidate(const QString &candidate) const
    {
        const QString host = hostOfEndpoint(candidate);
        QHostAddress addr(host);
        if (addr.isNull()) return CallPath::Stun; // unparsable — пробуем как public
        if (addr.isLoopback() || addr.isLinkLocal()) return CallPath::Stun; // bad, но пробуем
        // Сначала проверяем: в одной ли мы LAN.
        if (sameLanAsLocal(addr)) return CallPath::Lan;
        // Приватный IP, но не наша LAN → недостижимо direct, скорее VPN/cross-subnet.
        // Помечаем как Stun — probe всё равно скажет правду.
        return CallPath::Stun;
    }

    void CallController::registerDirectCandidate(const QString &candidate)
    {
        if (candidate.isEmpty()) return;
        if (direct_candidates_.contains(candidate)) return;
        DirectCandidateInfo info;
        info.category = classifyDirectCandidate(candidate);
        direct_candidates_.insert(candidate, info);
        const bool v6 = isIpv6Endpoint(candidate);
        qInfo().noquote() << "CallController: registered candidate" << candidate << "(family="
                          << (v6 ? "IPv6" : "IPv4") << ", category="
                          << (info.category == CallPath::Lan ? "LAN" : "STUN-public") << ")";
        startProbe(candidate);
        // Активируем reprobe-цикл сразу — даже если ни один путь пока не
        // подтвердился (первичный probe мог не пройти из-за временной потери
        // или race с peer'ом). Тиков нам не жалко, останов в resetProbingState.
        if (!reprobe_timer_.isActive() && state_ != QStringLiteral("idle")) {
            reprobe_timer_.start();
        }
        if (!rx_path_poll_timer_.isActive() && state_ != QStringLiteral("idle")) {
            rx_path_poll_timer_.start();
        }
    }

    void CallController::startProbe(const QString &address)
    {
        if (!engine_) return;
        // Probe имеет смысл только если engine prepared/running — на других
        // стадиях сессия Rust ещё/уже не существует, stunDiscover вернёт
        // пусто и сразу пометит candidate как unreachable, что неверно
        // (peer может быть на самом деле достижим, просто нашей сессии нет).
        const QString engineState = engine_->state();
        if (engineState != QStringLiteral("prepared") && engineState != QStringLiteral("running")) {
            return;
        }
        auto it = direct_candidates_.find(address);
        if (it == direct_candidates_.end()) return;
        if (it->inFlight) return;
        it->inFlight     = true;
        it->lastProbeMs  = QDateTime::currentMSecsSinceEpoch();
        QPointer<CallEngine> engine   = engine_;
        QPointer<CallController> self = this;
        const QString addr            = address;
        // STUN binding через сессионный сокет. Peer (если он жив и держит
        // session) отвечает Binding Success → reachable=true. Если ответа
        // нет за 2с — fail.
        (void)QtConcurrent::run([engine, self, addr]() {
            if (!engine || !self) return;
            // stunDiscover блокирующий; возвращает пустую строку при таймауте/ошибке.
            const QString reflexive = engine->stunDiscover(addr, /*timeoutMs=*/2000);
            const bool ok = !reflexive.isEmpty();
            QMetaObject::invokeMethod(self.data(), "onProbeResult", Qt::QueuedConnection,
                                      Q_ARG(QString, addr), Q_ARG(bool, ok));
        });
    }

    void CallController::onProbeResult(const QString &address, bool reachable)
    {
        auto it = direct_candidates_.find(address);
        if (it == direct_candidates_.end()) return;
        it->inFlight  = false;
        it->reachable = reachable;
        if (reachable) it->lastOkMs = QDateTime::currentMSecsSinceEpoch();
        const bool v6 = isIpv6Endpoint(address);
        qInfo().noquote() << "CallController: probe" << address
                          << "family=" << (v6 ? "IPv6" : "IPv4")
                          << "category=" << static_cast<int>(it->category)
                          << "->" << (reachable ? "reachable" : "fail");
        promoteBestPath();
    }

    void CallController::promoteBestPath()
    {
        if (!engine_) return;
        // Ищем минимальный CallPath среди:
        //   - direct candidates с reachable=true (Lan/Stun)
        //   - TURN allocations со своим localRelay И peerRelay (OurTurn/BackupTurn)
        CallPath bestPath = CallPath::None;
        QString bestAddr;
        QString bestTurnServer;

        bool anyDirectInFlight = false;
        for (auto it = direct_candidates_.constBegin(); it != direct_candidates_.constEnd(); ++it) {
            if (it.value().inFlight) anyDirectInFlight = true;
            if (!it.value().reachable) continue;
            if (bestPath == CallPath::None || it.value().category < bestPath) {
                bestPath       = it.value().category;
                bestAddr       = it.key();
                bestTurnServer = QString();
            }
        }
        for (auto it = turn_allocs_.constBegin(); it != turn_allocs_.constEnd(); ++it) {
            if (it.value().localRelay.isEmpty() || it.value().peerRelay.isEmpty()) continue;
            if (bestPath == CallPath::None || it.value().category < bestPath) {
                bestPath       = it.value().category;
                bestAddr       = it.value().peerRelay;
                bestTurnServer = it.key();
            }
        }

        if (bestPath == CallPath::None) return;
        if (current_path_ != CallPath::None && bestPath > current_path_) return; // не downgrade'им вверх
        if (bestPath == current_path_ && bestAddr == active_peer_addr_ &&
            bestTurnServer == active_turn_server_) {
            return; // ничего не изменилось
        }
        // КРИТИЧНО #1: не переключаемся на TURN, пока хоть один direct-probe ещё
        // в полёте. Allocate обычно завершается за ~500мс, а direct-пробы — 2с
        // (stunDiscover timeout). Без этой проверки мы перескакивали бы на TURN
        // раньше времени, не давая direct'у шанса.
        if ((bestPath == CallPath::OurTurn || bestPath == CallPath::BackupTurn) && anyDirectInFlight) {
            QPointer<CallController> self = this;
            QTimer::singleShot(2500, this, [self]() {
                if (self) self->promoteBestPath();
            });
            return;
        }
        // КРИТИЧНО #2: если Rust auto-discover УЖЕ показал РЕАЛЬНО рабочий
        // direct-канал (rx_path=Lan/Stun И mediaReceived=true), не переключаем
        // tx на TURN даже если наш STUN-probe провалился. Auto-discover видит
        // настоящий media-трафик — более надёжный сигнал чем единичный probe.
        //
        // Важно требовать ИМЕННО mediaReceived: rx_path может стать Direct
        // только потому что МЫ сами вызвали setPeer(direct_address) (например
        // на Huawei's reflexive из pending_peer_addr_) — это не значит что
        // media действительно приходит. Без mediaReceived guard'а мы
        // отказались бы переходить на TURN и звонок шёл без звука и видео.
        if (bestPath == CallPath::OurTurn || bestPath == CallPath::BackupTurn) {
            if ((rx_path_ == CallPath::Lan || rx_path_ == CallPath::Stun) &&
                engine_->mediaReceived()) {
                qInfo().noquote() << "CallController: best=TURN but actual direct media is flowing —"
                                  << "keep tx direct (trusting Rust auto-discover over failed probes)";
                if (current_path_ == CallPath::None) {
                    setCurrentPath(rx_path_, QString());
                }
                if (!reprobe_timer_.isActive()) reprobe_timer_.start();
                return;
            }
        }
        // Переключаем engine.
        if (bestPath == CallPath::OurTurn || bestPath == CallPath::BackupTurn) {
            if (engine_->setTurnPeer(bestTurnServer, bestAddr)) {
                turn_route_active_ = true;
                active_peer_addr_  = bestAddr;
                setCurrentPath(bestPath, bestTurnServer);
                engine_->requestKeyframe();
            }
        } else {
            if (engine_->setPeer(bestAddr)) {
                turn_route_active_ = false; // direct снова
                active_peer_addr_  = bestAddr;
                setCurrentPath(bestPath, QString());
            }
        }
        if (!reprobe_timer_.isActive()) reprobe_timer_.start();
    }

    void CallController::onReprobeTick()
    {
        // Если звонок закончился — останавливаем таймер.
        if (state_ == QStringLiteral("idle")) {
            reprobe_timer_.stop();
            return;
        }
        if (!engine_) return;
        const QString engineState = engine_->state();
        if (engineState != QStringLiteral("prepared") && engineState != QStringLiteral("running")) {
            return; // engine ещё не готов или уже не нужен
        }
        const qint64 now = QDateTime::currentMSecsSinceEpoch();
        // Пере-пробинг direct-кандидатов:
        //  - если есть текущий путь, пробуем категории строго выше (upgrade);
        //  - если current_path_=None (ничего ещё не подтвердилось), пробуем ВСЕ
        //    кандидаты, которые провалились или не завершились — это даёт
        //    шанс восстановить связность когда первый probe промахнулся.
        for (auto it = direct_candidates_.begin(); it != direct_candidates_.end(); ++it) {
            if (current_path_ != CallPath::None && it.value().category >= current_path_) continue;
            if (it.value().inFlight) continue;
            if (it.value().lastProbeMs > 0 && now - it.value().lastProbeMs < 5000) continue;
            startProbe(it.key());
        }
        // TURN-серверы: пробуем allocate если ещё не делали / провалился / нет
        // текущего успеха выше OurTurn. При current_path_=None пробуем все.
        const QStringList ordered = orderedTurnServers();
        for (int i = 0; i < ordered.size(); ++i) {
            const QString &srv = ordered[i];
            const CallPath cat = (i == 0) ? CallPath::OurTurn : CallPath::BackupTurn;
            if (current_path_ != CallPath::None && cat >= current_path_) continue;
            const auto allocIt = turn_allocs_.find(srv);
            if (allocIt != turn_allocs_.end()) {
                if (allocIt->allocateInFlight) continue;
                if (!allocIt->localRelay.isEmpty() && !allocIt->allocateFailed) continue;
            }
            launchTurnAllocateOn(srv, cat);
        }
    }

    void CallController::launchTurnAllocateOn(const QString &server, CallPath serverCategory)
    {
        if (server.isEmpty() || !engine_) return;
        TurnAllocInfo &info = turn_allocs_[server];
        info.category       = serverCategory;
        if (info.allocateInFlight) return;
        if (!info.localRelay.isEmpty() && !info.allocateFailed) return; // уже выделен
        info.allocateInFlight = true;
        info.allocateFailed   = false;
        qInfo().noquote() << "CallController: launching TURN allocate on" << server
                          << "(category=" << static_cast<int>(serverCategory) << ")";
        QPointer<CallEngine> engine   = engine_;
        QPointer<CallController> self = this;
        const QString srv             = server;
        (void)QtConcurrent::run([engine, self, srv]() {
            if (!engine || !self) return;
            const QString relay = engine->turnAllocate(srv, /*timeoutMs=*/3000);
            if (!self) return;
            // onTurnRelayReady сам нормализует relay-адрес (normalizeRelayAddress
            // из anonymous namespace) и эмитит ICE candidate peer'у.
            QMetaObject::invokeMethod(self.data(), "onTurnRelayReady", Qt::QueuedConnection,
                                      Q_ARG(QString, srv), Q_ARG(QString, relay));
        });
    }

} // namespace paranoia::voip
