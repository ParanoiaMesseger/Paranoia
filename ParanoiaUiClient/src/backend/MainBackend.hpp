#pragma once
#include <QQmlEngine>
#include <QVariantList>
#include <QTimer>
#include <QMap>

class MainBackend : public QObject
{
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(bool loggedIn READ isLoggedIn NOTIFY loginStateChanged)
    Q_PROPERTY(QString username READ username NOTIFY loginStateChanged)
    Q_PROPERTY(QString server READ server NOTIFY loginStateChanged)
    Q_PROPERTY(bool hasAdminAccess READ hasAdminAccess NOTIFY adminStateChanged)
    Q_PROPERTY(QString devicePubkey READ devicePubkey NOTIFY deviceKeyChanged)
    Q_PROPERTY(QString notificationHintPeer READ notificationHintPeer NOTIFY notificationHintPeerChanged)

public:
    explicit MainBackend(QObject *parent = nullptr);
    ~MainBackend() override;

    bool isLoggedIn() const;
    QString username() const;
    QString server() const;
    bool hasAdminAccess() const;
    QString devicePubkey() const;
    QString notificationHintPeer() const;

    Q_INVOKABLE void generateKeyPair();
    Q_INVOKABLE void loginClient(const QString &server, const QString &username, const QString &private_key);
    Q_INVOKABLE void activateProfile(const QString &profileId);
    Q_INVOKABLE void registerUser(const QString &domain, const QString &pubkey);

    Q_INVOKABLE void addDialog(const QString &peer, const QString &sharedSecret);
    Q_INVOKABLE void updateDialogKey(const QString &peer, const QString &newSharedSecret);
    Q_INVOKABLE QVariantMap createDialogKeyInvitation(const QString &peer) const;
    Q_INVOKABLE QVariantMap createDialogKeyResponse(const QString &invitationPayloadJson);
    Q_INVOKABLE QVariantMap dialogKeyFingerprint(const QString &localStateJson, const QString &peerPayloadJson);
    Q_INVOKABLE QVariantMap confirmDialogKeyExchange(const QString &peer, const QString &localStateJson,
                                                     const QString &peerPayloadJson, const QString &fingerprint,
                                                     bool updateExisting);
    Q_INVOKABLE void removeDialog(const QString &peer);
    Q_INVOKABLE QVariantList getDialogs() const;
    Q_INVOKABLE QVariantList getAdminServers() const;
    Q_INVOKABLE QVariantList getSessionList() const;
    Q_INVOKABLE void switchSession(const QString &profileId);

    Q_INVOKABLE QString takeNotificationPeer();
    Q_INVOKABLE void deleteDialogLocal(const QString &peer);
    Q_INVOKABLE void clearServerHistory(const QString &peer, quint64 cutSeq);

    Q_INVOKABLE QVariantMap exportProfile(const QString &profileType, const QStringList &peers,
                                          const QString &receiverPubkeyB64, const QString &filePath);
    Q_INVOKABLE QVariantMap importProfile(const QString &filePath);
    Q_INVOKABLE QVariantMap deleteExportFile(const QString &filePath);

signals:
    void keyPairGenerated(const QString &pubkey, const QString &private_key);
    void loginStateChanged();
    void deviceKeyChanged();
    void adminStateChanged();
    void loginError(const QString &msg);
    void userRegistered();
    void registerUserError(const QString &msg);
    void dialogsChanged();
    void notificationAvailable(quint64 count, const QString &peer);
    void notificationHintPeerChanged();
    void dialogDeleted(const QString &peer);
    void serverHistoryCleared(const QString &peer);
    void serverHistoryError(const QString &msg);
    // Cross-backend coordination
    void networkRestored();
    void dialogRemoved(const QString &peer);
    void sessionReset();
    void sessionsChanged();
    void sessionSwitched();

public slots:
    void onActivePeerChanged(const QString &peer);
    void onPeerMessagesRead(const QString &peer);

private slots:
    void onPollTimer();
    void onNetworkChanged();

private:
    QString m_activePeer;
    QString m_devicePrivkey;
    QTimer *m_pollTimer;
    QMap<QString, quint64> m_notifiedPendingByPeer;
    QString m_notificationHintPeer;
    int m_notifyRetryCount    = 0;
    bool m_notifyPollInFlight = false;

    void loginClientInternal(const QString &server, const QString &username, const QString &private_key,
                             bool makeActive);
    void loadClientConfig();
    void saveDeviceKey() const;
    void loadDeviceKey();
    void setNotificationHintPeer(const QString &peer);
    void pollNotifications();
    void scheduleNotifyPoll(int delayMs = -1);
    int randomNotifyDelayMs() const;
    int retryNotifyDelayMs() const;
    void upsertDialogKeyringEntry(const QString &peer, const QString &peerServerId, const QByteArray &sessionKey,
                                  quint64 startSeq, bool resetKeyring);
};
