#include "SessionStore.hpp"

#include <algorithm>

SessionStore *SessionStore::instance()
{
    // Намеренно «утекающий» синглтон: НЕ освобождается в atexit. Иначе его
    // деструктор бежал бы в __run_exit_handlers уже после остановки Qt/рантайма и
    // закрывал бы SQLCipher-соединения в момент глобальной деструкции — это падало
    // SIGSEGV в sqlite3FreeCodecArg (static destruction order). Чистое закрытие БД
    // делаем заранее через shutdown() на aboutToQuit; ОС вернёт память на выходе.
    static SessionStore *inst = new SessionStore();
    return inst;
}

SessionStore::SessionStore(QObject *parent) : QObject(parent) {}

void SessionStore::shutdown()
{
    // Гасим сессии, пока жив event-loop: дроп shared_ptr<ServerSession> →
    // ParanoiaFFI → Rust paranoia_client_free → чистое закрытие SQLCipher-БД здесь,
    // а не в atexit. Сигналы НЕ шлём — приложение уже завершается, реагировать
    // на смену сессий некому (QML-движок может разрушаться).
    m_activeSession.reset();
    m_sessions.clear();
}

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
                                                        const QStringList &reserveServerUrls,
                                                        const QStringList &turnServerUrls)
{
    auto it = std::find_if(m_sessions.begin(), m_sessions.end(),
                           [&profileId](const auto &s) { return s->profileId == profileId; });
    if (it != m_sessions.end()) {
        if (m_activeSession == *it) m_activeSession.reset();
        m_sessions.erase(it);
    }
    auto session = std::make_shared<ServerSession>(std::move(ffi), server, username, serverId, privateKey, profileId,
                                                   reserveServerUrls, turnServerUrls);
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
