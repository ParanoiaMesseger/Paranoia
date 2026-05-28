#pragma once
#include "ServerSession.hpp"
#include <QObject>
#include <memory>
#include <vector>

class SessionStore : public QObject
{
    Q_OBJECT

public:
    static SessionStore *instance();

    std::shared_ptr<ServerSession> activeSession() const;
    std::shared_ptr<ServerSession> sessionFor(const QString &server, const QString &username) const;
    std::shared_ptr<ServerSession> sessionForProfile(const QString &profileId) const;
    const std::vector<std::shared_ptr<ServerSession>> &allSessions() const { return m_sessions; }

    std::shared_ptr<ServerSession> addSession(std::shared_ptr<ParanoiaFFI> ffi, const QString &server,
                                              const QString &username, const QString &serverId,
                                              const QString &privateKey, const QString &profileId,
                                              const QStringList &reserveServerUrls = {},
                                              const QStringList &turnServerUrls    = {});
    void setActiveSession(const std::shared_ptr<ServerSession> &session);
    void removeSession(const std::shared_ptr<ServerSession> &session);

signals:
    void activeSessionChanged();
    void sessionsChanged();

private:
    explicit SessionStore(QObject *parent = nullptr);

    std::vector<std::shared_ptr<ServerSession>> m_sessions;
    std::shared_ptr<ServerSession> m_activeSession;
};
