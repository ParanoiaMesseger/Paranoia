#pragma once
#include <QObject>
#include <QQmlEngine>
#include <QVariantList>
#include <QVariantMap>
#include <QTimer>
#include <QMutex>
#include <QSet>
#include <QMap>
#include "paranoia_lib.h"
#include "adminStorage.hpp"

class ClientBackend : public QObject {
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(bool loggedIn READ isLoggedIn NOTIFY loginStateChanged)
    Q_PROPERTY(QString username READ username NOTIFY loginStateChanged)
    Q_PROPERTY(QString server READ server NOTIFY loginStateChanged)
    Q_PROPERTY(bool hasAdminAccess READ hasAdminAccess NOTIFY adminStateChanged)
    Q_PROPERTY(QString devicePubkey READ devicePubkey NOTIFY deviceKeyChanged)

public:
    explicit ClientBackend(QObject *parent = nullptr);
    ~ClientBackend();

    bool isLoggedIn() const;
    QString username() const;
    QString server() const;
    bool hasAdminAccess() const;
    QString devicePubkey() const;

    Q_INVOKABLE void generateKeyPair();
    Q_INVOKABLE void loginClient(const QString &server, const QString &username, const QString &privkey);
    Q_INVOKABLE void connectAdmin(const QString &server, const QString &privkey);
    Q_INVOKABLE void registerUser(const QString &domain, const QString &username, const QString &pubkey);
    Q_INVOKABLE QString qrCodePngDataUrl(const QString &payload, int size = 512) const;
    Q_INVOKABLE QVariantMap decodeQrCodeFromImage(const QString &filePath) const;
    Q_INVOKABLE QVariantMap registrationPublicKeyFromQr(const QString &payload) const;

    Q_INVOKABLE void addDialog(const QString &peer, const QString &sharedSecret);
    Q_INVOKABLE void updateDialogKey(const QString &peer, const QString &newSharedSecret);
    Q_INVOKABLE QVariantMap createDialogKeyInvitation(const QString &peer);
    Q_INVOKABLE QVariantMap createDialogKeyResponse(const QString &invitationPayloadJson);
    Q_INVOKABLE QVariantMap dialogKeyFingerprint(const QString &localStateJson, const QString &peerPayloadJson);
    Q_INVOKABLE QVariantMap confirmDialogKeyExchange(const QString &peer,
                                                     const QString &localStateJson,
                                                     const QString &peerPayloadJson,
                                                     const QString &fingerprint,
                                                     bool updateExisting);
    Q_INVOKABLE void removeDialog(const QString &peer);
    Q_INVOKABLE QVariantList getDialogs() const;
    Q_INVOKABLE QVariantList getClientProfiles() const;
    Q_INVOKABLE void switchClientProfile(const QString &profileId);
    Q_INVOKABLE QVariantList getAdminServers() const;
    Q_INVOKABLE bool hasDialogKey(const QString &peer) const;

    Q_INVOKABLE void openChat(const QString &peer);
    Q_INVOKABLE void stopChat();
    Q_INVOKABLE void sendText(const QString &text);
    Q_INVOKABLE void fetchMessages();
    Q_INVOKABLE QVariantList getCachedMessages(const QString &peer) const;
    Q_INVOKABLE QString activePeer() const;

    // Управление историей (план п.5)
    Q_INVOKABLE void deleteDialogLocal(const QString &peer);
    Q_INVOKABLE void clearServerHistory(const QString &peer, quint64 cutSeq);

    // Экспорт / импорт keyring
    // profileType: "client", "admin", "full"
    // peers: список peer-имён для экспорта; пустой список = все диалоги
    // receiverPubkeyB64: X25519 публичный ключ принимающего устройства (base64)
    // filePath: путь к файлу для сохранения
    Q_INVOKABLE QVariantMap exportProfile(const QString &profileType,
                                         const QStringList &peers,
                                         const QString &receiverPubkeyB64,
                                         const QString &filePath);

    // filePath: путь к файлу экспорта; расшифровывается device privkey
    // suggestDeleteFile: true если после успеха предложить удалить файл (Z3b)
    Q_INVOKABLE QVariantMap importProfile(const QString &filePath);
    Q_INVOKABLE QVariantMap deleteExportFile(const QString &filePath);

signals:
    void keyPairGenerated(const QString &pubkey, const QString &privkey);
    void loginStateChanged();
    void deviceKeyChanged();
    void adminStateChanged();
    void loginError(const QString &msg);
    void adminConnected();
    void connectError(const QString &msg);
    void userRegistered();
    void registerUserError(const QString &msg);
    void dialogsChanged();
    void messagesReceived(const QVariantList &messages);
    void sendError(const QString &msg);
    void receiveError(const QString &msg);
    void dialogDeleted(const QString &peer);
    void serverHistoryCleared(const QString &peer);
    void serverHistoryError(const QString &msg);

private slots:
    void onPollTimer();

private:
    struct DialogKeyEntry {
        quint64 startSeq;
        QByteArray key;
    };

    struct Dialog {
        QString peer;
        QList<DialogKeyEntry> keyring;
        QString lastMsg;
    };

    mutable QMutex m_handleMutex;
    ParanoiaHandle *m_handle = nullptr;
    QString m_server;
    QString m_username;
    QString m_privkey;
    QString m_profileId;
    QString m_activePeer;
    QString m_devicePrivkey;

    QList<Dialog> m_dialogs;
    QMap<QString, QVariantList> m_messageCache;
    QMap<QString, QSet<QString>> m_seenIds;
    QTimer *m_pollTimer;

    void saveClientConfig() const;
    void loadClientConfig();
    void saveClientConfigForProfile(const QString &profileId,
                                    const QString &server,
                                    const QString &username,
                                    const QString &privkey) const;
    void saveDialogs() const;
    void loadDialogs();
    QList<Dialog> loadDialogsFromPath(const QString &path) const;
    void saveDialogsToPath(const QString &path, const QList<Dialog> &dialogs) const;
    void saveDeviceKey() const;
    void loadDeviceKey();
    void loadHistory(const QString &peer);
    void appendMessages(const QString &peer, const QVariantList &messages);
    void upsertDialogKeyringEntry(const QString &peer,
                                  const QByteArray &sessionKey,
                                  quint64 startSeq,
                                  bool resetKeyring,
                                  bool clearCache);

    QByteArray deriveKey(const QString &sharedSecret) const;
    QString dialogKeyringJson(const Dialog &dialog) const;
    quint64 nextKeyStartSeq(const QString &peer) const;
    QVariantList parseMessages(const QString &json) const;
    QString extractText(const QString &debugContent) const;
    Dialog *findDialog(const QString &peer);
    const Dialog *findDialog(const QString &peer) const;
};
