#include "ServerSession.hpp"

#include "Paths.hpp"
#include "utils/Utils.hpp"

#include <QJsonObject>

ServerSession::ServerSession(std::unique_ptr<ParanoiaFFI> ffi, const QString &server, const QString &username,
                             const QString &serverId, const QString &privateKey, const QString &profileId)
    : server(server), username(username), serverId(serverId), private_key(privateKey), profileId(profileId),
      ffi(std::move(ffi))
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
    saveClientConfigForProfile(pid, server, username, serverId, private_key);
    Utils::upsertProfileManifest(pid, server, username, true);
}

void ServerSession::saveClientConfigForProfile(const QString &profileId, const QString &server, const QString &username,
                                               const QString &serverId, const QString &privateKey)
{
    if (profileId.isEmpty() || server.isEmpty() || privateKey.isEmpty()) return;
    if (!Paths::ensureProfileDir(profileId)) return;
    QJsonObject obj;
    obj["server"]      = Utils::normalizedServerUrl(server);
    obj["username"]    = username;
    obj["server_id"]   = serverId;
    obj["private_key"] = privateKey;
    Utils::writeJsonObjectFile(Paths::profileClient(profileId), obj);
}
