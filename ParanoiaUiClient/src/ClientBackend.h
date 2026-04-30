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

public:
    explicit ClientBackend(QObject *parent = nullptr);
    ~ClientBackend();

    bool isLoggedIn() const;
    QString username() const;
    QString server() const;
    bool hasAdminAccess() const;

    Q_INVOKABLE void generateKeyPair();
    Q_INVOKABLE void loginClient(const QString &server, const QString &username, const QString &privkey);
    Q_INVOKABLE void connectAdmin(const QString &server, const QString &privkey);
    Q_INVOKABLE void registerUser(const QString &domain, const QString &username, const QString &pubkey);

    Q_INVOKABLE void addDialog(const QString &peer, const QString &sharedSecret);
    Q_INVOKABLE void removeDialog(const QString &peer);
    Q_INVOKABLE QVariantList getDialogs() const;
    Q_INVOKABLE QVariantList getAdminServers() const;

    Q_INVOKABLE void openChat(const QString &peer);
    Q_INVOKABLE void stopChat();
    Q_INVOKABLE void sendText(const QString &text);
    Q_INVOKABLE void fetchMessages();
    Q_INVOKABLE QVariantList getCachedMessages(const QString &peer) const;
    Q_INVOKABLE QString activePeer() const;

signals:
    void keyPairGenerated(const QString &pubkey, const QString &privkey);
    void loginStateChanged();
    void adminStateChanged();
    void loginError(const QString &msg);
    void adminConnected();
    void connectError(const QString &msg);
    void userRegistered();
    void registerUserError(const QString &msg);
    void dialogsChanged();
    void messagesReceived(const QVariantList &messages);
    void sendError(const QString &msg);

private slots:
    void onPollTimer();

private:
    struct Dialog {
        QString peer;
        QByteArray sessionKey; // 32 bytes (SHA-256 of sharedSecret)
        QString lastMsg;
    };

    mutable QMutex m_handleMutex;
    ParanoiaHandle *m_handle = nullptr;
    QString m_server;
    QString m_username;
    QString m_privkey;
    QString m_activePeer;

    QList<Dialog> m_dialogs;
    QMap<QString, QVariantList> m_messageCache;
    QMap<QString, QSet<QString>> m_seenIds;
    QTimer *m_pollTimer;

    void saveClientConfig() const;
    void loadClientConfig();
    void saveDialogs() const;
    void loadDialogs();
    void loadHistory(const QString &peer);
    void appendMessages(const QString &peer, const QVariantList &messages);

    QByteArray deriveKey(const QString &sharedSecret) const;
    QVariantList parseMessages(const QString &json) const;
    QString extractText(const QString &debugContent) const;
    Dialog *findDialog(const QString &peer);
};
