#include "SessionStore.hpp"

#include <algorithm>

SessionStore *SessionStore::instance()
{
    static SessionStore inst;
    return &inst;
}

SessionStore::SessionStore(QObject *parent) : QObject(parent) {}

std::shared_ptr<ServerSession> SessionStore::activeSession() const { return m_activeSession; }

std::shared_ptr<ServerSession> SessionStore::sessionFor(const QString &server, const QString &username) const
{
    for (const auto &s : m_sessions)
        if (s->server == server && s->username == username) return s;
    return nullptr;
}

std::shared_ptr<ServerSession> SessionStore::sessionForProfile(const QString &profileId) const
{
    for (const auto &s : m_sessions)
        if (s->profileId == profileId) return s;
    return nullptr;
}

std::shared_ptr<ServerSession> SessionStore::addSession(std::shared_ptr<ParanoiaFFI> ffi, const QString &server,
                                                        const QString &username, const QString &serverId,
                                                        const QString &privateKey, const QString &profileId,
                                                        const QStringList &reserveServerUrls)
{
    auto it = std::find_if(m_sessions.begin(), m_sessions.end(),
                           [&profileId](const auto &s) { return s->profileId == profileId; });
    if (it != m_sessions.end()) {
        if (m_activeSession == *it) m_activeSession.reset();
        m_sessions.erase(it);
    }
    auto session = std::make_shared<ServerSession>(std::move(ffi), server, username, serverId, privateKey, profileId,
                                                   reserveServerUrls);
    m_sessions.push_back(session);
    emit sessionsChanged();
    return session;
}

void SessionStore::setActiveSession(const std::shared_ptr<ServerSession> &session)
{
    if (m_activeSession == session) return;
    m_activeSession = session;
    emit activeSessionChanged();
}

void SessionStore::removeSession(const std::shared_ptr<ServerSession> &session)
{
    auto it = std::find(m_sessions.begin(), m_sessions.end(), session);
    if (it == m_sessions.end()) return;
    if (m_activeSession == session) {
        m_activeSession.reset();
        emit activeSessionChanged();
    }
    m_sessions.erase(it);
    emit sessionsChanged();
}
