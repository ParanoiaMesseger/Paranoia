#include "CallController.hpp"

#include <QDateTime>
#include <QDebug>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMetaObject>
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
            for (const auto &candidate : candidates) {
                if (!candidate.isEmpty() && !isIpv6Endpoint(candidate) && !isTurnCandidate(candidate)) return candidate;
            }
            return {};
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

    CallController::CallController(QObject *parent) : QObject(parent) {}

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
            emit controllerError(QStringLiteral("Видео не собрано в этой версии"));
            return false;
        }
        setWantVideo(on);
        if (state_ != QStringLiteral("running") || !engine_) return true;
        return engine_->videoActive() == on;
    }

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
        const int rc =
            handle_->callSignalSend(self_username_, toUserId, master_key_b64_, static_cast<unsigned char>(kind), json);
        if (rc != 0) {
            const QString message = QStringLiteral("call_signal_send failed: %1").arg(ParanoiaFFI::last_error());
            qWarning().noquote() << "CallController:" << message << "kind" << kind << "from" << logId(self_username_)
                                 << "to" << logId(toUserId);
            emit controllerError(message);
            return false;
        }
        qInfo().noquote() << "CallController: sent signal kind" << kind << "from" << logId(self_username_) << "to"
                          << logId(toUserId) << "call" << logId(payload.value(QStringLiteral("call_id")).toString());
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
        // Параллельно запускаем STUN-discover (если настроен): reflexive прилетит
        // отдельным Ice trickle.
        launchStunDiscoverIfConfigured();
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
                    handle_->callSignalSend(self_username_, fromPeer, master_key_b64_, 2 /*Hangup*/, json);
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
        if (!pending_peer_addr_.isEmpty()) { engine_->setPeer(pending_peer_addr_); }
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
        scheduleTurnFallbackCheck();
        // Параллельно STUN-discover — наш reflexive прилетит peer'у как Ice
        // trickle и улучшит шансы соединения через NAT.
        launchStunDiscoverIfConfigured();
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
        if (!peerCandidate.isEmpty()) { engine_->setPeer(peerCandidate); }
        if (hasTurnCandidate) { ensureTurnRouteForPeer(turnServer, normalizeRelayAddress(turnServer, turnRelay)); }
        if (!engine_->attachAudio()) {
            hangupCall(QStringLiteral("engine_attach_failed"));
            return;
        }
        // Если обе стороны согласны на видео — включаем камеру.
        if (want_video_ && peerWantsVideo && CallEngine::videoSupported()) { engine_->attachVideo(); }
        setState(QStringLiteral("running"));
        emit callConnected();
        scheduleTurnFallbackCheck();
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
        if (isIpv6Endpoint(candidate)) {
            qWarning().noquote() << "CallController: ignoring IPv6 ICE candidate for IPv4 media socket" << candidate;
            return;
        }
        if (turn_route_active_) {
            qInfo().noquote() << "CallController: ignoring direct ICE candidate after TURN route activation" << candidate;
            return;
        }
        qInfo().noquote() << "CallController: ICE candidate from" << logId(fromPeer) << "call" << logId(callId)
                          << candidate;
        engine_->setPeer(candidate);
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
            if (!self) return;
            if (reflexive.isEmpty()) return;
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

    void CallController::scheduleTurnFallbackCheck()
    {
        if (turn_server_.isEmpty() || turn_fallback_started_ || !engine_) return;
        QPointer<CallController> self = this;
        QTimer::singleShot(7000, this, [self]() {
            if (!self || !self->engine_) return;
            if (self->state_ != QStringLiteral("running")) return;
            if (self->engine_->mediaReceived()) return;
            self->launchTurnFallbackIfConfigured();
        });
    }

    void CallController::launchTurnFallbackIfConfigured()
    {
        if (turn_server_.isEmpty() || !engine_ || turn_fallback_started_) return;
        turn_fallback_started_ = true;
        const QString server = turn_server_;
        QPointer<CallEngine> engine = engine_;
        QPointer<CallController> self = this;
        auto future = QtConcurrent::run([engine, self, server]() {
            if (!engine || !self) return;
            QString relay = engine->turnAllocate(server, /*timeoutMs=*/3000);
            if (!self || relay.isEmpty()) return;
            relay = normalizeRelayAddress(server, relay);
            QMetaObject::invokeMethod(self.data(), "onTurnRelayReady", Qt::QueuedConnection, Q_ARG(QString, server),
                                      Q_ARG(QString, relay));
        });
        Q_UNUSED(future);
    }

    void CallController::ensureTurnRouteForPeer(const QString &server, const QString &peerRelay)
    {
        if (!engine_ || server.isEmpty() || peerRelay.isEmpty()) return;
        if (engine_->state() == QStringLiteral("idle")) {
            pending_turn_peer_server_ = server;
            pending_turn_peer_relay_  = peerRelay;
            return;
        }
        if (!local_turn_relay_.isEmpty()) {
            if (engine_->setTurnPeer(server, peerRelay)) {
                turn_route_active_ = true;
                engine_->requestKeyframe();
            }
            return;
        }
        pending_turn_peer_server_ = server;
        pending_turn_peer_relay_  = peerRelay;
        if (turn_fallback_started_) return;
        turn_server_ = server;
        launchTurnFallbackIfConfigured();
    }

    void CallController::onTurnRelayReady(const QString &server, const QString &relay)
    {
        if (relay.isEmpty()) return;
        if (state_ != QStringLiteral("outgoing") && state_ != QStringLiteral("incoming") &&
            state_ != QStringLiteral("running")) {
            return;
        }
        local_turn_relay_ = normalizeRelayAddress(server, relay);
        QJsonObject ice;
        ice.insert(QStringLiteral("call_id"), call_id_);
        ice.insert(QStringLiteral("candidate"), formatTurnCandidate(server, local_turn_relay_));
        sendSignal(/*kind=Ice*/ 3, ice);

        if (!pending_turn_peer_server_.isEmpty() && !pending_turn_peer_relay_.isEmpty()) {
            const QString peerServer = pending_turn_peer_server_;
            const QString peerRelay  = pending_turn_peer_relay_;
            pending_turn_peer_server_.clear();
            pending_turn_peer_relay_.clear();
            if (engine_ && engine_->setTurnPeer(peerServer, peerRelay)) {
                turn_route_active_ = true;
                engine_->requestKeyframe();
            }
        }
    }

} // namespace paranoia::voip
