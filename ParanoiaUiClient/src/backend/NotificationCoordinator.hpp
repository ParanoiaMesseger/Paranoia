#pragma once

#include <QList>
#include <QMap>
#include <QMutex>
#include <QObject>
#include <QTimer>
#include <QString>
#include <Qt>
#include <atomic>
#include <memory>
#include <vector>

class ServerSession;

class NotificationCoordinator : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString notificationHintPeer READ notificationHintPeer NOTIFY notificationHintPeerChanged)
    Q_PROPERTY(QString notificationHintProfileId READ notificationHintProfileId NOTIFY notificationHintPeerChanged)

public:
    explicit NotificationCoordinator(QObject *parent = nullptr);
    ~NotificationCoordinator() override;

    QString notificationHintPeer() const;
    QString notificationHintProfileId() const;
    quint64 unreadCount(const QString &profileId, const QString &peer) const;
    quint64 totalUnreadForProfile(const QString &profileId) const;
    bool isNotificationHintFor(const QString &profileId, const QString &peer) const;

    Q_INVOKABLE QString takeNotificationPeer();
    bool clearPeer(const QString &profileId, const QString &peer);
    void resetActiveContext();
    void schedulePoll(int delayMs = -1);

signals:
    void notificationAvailable(quint64 count, const QString &profileId, const QString &peer);
    void notificationsCleared();
    void notificationHintPeerChanged();
    void dialogsChanged();
    void networkRestored();
    void sessionReset();
    void sessionSwitched();

public slots:
    void onActivePeerChanged(const QString &peer);
    void onPeerMessagesRead(const QString &peer);
    void onBackgroundMessagesReceived(const QString &profileId, const QString &peer, quint64 count);

private slots:
    void onPollTimer();
    void onNetworkChanged();
    void onApplicationStateChanged(Qt::ApplicationState state);

private:
    enum class PollMode { Foreground, Background };

    struct PollTarget {
        std::shared_ptr<ServerSession> session;
        QString profileId;
        QString peer;
        QString peerServerId;
        QString keyringJson;
    };

    struct NotifyCount {
        QString key;
        QString profileId;
        QString peer;
        quint64 count;
    };

    QTimer m_pollTimer;
    QString m_activePeer;
    QMap<QString, quint64> m_notifiedPendingByPeer;
    QMap<QString, quint64> m_locallyReceivedPendingByPeer;
    QString m_notificationHintProfileId;
    QString m_notificationHintPeer;
    int m_notifyRetryCount               = 0;
    bool m_notifyPollInFlight            = false;
    std::atomic_bool m_applicationActive = false;

    mutable QMutex m_bgPollSnapshotMutex;
    std::vector<PollTarget> m_bgPollSnapshot;

    bool applicationIsActive() const;
    bool setNotificationHint(const QString &profileId, const QString &peer);
    void pollForegroundNotifications();
    void pollBackgroundNotifications();
    void pollNotifications(PollMode mode);
    QList<PollTarget> buildPollTargets(PollMode mode) const;
    void applyNotifyCounts(PollMode mode, const QList<NotifyCount> &counts, bool anyFailed, const QString &error);
    void presentNotification(PollMode mode, quint64 total, const QString &profileId, const QString &peer);
    void rebuildBackgroundPollSnapshot();
    void runBackgroundPollFromService();
    int randomNotifyDelayMs() const;
    int retryNotifyDelayMs() const;
};
