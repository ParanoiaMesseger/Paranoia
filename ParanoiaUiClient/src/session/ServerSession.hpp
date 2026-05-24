#pragma once
#include "Dialog.hpp"
#include <QVariantMap>
#include <ParanoiaFFI>
#include <QList>
#include <QMutex>
#include <QString>
#include <QStringList>
#include <memory>

class ServerSession
{
public:
    ServerSession(std::shared_ptr<ParanoiaFFI> ffi, const QString &server, const QString &username,
                  const QString &serverId, const QString &privateKey, const QString &profileId,
                  const QStringList &reserveServerUrls, const QStringList &turnServerUrls = {});

    ServerSession(const ServerSession &)            = delete;
    ServerSession &operator=(const ServerSession &) = delete;
    bool isLoggedIn() const;
    Dialog *findDialog(const QString &peer);
    const Dialog *findDialog(const QString &peer) const;
    void saveDialogs() const;
    void loadDialogs();
    void saveClientConfig() const;
    static void saveClientConfigForProfile(const QString &profileId, const QString &server, const QString &username,
                                           const QString &serverId, const QString &privateKey,
                                           const QStringList &reserveServerUrls = {},
                                           const QStringList &turnServerUrls    = {});

    /// Нет смысла делать приавтными поля, которые делаешь доступными через get/set.
    const QString server;
    const QString username;
    const QString serverId;
    const QString private_key;
    const QString profileId;
    const QStringList reserveServerUrls;
    /// Резервные TURN-серверы для VoIP-fallback'а. Первичный TURN всегда
    /// выводится из активной session-URL'а; этот список — дополнительные,
    /// используемые когда первичный недоступен (см. CallController::ICE
    /// connectivity checks). Формат каждого: "host:port" или "host" (тогда
    /// порт 3478 по умолчанию).
    QStringList turnServerUrls;
    QList<Dialog> dialogs;
    mutable QMutex ffiMutex;
    std::shared_ptr<ParanoiaFFI> ffi;
};
