#include "NotificationCoordinator.hpp"

#include "platform/PlatformNotifications.hpp"
#include "session/Dialog.hpp"
#include "session/ServerSession.hpp"
#include "session/SessionStore.hpp"
#include <ParanoiaFFI>

#include <QCoreApplication>
#include <QDateTime>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QSet>
#include <QDebug>
#include <QGuiApplication>
#include <QMutexLocker>
#include <QNetworkInformation>
#include <QPointer>
#include <QRandomGenerator>
#include <QThreadPool>
#include <algorithm>

#if defined(Q_OS_ANDROID)
#include <QJniEnvironment>
#include <android/log.h>
#endif

NotificationCoordinator::NotificationCoordinator(QObject *parent) : QObject(parent)
{
    m_applicationActive.store(QGuiApplication::applicationState() == Qt::ApplicationActive, std::memory_order_relaxed);
    PlatformNotifications::setApplicationForeground(applicationIsActive());
    // applicationStateChanged не выстреливает «впервые» — если стартовали уже
    // в Active, обязательно скидываем накопленные за прошлые сессии карточки.
    if (applicationIsActive()) PlatformNotifications::clearAccumulatedNotifications();
    m_pollTimer.setSingleShot(true);
    connect(&m_pollTimer, &QTimer::timeout, this, &NotificationCoordinator::onPollTimer);
    // Heartbeat короче серверного TTL (Java: 150с) — продлеваем foreground пока живы.
    m_foregroundHeartbeat.setInterval(60'000);
    connect(&m_foregroundHeartbeat, &QTimer::timeout, this, []() {
        PlatformNotifications::setApplicationForeground(true);
    });
    if (applicationIsActive()) m_foregroundHeartbeat.start();
    connect(qApp, &QGuiApplication::applicationStateChanged, this, &NotificationCoordinator::onApplicationStateChanged);
    if (QNetworkInformation::loadDefaultBackend()) {
        if (auto *networkInfo = QNetworkInformation::instance()) {
            connect(networkInfo, &QNetworkInformation::reachabilityChanged, this,
                    &NotificationCoordinator::onNetworkChanged);
            connect(networkInfo, &QNetworkInformation::transportMediumChanged, this,
                    &NotificationCoordinator::onNetworkChanged);
        }
    }

    QPointer self(this);
    PlatformNotifications::setBackgroundPollCallback([self]() {
        QThreadPool::globalInstance()->start([self]() {
            if (!self) return;
            self->runBackgroundPollFromService();
        });
        if (!self) return;
        QMetaObject::invokeMethod(self, [self]() {
            if (!self) return;
            self->onNetworkChanged();
        });
    });
}

NotificationCoordinator::~NotificationCoordinator()
{
    m_pollTimer.stop();
    m_foregroundHeartbeat.stop();
    PlatformNotifications::setBackgroundPollCallback({});
#if defined(Q_OS_ANDROID)
    PlatformNotifications::setApplicationForeground(false);
#else
    PlatformNotifications::stopBackgroundPollingService();
#endif
}

QString NotificationCoordinator::notificationHintPeer() const { return m_notificationHintPeer; }

QString NotificationCoordinator::notificationHintProfileId() const { return m_notificationHintProfileId; }

quint64 NotificationCoordinator::unreadCount(const QString &profileId, const QString &peer) const
{
    return m_notifiedPendingByPeer.value(profileId + QLatin1Char(':') + peer, 0);
}

qint64 NotificationCoordinator::lastActivityMs(const QString &profileId, const QString &peer) const
{
    return m_lastActivityByPeer.value(profileId + QLatin1Char(':') + peer, 0);
}

quint64 NotificationCoordinator::totalUnreadForProfile(const QString &profileId) const
{
    quint64 total        = 0;
    const QString prefix = profileId + QLatin1Char(':');
    for (auto it = m_notifiedPendingByPeer.constBegin(); it != m_notifiedPendingByPeer.constEnd(); ++it)
        if (it.key().startsWith(prefix)) total += it.value();
    return total;
}

bool NotificationCoordinator::isNotificationHintFor(const QString &profileId, const QString &peer) const
{
    return profileId == m_notificationHintProfileId && peer == m_notificationHintPeer;
}

QString NotificationCoordinator::takeNotificationPeer()
{
    const auto target = PlatformNotifications::takeOpenTargetFromNotification();
    if (!target.peer.isEmpty()) {
        auto *store       = SessionStore::instance();
        QString profileId = target.profileId;
        if (!profileId.isEmpty()) {
            auto session = store->sessionForProfile(profileId);
            if (session && session != store->activeSession()) {
                store->setActiveSession(session);
                m_activePeer.clear();
                emit sessionReset();
                emit dialogsChanged();
                emit sessionSwitched();
                schedulePoll(0);
            }
        }
        if (profileId.isEmpty()) {
            const auto session = store->activeSession();
            if (session) profileId = session->profileId;
        }
        setNotificationHint(profileId, target.peer);
        emit dialogsChanged();
    }
    return m_notificationHintPeer;
}

bool NotificationCoordinator::clearPeer(const QString &profileId, const QString &peer)
{
    if (profileId.isEmpty() || peer.isEmpty()) return false;
    const QString key = profileId + QLatin1Char(':') + peer;
    bool changed      = m_notifiedPendingByPeer.remove(key) > 0;
    m_locallyReceivedPendingByPeer.remove(key);
    if (m_notificationHintProfileId == profileId && m_notificationHintPeer == peer)
        changed = setNotificationHint({}, {}) || changed;
    return changed;
}

void NotificationCoordinator::clearProfile(const QString &profileId)
{
    if (profileId.isEmpty()) return;
    const QString prefix = profileId + QLatin1Char(':');
    const auto dropPrefixed = [&prefix](QMap<QString, quint64> &m) {
        for (auto it = m.begin(); it != m.end();)
            it = it.key().startsWith(prefix) ? m.erase(it) : std::next(it);
    };
    dropPrefixed(m_notifiedPendingByPeer);
    dropPrefixed(m_locallyReceivedPendingByPeer);
    for (auto it = m_lastActivityByPeer.begin(); it != m_lastActivityByPeer.end();)
        it = it.key().startsWith(prefix) ? m_lastActivityByPeer.erase(it) : std::next(it);
    if (m_notificationHintProfileId == profileId) setNotificationHint({}, {});
    emit dialogsChanged();
}

void NotificationCoordinator::resetActiveContext()
{
    m_activePeer.clear();
    setNotificationHint({}, {});
}

void NotificationCoordinator::onActivePeerChanged(const QString &peer)
{
    m_activePeer = peer;
    if (!peer.isEmpty()) {
        const auto session      = SessionStore::instance()->activeSession();
        const QString profileId = session ? session->profileId : QString();
        if (clearPeer(profileId, peer)) emit dialogsChanged();
    }
}

void NotificationCoordinator::onPeerMessagesRead(const QString &peer)
{
    const auto session      = SessionStore::instance()->activeSession();
    const QString profileId = session ? session->profileId : QString();
    if (clearPeer(profileId, peer)) emit dialogsChanged();
}

void NotificationCoordinator::onBackgroundMessagesReceived(const QString &profileId, const QString &peer, quint64 count)
{
    if (applicationIsActive()) return;
    if (profileId.isEmpty() || peer.isEmpty() || count == 0) return;

    const QString key                   = profileId + QLatin1Char(':') + peer;
    m_locallyReceivedPendingByPeer[key] = m_locallyReceivedPendingByPeer.value(key, 0) + count;
    m_notifiedPendingByPeer[key]        = m_notifiedPendingByPeer.value(key, 0) + count;
    m_lastActivityByPeer[key]           = QDateTime::currentMSecsSinceEpoch();
    quint64 total                       = 0;
    for (auto it = m_notifiedPendingByPeer.constBegin(); it != m_notifiedPendingByPeer.constEnd(); ++it)
        total += it.value();
    setNotificationHint(profileId, peer);
    emit dialogsChanged();
    presentNotification(PollMode::Background, total, profileId, peer);
}

void NotificationCoordinator::onPollTimer()
{
    if (applicationIsActive())
        pollForegroundNotifications();
    else {
#if defined(Q_OS_ANDROID)
        schedulePoll();
#else
        pollBackgroundNotifications();
#endif
    }
}

void NotificationCoordinator::onNetworkChanged()
{
    m_notifyRetryCount = 0;
    schedulePoll(0);
    emit networkRestored();
}

void NotificationCoordinator::onApplicationStateChanged(Qt::ApplicationState state)
{
    m_applicationActive.store(state == Qt::ApplicationActive, std::memory_order_relaxed);
    PlatformNotifications::setApplicationForeground(applicationIsActive());
    if (applicationIsActive()) m_foregroundHeartbeat.start();
    else m_foregroundHeartbeat.stop();
    m_notifyRetryCount = 0;
    if (state == Qt::ApplicationActive) {
        // При любом выходе на передний план — даже если приложение открыто иконкой,
        // а не тапом по уведомлению, — карточки в шторке теряют смысл и должны
        // исчезнуть. Так же сбрасываем «локально‑полученные» счётчики, иначе
        // следующий фоновый poll вернёт ту же сумму и баннер всплывёт снова.
        PlatformNotifications::clearAccumulatedNotifications();
        emit notificationsCleared();
        const bool hadPending = !m_notifiedPendingByPeer.isEmpty() || !m_locallyReceivedPendingByPeer.isEmpty();
        m_notifiedPendingByPeer.clear();
        m_locallyReceivedPendingByPeer.clear();
        if (setNotificationHint({}, {}) || hadPending) emit dialogsChanged();
    } else {
        quint64 total = 0;
        for (auto it = m_notifiedPendingByPeer.constBegin(); it != m_notifiedPendingByPeer.constEnd(); ++it)
            total += it.value();
        if (total > 0)
            presentNotification(PollMode::Background, total, m_notificationHintProfileId, m_notificationHintPeer);
    }
    schedulePoll(0);
}

bool NotificationCoordinator::applicationIsActive() const
{
    return m_applicationActive.load(std::memory_order_relaxed);
}

bool NotificationCoordinator::setNotificationHint(const QString &profileId, const QString &peer)
{
    if (m_notificationHintProfileId == profileId && m_notificationHintPeer == peer) return false;
    m_notificationHintProfileId = profileId;
    m_notificationHintPeer      = peer;
    emit notificationHintPeerChanged();
    return true;
}

void NotificationCoordinator::pollForegroundNotifications() { pollNotifications(PollMode::Foreground); }

void NotificationCoordinator::pollBackgroundNotifications() { pollNotifications(PollMode::Background); }

void NotificationCoordinator::pollNotifications(PollMode mode)
{
    if (m_notifyPollInFlight) {
        schedulePoll();
        return;
    }

    const QList<PollTarget> targets = buildPollTargets(mode);
    if (targets.isEmpty()) {
        const bool hadPending = !m_notifiedPendingByPeer.isEmpty();
        m_notifiedPendingByPeer.clear();
        m_locallyReceivedPendingByPeer.clear();
        setNotificationHint({}, {});
        if (hadPending) emit dialogsChanged();
        schedulePoll();
        return;
    }

    QPointer self(this);
    m_notifyPollInFlight = true;
    QThreadPool::globalInstance()->start([self, targets, mode]() {
        if (!self) return;
        QString error;
        bool anyFailed                = false;
        const QList<NotifyCount> counts = pollCountsGrouped(targets, anyFailed, error);
        if (!self) return;
        QMetaObject::invokeMethod(self, [self, counts, anyFailed, error, mode]() {
            if (!self) return;
            self->m_notifyPollInFlight = false;
            self->applyNotifyCounts(mode, counts, anyFailed, error);
        });
    });
}

QList<NotificationCoordinator::NotifyCount>
NotificationCoordinator::pollCountsGrouped(const QList<PollTarget> &targets, bool &anyFailed, QString &error)
{
    QList<NotifyCount> counts;
    anyFailed = false;

    // Группируем по сессии: один identity-ключ сессии = один multi-notify-запрос.
    QList<std::shared_ptr<ServerSession>> order;
    QMap<ServerSession *, QList<PollTarget>> bySession;
    for (const auto &t : targets) {
        if (!t.session) continue;
        if (!bySession.contains(t.session.get())) order.append(t.session);
        bySession[t.session.get()].append(t);
    }

    for (const auto &session : order) {
        const QList<PollTarget> &group = bySession[session.get()];
        // peerServerId -> исходный target (для маппинга ответа обратно в key/peer).
        QMap<QString, PollTarget> byServerId;
        QJsonArray items;
        for (const auto &t : group) {
            QJsonObject o;
            o["peer"] = t.peerServerId;
            // keyringJson — JSON-массив строкой; вкладываем как массив, чтобы Rust
            // распарсил его как keyring сразу (без двойного экранирования).
            const QJsonDocument kr = QJsonDocument::fromJson(t.keyringJson.toUtf8());
            o["keyring"]           = kr.isArray() ? QJsonValue(kr.array()) : QJsonValue(QJsonArray());
            items.append(o);
            byServerId.insert(t.peerServerId, t);
        }

        // Копируем handle+serverId под МГНОВЕННЫМ локом, сам сетевой запрос — БЕЗ
        // ffiMutex (как ActiveChatNotifier): иначе при потере сети connect_timeout
        // висел бы под общим локом и морозил весь UI (см. фикс «намертво»).
        std::shared_ptr<ParanoiaFFI> ffi;
        QString serverId;
        {
            QMutexLocker locker(&session->ffiMutex);
            ffi      = session->ffi;
            serverId = session->serverId;
        }
        if (!ffi) continue;

        const QString itemsJson = QString::fromUtf8(QJsonDocument(items).toJson(QJsonDocument::Compact));
        int rc                  = 0;
        const QString resJson   = ffi->notify_unread_multi_keyring(serverId, itemsJson, 0, rc);
        if (rc != 0) {
            anyFailed = true;
            if (error.isEmpty()) error = ParanoiaFFI::last_error();
            continue;
        }

        const QJsonDocument doc = QJsonDocument::fromJson(resJson.toUtf8());
        for (const auto &v : doc.array()) {
            const QJsonObject o = v.toObject();
            const QString sid   = o["peer"].toString();
            const quint64 n     = static_cast<quint64>(o["n"].toDouble());
            auto it             = byServerId.find(sid);
            if (it == byServerId.end() || n == 0) continue;
            const PollTarget &t = it.value();
            counts.append({t.profileId + QLatin1Char(':') + t.peer, t.profileId, t.peer, n});
        }
    }
    return counts;
}

QList<NotificationCoordinator::PollTarget> NotificationCoordinator::buildPollTargets(PollMode mode) const
{
    QList<PollTarget> targets;
    const auto activeSession     = SessionStore::instance()->activeSession();
    const QString activePeer     = m_activePeer;
    const bool excludeActivePeer = mode == PollMode::Foreground;

    for (const auto &session : SessionStore::instance()->allSessions()) {
        if (!session || !session->isLoggedIn()) continue;
        const QString profileId = session->profileId;
        for (const auto &dialog : session->dialogs) {
            if (excludeActivePeer && session == activeSession && !activePeer.isEmpty() && dialog.peer == activePeer)
                continue;
            const QString keyringJson = dialog.keyringJson();
            if (!session->serverId.isEmpty() && !dialog.peer.isEmpty() && !dialog.peerServerId.isEmpty() &&
                !keyringJson.isEmpty())
                targets.append({session, profileId, dialog.peer, dialog.peerServerId, keyringJson});
        }
    }
    return targets;
}

void NotificationCoordinator::applyNotifyCounts(PollMode mode, const QList<NotifyCount> &counts, bool anyFailed,
                                                const QString &error)
{
    bool hasNewPending  = false;
    bool pendingChanged = false;
    QString newPendingProfileId;
    QString newPendingPeer;
    int newPendingPeers = 0;
    QString hintProfileId;
    QString hintPeer;
    int pendingPeers = 0;

    for (const auto &item : counts) {
        const QString &key          = item.key;
        const quint64 serverCount   = item.count;
        const quint64 localCount    = m_locallyReceivedPendingByPeer.value(key, 0);
        const quint64 combinedCount = localCount + serverCount;
        if (combinedCount == 0) {
            pendingChanged = m_notifiedPendingByPeer.remove(key) > 0 || pendingChanged;
            continue;
        }

        ++pendingPeers;
        if (pendingPeers == 1) {
            hintProfileId = item.profileId;
            hintPeer      = item.peer;
        } else {
            hintProfileId.clear();
            hintPeer.clear();
        }

        const quint64 previousCombined = m_notifiedPendingByPeer.value(key, 0);
        const quint64 previousLocal    = m_locallyReceivedPendingByPeer.value(key, 0);
        const quint64 previousServer   = previousCombined > previousLocal ? previousCombined - previousLocal : 0;
        if (combinedCount != previousCombined) pendingChanged = true;
        if (serverCount > previousServer) {
            // Новое серверное сообщение для этого пира — бампаем свежесть, чтобы
            // диалог поднялся в списке (in-memory, как и счётчики непрочитанного).
            m_lastActivityByPeer[key] = QDateTime::currentMSecsSinceEpoch();
            hasNewPending = true;
            ++newPendingPeers;
            if (newPendingPeers == 1) {
                newPendingProfileId = item.profileId;
                newPendingPeer      = item.peer;
            } else {
                newPendingProfileId.clear();
                newPendingPeer.clear();
            }
        }
        m_notifiedPendingByPeer[key] = combinedCount;
    }

    quint64 total = 0;
    for (auto it = m_notifiedPendingByPeer.constBegin(); it != m_notifiedPendingByPeer.constEnd(); ++it)
        total += it.value();
    if (hintPeer.isEmpty() && newPendingPeers == 1) {
        hintProfileId = newPendingProfileId;
        hintPeer      = newPendingPeer;
    }
    if (total == 0) {
        setNotificationHint({}, {});
    } else if (pendingChanged) {
        setNotificationHint(hintProfileId, hintPeer);
    }
    if (pendingChanged) emit dialogsChanged();
    if (hasNewPending) presentNotification(mode, total, hintProfileId, hintPeer);
    // Индикатор связи — только по форграунд-поллингу (фон не должен дёргать UI).
    if (mode == PollMode::Foreground) emit connectivityChanged(!anyFailed);
    if (anyFailed) {
        qWarning().noquote() << "Notify polling failed for some sessions:" << error;
        ++m_notifyRetryCount;
        schedulePoll(retryNotifyDelayMs());
    } else {
        m_notifyRetryCount = 0;
        schedulePoll();
    }
}

void NotificationCoordinator::presentNotification(PollMode mode, quint64 total, const QString &profileId,
                                                  const QString &peer)
{
    if (mode != PollMode::Background) return;
    // На Android уведомления тоже постим из main-процесса: пока процесс жив,
    // ChatBackend сам тянет сообщения и продвигает локальный seq, поэтому
    // сервисный paranoia_notify_count для уже-затянутых сообщений вернёт 0 —
    // если не отправить нотификацию здесь, пользователь её не увидит.
    // showMessageCount идёт в ParanoiaForegroundService.showNewMessages,
    // которая сама фильтрует foreground state.
    PlatformNotifications::showMessageCount(total, profileId, peer);
    emit notificationAvailable(total, profileId, peer);
}

void NotificationCoordinator::schedulePoll(int delayMs)
{
    rebuildBackgroundPollSnapshot();
    const auto &sessions = SessionStore::instance()->allSessions();
    bool anyActive       = false;
    for (const auto &s : sessions)
        if (s && s->isLoggedIn() && !s->dialogs.isEmpty()) {
            anyActive = true;
            break;
        }
    if (!anyActive) {
        m_pollTimer.stop();
        PlatformNotifications::stopBackgroundPollingService();
        return;
    }

#if defined(Q_OS_ANDROID)
    PlatformNotifications::startBackgroundPollingService();
#else
    if (applicationIsActive())
        PlatformNotifications::stopBackgroundPollingService();
    else
        PlatformNotifications::startBackgroundPollingService();
#endif

    if (delayMs < 0) delayMs = randomNotifyDelayMs();
    m_pollTimer.start(delayMs);
}

void NotificationCoordinator::rebuildBackgroundPollSnapshot()
{
    std::vector<PollTarget> next;
    for (const auto &session : SessionStore::instance()->allSessions()) {
        if (!session || !session->isLoggedIn()) continue;
        for (const auto &dialog : session->dialogs) {
            const QString keyringJson = dialog.keyringJson();
            if (session->serverId.isEmpty() || dialog.peer.isEmpty() || dialog.peerServerId.isEmpty() ||
                keyringJson.isEmpty())
                continue;
            next.push_back({session, session->profileId, dialog.peer, dialog.peerServerId, keyringJson});
        }
    }
    QMutexLocker lock(&m_bgPollSnapshotMutex);
    m_bgPollSnapshot.swap(next);
}

void NotificationCoordinator::runBackgroundPollFromService()
{
    if (applicationIsActive()) {
#if defined(Q_OS_ANDROID)
        __android_log_write(ANDROID_LOG_INFO, "ParanoiaService", "background notify poll skipped: app is active");
#endif
        return;
    }
#if defined(Q_OS_ANDROID)
    QJniEnvironment jniEnv;
#endif
    std::vector<PollTarget> targets;
    {
        QMutexLocker lock(&m_bgPollSnapshotMutex);
        targets = m_bgPollSnapshot;
    }
#if defined(Q_OS_ANDROID)
    __android_log_print(ANDROID_LOG_INFO, "ParanoiaService", "background notify poll started: targets=%zu",
                        targets.size());
#endif
    if (targets.empty()) {
#if defined(Q_OS_ANDROID)
        __android_log_write(ANDROID_LOG_INFO, "ParanoiaService", "background notify poll finished: no targets");
#endif
        return;
    }
#if defined(Q_OS_IOS)
    // Входящие звонки в фоне (#6, iOS). На iOS опрос идёт В Qt-процессе, поэтому
    // используем in-process handle сессии: один call_poll (long-poll 30с) на сессию,
    // ключи диалогов — из session->dialogs (как в VoipSystem). На оффер (kind 0) —
    // локальный баннер с кнопками. БЕЗ push. Dedup по call_id, чтобы не звенеть дважды.
    {
        static QSet<QString> seenCallIds;
        QSet<QString> doneSessions;
        for (const auto &target : targets) {
            if (!target.session) continue;
            const QString user = target.session->serverId;
            if (user.isEmpty() || doneSessions.contains(user)) continue;
            doneSessions.insert(user);

            QJsonArray peers;
            for (const Dialog &d : target.session->dialogs) {
                if (d.peerServerId.isEmpty() || d.keyring.isEmpty()) continue;
                QJsonObject pk;
                pk["peer"]           = d.peerServerId;
                pk["master_key_b64"] = QString::fromUtf8(d.keyring.last().key.toBase64());
                peers.append(pk);
            }
            if (peers.isEmpty()) continue;
            const QString peersJson =
                QString::fromUtf8(QJsonDocument(peers).toJson(QJsonDocument::Compact));

            // Long-poll БЕЗ удержания ffiMutex: 30с под общим локом морозили весь UI
            // (отправка/приём/маскировка вставали в очередь). Копируем handle на миг,
            // сетевой вызов — без лока (callPoll сетевой, без записи в БД).
            std::shared_ptr<ParanoiaFFI> ffi;
            {
                QMutexLocker locker(&target.session->ffiMutex);
                ffi = target.session->ffi;
            }
            if (!ffi) continue;
            const QString callJson = ffi->callPoll(user, peersJson, 30000);
            if (callJson.isEmpty()) continue;
            QJsonParseError perr{};
            const auto doc = QJsonDocument::fromJson(callJson.toUtf8(), &perr);
            if (perr.error != QJsonParseError::NoError || !doc.isArray()) continue;
            for (const auto &v : doc.array()) {
                const auto env = v.toObject();
                if (env.value("kind").toInt(-1) != 0) continue; // только Offer
                const auto payload =
                    QJsonDocument::fromJson(env.value("payload_json").toString().toUtf8()).object();
                QString callId = payload.value("call_id").toString();
                if (callId.isEmpty())
                    callId = env.value("sender").toString() + ":"
                             + QString::number(env.value("ts_ms").toVariant().toLongLong());
                if (seenCallIds.contains(callId)) continue;
                seenCallIds.insert(callId);
                // Сохраняем расшифрованный конверт для handoff: при открытии VoipSystem
                // заберёт и скормит в CallSignaling.injectEnvelope (сервер уже drain'нул).
                PlatformNotifications::storePendingCallOffer(
                    QString::fromUtf8(QJsonDocument(env).toJson(QJsonDocument::Compact)));
                PlatformNotifications::showIncomingCall(callId);
            }
        }
    }
#endif

    quint64 total = 0;
    QString firstError;
    QString hintProfileId;
    QString hintPeer;
    int pendingPeers = 0;
    // Один multi-notify на сессию вместо N одиночных (батарея фон-сервиса).
    bool anyFailed                  = false;
    const QList<NotifyCount> counts = pollCountsGrouped(QList<PollTarget>(targets.begin(), targets.end()),
                                                        anyFailed, firstError);
    for (const auto &c : counts) {
        if (c.count == 0) continue;
        total += c.count;
        ++pendingPeers;
        if (pendingPeers == 1) {
            hintProfileId = c.profileId;
            hintPeer      = c.peer;
        } else {
            hintProfileId.clear();
            hintPeer.clear();
        }
    }
#if defined(Q_OS_ANDROID)
    __android_log_print(ANDROID_LOG_INFO, "ParanoiaService",
                        "background notify poll finished: total=%llu pendingPeers=%d failed=%d",
                        static_cast<unsigned long long>(total), pendingPeers, anyFailed ? 1 : 0);
#endif
    if (anyFailed && total == 0) {
#if defined(Q_OS_ANDROID)
        __android_log_print(ANDROID_LOG_WARN, "ParanoiaService", "background notify polling had failures: %s",
                            firstError.toUtf8().constData());
#endif
        return;
    }
    if (total > 0) {
        PlatformNotifications::showMessageCount(total, hintProfileId, hintPeer);
        emit notificationAvailable(total, hintProfileId, hintPeer);
    }
}

int NotificationCoordinator::randomNotifyDelayMs() const { return QRandomGenerator::global()->bounded(2'000, 15'001); }

int NotificationCoordinator::retryNotifyDelayMs() const
{
    const int shift  = std::min(m_notifyRetryCount, 6);
    const int base   = std::min(1000 * (1 << shift), 60'000);
    const int jitter = QRandomGenerator::global()->bounded((base / 5) + 1);
    return base + jitter;
}
