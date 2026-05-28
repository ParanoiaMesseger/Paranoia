#include "NotificationCoordinator.hpp"

#include "platform/PlatformNotifications.hpp"
#include "session/ServerSession.hpp"
#include "session/SessionStore.hpp"
#include <ParanoiaFFI>

#include <QCoreApplication>
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
        QList<NotifyCount> counts;
        QString error;
        bool anyFailed = false;
        if (!self) return;
        for (const auto &target : targets) {
            uint64_t count    = 0;
            const QString key = target.profileId + QLatin1Char(':') + target.peer;
            {
                QMutexLocker locker(&target.session->ffiMutex);
                if (!target.session->ffi) continue;
                const int rc = target.session->ffi->notify_count_keyring(target.session->serverId, target.peerServerId,
                                                                         target.keyringJson, count);
                if (rc != 0) {
                    anyFailed = true;
                    if (error.isEmpty()) error = ParanoiaFFI::last_error();
                    continue;
                }
            }
            counts.append({key, target.profileId, target.peer, static_cast<quint64>(count)});
        }
        if (!self) return;
        QMetaObject::invokeMethod(self, [self, counts, anyFailed, error, mode]() {
            if (!self) return;
            self->m_notifyPollInFlight = false;
            self->applyNotifyCounts(mode, counts, anyFailed, error);
        });
    });
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
    quint64 total = 0;
    int failures  = 0;
    QString firstError;
    QString hintProfileId;
    QString hintPeer;
    int pendingPeers = 0;
    for (const auto &target : targets) {
        uint64_t count = 0;
        int rc;
        {
            QMutexLocker locker(&target.session->ffiMutex);
            if (!target.session->ffi) continue;
            rc = target.session->ffi->notify_count_keyring(target.session->serverId, target.peerServerId,
                                                           target.keyringJson, count);
        }
        if (rc != 0) {
            ++failures;
            if (firstError.isEmpty()) firstError = ParanoiaFFI::last_error();
            continue;
        }
        if (count > 0) {
            total += static_cast<quint64>(count);
            ++pendingPeers;
            if (pendingPeers == 1) {
                hintProfileId = target.profileId;
                hintPeer      = target.peer;
            } else {
                hintProfileId.clear();
                hintPeer.clear();
            }
        }
    }
#if defined(Q_OS_ANDROID)
    __android_log_print(ANDROID_LOG_INFO, "ParanoiaService",
                        "background notify poll finished: total=%llu pendingPeers=%d failures=%d",
                        static_cast<unsigned long long>(total), pendingPeers, failures);
#endif
    if (failures > 0 && total == 0) {
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
