#include "VoipSystem.hpp"

#include "backend/MainBackend.hpp"
#include "platform/PlatformNotifications.hpp"
#include "session/Dialog.hpp"
#include "session/ServerSession.hpp"
#include "session/SessionStore.hpp"

#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QDebug>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QUrl>
#include <QVariantMap>

namespace paranoia::voip
{
    namespace
    {
        constexpr int kParanoiaStunPort = 3478;
    }

    VoipSystem::VoipSystem(QQmlApplicationEngine &engine, MainBackend &backend, QObject *parent)
        : QObject(parent), backend_(backend)
    {
        callController_.setEngine(&callEngine_);
        callController_.setSignaling(&callSignaling_);

        connect(&callEngine_, &CallEngine::errorOccurred, this,
                [](const QString &message) { qWarning().noquote() << "CallEngine:" << message; });
        connect(&callController_, &CallController::controllerError, this,
                [](const QString &message) { qWarning().noquote() << "CallControl:" << message; });
        connect(&callSignaling_, &CallSignalingClient::pollFailed, this,
                [](const QString &message) { qWarning().noquote() << "CallSignaling:" << message; });

        // STUN-server for reflexive candidates. Priority:
        // 1. env `PARANOIA_STUN_SERVER` (`disable|off|none` disables STUN);
        // 2. build define `PARANOIA_DEFAULT_STUN_SERVER`;
        // 3. active session host + default port 3478;
        // 4. public fallback `stun.l.google.com:19302`.
        stunExplicit_ = QString::fromUtf8(qgetenv("PARANOIA_STUN_SERVER"));
        if (stunExplicit_.isEmpty()) { stunExplicit_ = QString::fromUtf8(PARANOIA_DEFAULT_STUN_SERVER); }
        const QString lower = stunExplicit_.trimmed().toLower();
        if (lower == QStringLiteral("disable") || lower == QStringLiteral("off") ||
            lower == QStringLiteral("none")) {
            stunDisabled_ = true;
            stunExplicit_.clear();
        }

        // TURN relay fallback. Priority:
        // 1. env `PARANOIA_TURN_SERVER` (`disable|off|none` disables TURN);
        // 2. active session host + default port 3478.
        turnExplicit_ = QString::fromUtf8(qgetenv("PARANOIA_TURN_SERVER"));
        const QString turnLower = turnExplicit_.trimmed().toLower();
        if (turnLower == QStringLiteral("disable") || turnLower == QStringLiteral("off") ||
            turnLower == QStringLiteral("none")) {
            turnDisabled_ = true;
            turnExplicit_.clear();
        }

        const QString initial = deriveStunForServer(QString());
        callController_.setStunServer(initial);
        callController_.setTurnServer(deriveTurnForServer(QString()));
        if (initial.isEmpty()) {
            qInfo().noquote() << "VoIP: STUN disabled - calls work only in local network";
        } else {
            qInfo().noquote() << "VoIP: initial STUN server" << initial;
        }

        engine.rootContext()->setContextProperty("Call", &callEngine_);
        engine.rootContext()->setContextProperty("CallSignaling", &callSignaling_);
        engine.rootContext()->setContextProperty("CallControl", &callController_);

        connect(&backend_, &MainBackend::sessionsChanged, this, &VoipSystem::refreshBindings);
        connect(&backend_, &MainBackend::sessionSwitched, this, &VoipSystem::refreshBindings);
        connect(&backend_, &MainBackend::dialogsChanged, this, &VoipSystem::refreshBindings);
        // На возврат приложения в foreground (тап по баннеру звонка из фона) —
        // забираем отложенный оффер и поднимаем экран вызова (#6 handoff). И
        // координация опроса звонков: in-app сигналинг опрашивает офферы ТОЛЬКО
        // когда приложение активно ИЛИ идёт звонок — иначе отдаёт канал фон-сервису
        // (иначе оба поллера дерутся за drain-эндпоинт и в фоне клиент «съедал»
        // оффер, показывая невидимый экран вместо баннера).
        appActive_ = QGuiApplication::applicationState() == Qt::ApplicationActive;
        connect(qApp, &QGuiApplication::applicationStateChanged, this, [this](Qt::ApplicationState s) {
            appActive_ = (s == Qt::ApplicationActive);
            if (appActive_) maybeInjectPendingCallOffer();
            updateOfferPolling();
        });
        connect(&callController_, &CallController::callStateChanged, this, [this]() {
            const bool active = callController_.callState() != QStringLiteral("idle");
            if (active != callActive_) {
                callActive_ = active;
                updateOfferPolling();
            }
        });
        // Heartbeat: пока in-app владеет опросом звонков — продлеваем флаг (фон-сервис
        // его видит и не лезет в call_poll). TTL на Java-стороне 90с, шлём ~раз в 30с.
        uiCallHeartbeat_.setInterval(30'000);
        connect(&uiCallHeartbeat_, &QTimer::timeout, this, []() { PlatformNotifications::heartbeatUiCallPolling(); });
        refreshBindings();
        updateOfferPolling();
    }

    void VoipSystem::updateOfferPolling()
    {
        const bool enabled = appActive_ || callActive_;
        qInfo().noquote() << "VoIP: offer-polling" << (enabled ? "ON" : "OFF") << "(appActive" << appActive_
                          << "callActive" << callActive_ << ")";
        callSignaling_.setOfferPollingEnabled(enabled);
        if (enabled) {
            // Сразу застолбить канал за UI, потом продлевать таймером.
            PlatformNotifications::heartbeatUiCallPolling();
            if (!uiCallHeartbeat_.isActive()) uiCallHeartbeat_.start();
        } else {
            uiCallHeartbeat_.stop();
            // Отдать опрос звонков фон-сервису немедленно (не ждать TTL).
            PlatformNotifications::clearUiCallPolling();
        }
    }

    void VoipSystem::maybeInjectPendingCallOffer()
    {
        // Забираем из prefs ОДИН раз и держим в памяти, пока не сможем нормально
        // инжектить (takePendingCallOffer стирает из prefs — повторно не достать).
        if (pendingCallOffer_.isEmpty()) {
            pendingCallOffer_ = PlatformNotifications::takePendingCallOffer();
            // Флаг авто-приёма читаем вместе с оффером (intent-канал одноразовый).
            if (!pendingCallOffer_.isEmpty()) {
                pendingCallAnswer_ = PlatformNotifications::takePendingCallAnswerIntent();
            }
        }
        if (pendingCallOffer_.isEmpty()) return;

        // Извлекаем отправителя из конверта. Если в keyring'е ещё нет его master
        // key (dialogs не догрузились на cold start) — НЕ инжектим: оставляем
        // оффер и повторим на следующем refreshBindings (он привязан к
        // dialogsChanged). Иначе экран звонка показал бы hex вместо имени, а
        // accept упал бы на "master key unknown".
        QString sender;
        QString offerCallId;
        {
            QJsonParseError perr{};
            const auto doc = QJsonDocument::fromJson(pendingCallOffer_.toUtf8(), &perr);
            QJsonObject env;
            if (perr.error == QJsonParseError::NoError) {
                if (doc.isObject()) {
                    env = doc.object();
                } else if (doc.isArray() && !doc.array().isEmpty() && doc.array().first().isObject()) {
                    env = doc.array().first().toObject();
                }
            }
            sender = env.value(QStringLiteral("sender")).toString();
            // call_id лежит внутри payload_json (строка с JSON).
            const QString payloadStr = env.value(QStringLiteral("payload_json")).toString();
            if (!payloadStr.isEmpty()) {
                QJsonParseError pperr{};
                const auto pdoc = QJsonDocument::fromJson(payloadStr.toUtf8(), &pperr);
                if (pperr.error == QJsonParseError::NoError && pdoc.isObject())
                    offerCallId = pdoc.object().value(QStringLiteral("call_id")).toString();
            }
        }
        // Гонка отмены: hangup по этому call_id мог прийти РАНЬШЕ, чем мы инжектим
        // сохранённый оффер (фон-сервис сложил оффер в prefs, затем удалённый сброс).
        // Не показываем экран дозвона по уже отменённому звонку.
        if (!offerCallId.isEmpty() && callSignaling_.wasRecentlyHungUp(offerCallId)) {
            qInfo().noquote() << "VoIP: dropping pending call offer — call was already hung up";
            pendingCallOffer_.clear();
            pendingCallAnswer_ = false;
            return;
        }
        if (!sender.isEmpty() && callSignaling_.masterKeyFor(sender).isEmpty()) {
            qInfo().noquote() << "VoIP: holding pending call offer until keyring loads sender key";
            return;
        }
        qInfo().noquote() << "VoIP: injecting handed-off incoming-call offer";
        // Если звонок «принят» из баннера — навешиваем ОДНОРАЗОВЫЙ авто-приём на
        // ближайший incomingCall (onOffer асинхронен: сигнал придёт после inject).
        // One-shot, чтобы не принять автоматически следующий, не связанный звонок.
        if (pendingCallAnswer_) {
            pendingCallAnswer_ = false;
            auto *conn = new QMetaObject::Connection;
            *conn = connect(&callController_, &CallController::incomingCall, this,
                            [this, conn](const QString &, const QString &, bool) {
                                disconnect(*conn);
                                delete conn;
                                qInfo().noquote()
                                    << "VoIP: auto-accepting call answered from notification banner";
                                callController_.acceptIncomingCall();
                            });
        }
        callSignaling_.injectEnvelope(pendingCallOffer_);
        pendingCallOffer_.clear();
    }

    QString VoipSystem::deriveStunForServer(const QString &serverUrl) const
    {
        if (stunDisabled_) return {};
        if (!stunExplicit_.isEmpty()) return stunExplicit_;
        if (!serverUrl.isEmpty()) {
            QUrl url(serverUrl);
            QString host = url.host();
            if (host.isEmpty()) {
                QString server = serverUrl;
                if (server.startsWith(QStringLiteral("//"))) server.remove(0, 2);
                const int slash = server.indexOf(QLatin1Char('/'));
                if (slash >= 0) server = server.left(slash);
                const int colon = server.indexOf(QLatin1Char(':'));
                if (colon >= 0) server = server.left(colon);
                host = server.trimmed();
            }
            if (!host.isEmpty()) { return QStringLiteral("%1:%2").arg(host).arg(kParanoiaStunPort); }
        }
        return QStringLiteral("stun.l.google.com:19302");
    }

    QString VoipSystem::deriveTurnForServer(const QString &serverUrl) const
    {
        if (turnDisabled_) return {};
        if (!turnExplicit_.isEmpty()) return turnExplicit_;
        if (!serverUrl.isEmpty()) {
            QUrl url(serverUrl);
            QString host = url.host();
            if (host.isEmpty()) {
                QString server = serverUrl;
                if (server.startsWith(QStringLiteral("//"))) server.remove(0, 2);
                const int slash = server.indexOf(QLatin1Char('/'));
                if (slash >= 0) server = server.left(slash);
                const int colon = server.indexOf(QLatin1Char(':'));
                if (colon >= 0) server = server.left(colon);
                host = server.trimmed();
            }
            if (!host.isEmpty()) { return QStringLiteral("%1:%2").arg(host).arg(kParanoiaStunPort); }
        }
        return {};
    }

    void VoipSystem::refreshBindings()
    {
        auto active = SessionStore::instance()->activeSession();
        if (!active || !active->ffi) {
            callSignaling_.stop();
            callController_.setHandle(nullptr);
            callController_.setPeerUserIds({});
            callSignaling_.setPeerKeyring({});
            callController_.setStunServer(deriveStunForServer(QString()));
            callController_.setTurnServer(deriveTurnForServer(QString()));
            callController_.setBackupTurnServers({});
            return;
        }

        const QString selfUserId = active->serverId.isEmpty() ? active->username : active->serverId;
        callController_.setHandle(active->ffi);
        callController_.setSelfUsername(selfUserId);

        const QString stunForActive = deriveStunForServer(active->server);
        callController_.setStunServer(stunForActive);
        if (!stunForActive.isEmpty()) { qInfo().noquote() << "VoIP: STUN server for active session" << stunForActive; }
        const QString turnForActive = deriveTurnForServer(active->server);
        callController_.setTurnServer(turnForActive);
        if (!turnForActive.isEmpty()) { qInfo().noquote() << "VoIP: TURN server for active session" << turnForActive; }
        // Резервные TURN-сервера из профиля. Порядок сохраняем как у пользователя.
        callController_.setBackupTurnServers(active->turnServerUrls);
        if (!active->turnServerUrls.isEmpty()) {
            qInfo().noquote() << "VoIP: backup TURN servers for active session"
                              << active->turnServerUrls.join(QStringLiteral(", "));
        }

        callSignaling_.setHandle(active->ffi);
        callSignaling_.setUser(selfUserId);

        QVariantMap keyring;
        QVariantMap peerUserIds;
        for (const auto &dialog : active->dialogs) {
            if (dialog.keyring.isEmpty()) continue;
            const auto &entry        = dialog.keyring.last();
            const QString keyB64     = QString::fromUtf8(entry.key.toBase64());
            const QString peerUserId = dialog.peerServerId.isEmpty() ? dialog.peer : dialog.peerServerId;
            keyring.insert(dialog.peer, keyB64);
            if (!peerUserId.isEmpty()) {
                keyring.insert(peerUserId, keyB64);
                peerUserIds.insert(dialog.peer, peerUserId);
            }
        }
        callController_.setPeerUserIds(peerUserIds);
        callSignaling_.setPeerKeyring(keyring);
        callSignaling_.start();
        // Сессия готова (cold start из баннера звонка) — поднять отложенный оффер.
        maybeInjectPendingCallOffer();
    }

} // namespace paranoia::voip
