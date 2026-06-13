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
    // Время последней активности (ms epoch), отслеженное координатором для
    // ФОНОВЫХ входящих (пока диалог не открыт и appendMessages не звался).
    // Сортировка списка диалогов берёт max этого и Dialog::lastActivityMs.
    qint64 lastActivityMs(const QString &profileId, const QString &peer) const;
    bool isNotificationHintFor(const QString &profileId, const QString &peer) const;

    Q_INVOKABLE QString takeNotificationPeer();
    bool clearPeer(const QString &profileId, const QString &peer);
    // Убрать ВСЕ in-memory счётчики/активность профиля (при удалении профиля).
    void clearProfile(const QString &profileId);
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
    // Пока приложение на переднем плане — периодически продлеваем foreground-флаг
    // фон-сервиса (у того TTL). Если UI-процесс упадёт/будет убит «активным», флаг
    // не продлится и сервис в течение TTL сам возобновит фоновый опрос (иначе флаг
    // залип бы в true и уведомления молча пропадали до следующего открытия app).
    QTimer m_foregroundHeartbeat;
    QString m_activePeer;
    QMap<QString, quint64> m_notifiedPendingByPeer;
    QMap<QString, quint64> m_locallyReceivedPendingByPeer;
    // Свежесть для сортировки (in-memory, как и счётчики непрочитанного):
    // бампается при детекте нового ФОНОВОГО сообщения, НЕ при прочтении.
    QMap<QString, qint64> m_lastActivityByPeer;
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
