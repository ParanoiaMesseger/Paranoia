#include "ServerSession.hpp"

#include "Paths.hpp"
#include "utils/Utils.hpp"

#include <QJsonObject>

ServerSession::ServerSession(std::shared_ptr<ParanoiaFFI> ffi, const QString &server, const QString &username,
                             const QString &serverId, const QString &privateKey, const QString &profileId,
                             const QStringList &reserveServerUrls, const QStringList &turnServerUrls)
    : server(server), username(username), serverId(serverId), private_key(privateKey), profileId(profileId),
      reserveServerUrls(Utils::normalizedServerUrls(reserveServerUrls, server)),
      turnServerUrls(turnServerUrls), ffi(std::move(ffi))
{
}

bool ServerSession::isLoggedIn() const { return ffi != nullptr && ffi->isRawOk(); }

Dialog *ServerSession::findDialog(const QString &peer)
{
    for (auto &d : dialogs)
        if (d.peer == peer) return &d;
    return nullptr;
}

const Dialog *ServerSession::findDialog(const QString &peer) const
{
    for (const auto &d : dialogs)
        if (d.peer == peer) return &d;
    return nullptr;
}

void ServerSession::saveDialogs() const
{
    if (!profileId.isEmpty()) Dialog::saveToPath(Paths::profileDialogs(profileId), dialogs);
}

void ServerSession::loadDialogs()
{
    dialogs.clear();
    if (!profileId.isEmpty()) dialogs = Dialog::loadFromPath(Paths::profileDialogs(profileId));
}

void ServerSession::saveClientConfig() const
{
    if (server.isEmpty() || private_key.isEmpty()) return;
    const QString pid = profileId.isEmpty() ? Utils::profileIdFor(server, serverId) : profileId;
    saveClientConfigForProfile(pid, server, username, serverId, private_key, reserveServerUrls, turnServerUrls);
    Utils::upsertProfileManifest(pid, server, username, true);
}

void ServerSession::saveClientConfigForProfile(const QString &profileId, const QString &server, const QString &username,
                                               const QString &serverId, const QString &privateKey,
                                               const QStringList &reserveServerUrls,
                                               const QStringList &turnServerUrls)
{
    if (profileId.isEmpty() || server.isEmpty() || privateKey.isEmpty()) return;
    if (!Paths::ensureProfileDir(profileId)) return;
    const QString normalizedServer = Utils::normalizedServerUrl(server);
    // Сохраняем метаданные подключения (тариф + параметры маскировки), если они
    // уже записаны — частые перезаписи (правки резерва/TURN) не должны их стирать.
    QJsonObject obj = Utils::readJsonObjectFile(Paths::profileClient(profileId));
    for (const QString &key : {QStringLiteral("server"), QStringLiteral("reserve_server_urls"),
                               QStringLiteral("turn_server_urls"), QStringLiteral("username"),
                               QStringLiteral("server_id"), QStringLiteral("private_key")})
        obj.remove(key);
    obj["server"] = normalizedServer;
    obj["reserve_server_urls"] =
        Utils::stringListToJsonArray(Utils::normalizedServerUrls(reserveServerUrls, normalizedServer));
    obj["turn_server_urls"] = Utils::stringListToJsonArray(turnServerUrls);
    obj["username"]    = username;
    obj["server_id"]   = serverId;
    obj["private_key"] = privateKey;
    Utils::writeJsonObjectFile(Paths::profileClient(profileId), obj);
}
