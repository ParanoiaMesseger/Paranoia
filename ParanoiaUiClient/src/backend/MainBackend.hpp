#pragma once
#include <QObject>
#include <QVariantList>
#include <QStringList>

class NotificationCoordinator;
class ServerSession;

class MainBackend : public QObject
{
    Q_OBJECT

    Q_PROPERTY(bool loggedIn READ isLoggedIn NOTIFY loginStateChanged)
    Q_PROPERTY(QString username READ username NOTIFY loginStateChanged)
    Q_PROPERTY(QString server READ server NOTIFY loginStateChanged)
    Q_PROPERTY(bool hasAdminAccess READ hasAdminAccess NOTIFY adminStateChanged)
    Q_PROPERTY(QString devicePubkey READ devicePubkey NOTIFY deviceKeyChanged)
    Q_PROPERTY(QString activeProfileId READ activeProfileId NOTIFY loginStateChanged)
    Q_PROPERTY(bool hasStoredClientProfiles READ hasStoredClientProfiles NOTIFY storedClientProfilesChanged)

public:
    explicit MainBackend(NotificationCoordinator &notifications, QObject *parent = nullptr);
    ~MainBackend() override;

    bool isLoggedIn() const;
    QString username() const;
    QString server() const;
    bool hasAdminAccess() const;
    QString devicePubkey() const;
    QString activeProfileId() const;
    bool hasStoredClientProfiles() const;

    Q_INVOKABLE void generateKeyPair();
    Q_INVOKABLE void loginClient(const QString &server, const QString &reserveServer, const QString &username,
                                 const QString &private_key);
    Q_INVOKABLE void activateProfile(const QString &profileId);
    Q_INVOKABLE void registerUser(const QString &domain, const QString &pubkey);
    Q_INVOKABLE QVariantList getReserveDomains(const QString &targetType, const QString &targetId,
                                               const QString &primaryDomain) const;
    Q_INVOKABLE void addAdminReserveDomain(const QString &primaryDomain, const QString &reserveDomain);
    Q_INVOKABLE void addClientReserveDomain(const QString &profileId, const QString &reserveDomain);
    Q_INVOKABLE void removeAdminReserveDomain(const QString &primaryDomain, const QString &reserveDomain);
    Q_INVOKABLE void removeClientReserveDomain(const QString &profileId, const QString &reserveDomain);
    Q_INVOKABLE void checkReserveDomain(const QString &targetType, const QString &targetId,
                                        const QString &primaryDomain, const QString &reserveDomain);

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
    void reserveDomainAdded(const QString &targetType, const QString &targetId, const QString &reserveDomain);
    void reserveDomainRemoved(const QString &targetType, const QString &targetId, const QString &reserveDomain);
    void reserveDomainCheckFinished(const QString &targetType, const QString &targetId, const QString &reserveDomain,
                                    bool ok, const QString &msg, qint64 pingMs);
    void reserveDomainError(const QString &msg);
    void dialogsChanged();
    void dialogDeleted(const QString &peer);
    void serverHistoryCleared(const QString &peer);
    void serverHistoryError(const QString &msg);
    // Cross-backend coordination
    void dialogRemoved(const QString &peer);
    void sessionReset();
    void sessionsChanged();
    void sessionSwitched();
    void storedClientProfilesChanged();

private:
    NotificationCoordinator *m_notifications = nullptr;
    QString m_devicePrivkey;
    bool m_hasStoredClientProfiles = false;
    void setHasStoredClientProfiles(bool hasProfiles);
    void loginClientInternal(const QString &server, const QString &username, const QString &private_key,
                             const QStringList &reserveServerUrls, bool makeActive,
                             bool rotateRegistrationKeyOnSuccess = false);
    void rotateRegistrationKeyPair(const QString &previousPrivateKey = {});
    void loadClientConfig();
    void saveDeviceKey() const;
    void loadDeviceKey();
    void upsertDialogKeyringEntry(const QString &peer, const QString &peerServerId, const QByteArray &sessionKey,
                                  quint64 startSeq, bool resetKeyring);
};
