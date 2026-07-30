#include "ServerSession.hpp"

#include "Paths.hpp"
#include "utils/Utils.hpp"

#include <QJsonObject>
#include <QThreadPool>
#include <QWaitCondition>
#include <utility>

// ── Асинхронная коалесирующая запись dialogs.json ────────────────────────────
//
// Корень фризов 01#7/01#12: saveDialogs() сериализовал ВСЕ диалоги профиля (вместе
// с base64-аватарами), шифровал их через vault-FFI и писал файл на диск СИНХРОННО
// на GUI-потоке — на каждый батч сообщений, каждый символ черновика, каждое
// переключение чипа темы. Здесь запись уходит на QThreadPool: вызывающий поток лишь
// снимает копию QList<Dialog> (implicitly-shared, дёшево) и кладёт её как «ожидающий
// снимок». Инварианты:
//   • одновременно на очередь крутится не более одного воркера → записи в один и тот
//     же файл сериализованы (без гонки atomic-rename), и всегда пишется САМЫЙ СВЕЖИЙ
//     снимок (последняя запись побеждает; промежуточные схлопываются — коалесинг);
//   • m_hasPending ⇒ m_running (enqueue взводит running вместе с pending; drain
//     снимает running, только когда pending пуст) → дождавшись простоя, flush()
//     гарантирует, что последний снимок уже на диске;
//   • очередь живёт в shared_ptr, воркер держит свою копию → запись доводится до
//     конца даже если ServerSession уже разрушен (снимок снят по значению, путь
//     хранится здесь). Все QList — отдельные объекты поверх общих atomically-refcnt
//     данных: GUI-мутация dialogs делает detach, воркер читает свой снимок — гонки
//     данных нет (потокобезопасность implicit sharing Qt).
class DialogSaveQueue : public std::enable_shared_from_this<DialogSaveQueue>
{
public:
    explicit DialogSaveQueue(QString path) : m_path(std::move(path)) {}

    void enqueue(QList<Dialog> snapshot)
    {
        bool needStart = false;
        {
            QMutexLocker lock(&m_mutex);
            m_pending    = std::move(snapshot);
            m_hasPending = true;
            if (!m_running) {
                m_running = true;
                needStart = true;
            }
        }
        if (needStart) {
            auto self = shared_from_this();
            QThreadPool::globalInstance()->start([self]() { self->drain(); });
        }
    }

    void flush()
    {
        QMutexLocker lock(&m_mutex);
        while (m_running) m_idle.wait(&m_mutex);
    }

private:
    void drain()
    {
        for (;;) {
            QList<Dialog> snap;
            {
                QMutexLocker lock(&m_mutex);
                if (!m_hasPending) {
                    m_running = false;
                    m_idle.wakeAll(); // разбудить flush(), ждущий простоя
                    return;
                }
                snap         = std::move(m_pending);
                m_hasPending = false;
            }
            Dialog::saveToPath(m_path, snap); // сериализация + vault-шифр + запись, БЕЗ лока
        }
    }

    const QString  m_path;
    QMutex         m_mutex;
    QWaitCondition m_idle;
    QList<Dialog>  m_pending;
    bool           m_hasPending = false;
    bool           m_running    = false;
};

ServerSession::ServerSession(std::shared_ptr<ParanoiaFFI> ffi, const QString &server, const QString &username,
                             const QString &serverId, const QString &privateKey, const QString &profileId,
                             const QStringList &reserveServerUrls, const QStringList &turnServerUrls)
    : server(server), username(username), serverId(serverId), private_key(privateKey), profileId(profileId),
      reserveServerUrls(Utils::normalizedServerUrls(reserveServerUrls, server)),
      turnServerUrls(turnServerUrls), ffi(std::move(ffi))
{
    if (!this->profileId.isEmpty())
        m_saveQueue = std::make_shared<DialogSaveQueue>(Paths::profileDialogs(this->profileId));
}

// Определён здесь (а не =default в заголовке): DialogSaveQueue тут полный.
ServerSession::~ServerSession() = default;

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

Dialog *ServerSession::findDialogByServerId(const QString &serverId)
{
    if (serverId.isEmpty()) return nullptr;
    for (auto &d : dialogs)
        if (d.peerServerId == serverId) return &d;
    return nullptr;
}

void ServerSession::saveDialogs() const
{
    // Снимок диалогов снимается СЕЙЧАС, на вызывающем потоке (владельце dialogs), а
    // тяжёлая часть (vault-шифр + запись) уходит воркеру — GUI больше не встаёт.
    if (m_saveQueue) m_saveQueue->enqueue(dialogs);
}

void ServerSession::flushDialogs() const
{
    if (m_saveQueue) m_saveQueue->flush();
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
