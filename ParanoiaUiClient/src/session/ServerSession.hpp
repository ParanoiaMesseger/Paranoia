#pragma once
#include "Dialog.hpp"
#include <QVariantMap>
#include <ParanoiaFFI>
#include <QList>
#include <QMutex>
#include <QString>
#include <memory>

class ServerSession
{
public:
    ServerSession(std::unique_ptr<ParanoiaFFI> ffi, const QString &server, const QString &username,
                  const QString &serverId, const QString &privateKey, const QString &profileId);

    ServerSession(const ServerSession &)            = delete;
    ServerSession &operator=(const ServerSession &) = delete;
    bool isLoggedIn() const;
    Dialog *findDialog(const QString &peer);
    const Dialog *findDialog(const QString &peer) const;
    void saveDialogs() const;
    void loadDialogs();
    void saveClientConfig() const;
    static void saveClientConfigForProfile(const QString &profileId, const QString &server, const QString &username,
                                           const QString &serverId, const QString &privateKey);

    /// Нет смысла делать приавтными поля, которые делаешь доступными через get/set.
    const QString server;
    const QString username;
    const QString serverId;
    const QString private_key;
    const QString profileId;
    QList<Dialog> dialogs;
    mutable QMutex ffiMutex;
    std::unique_ptr<ParanoiaFFI> ffi;
};
