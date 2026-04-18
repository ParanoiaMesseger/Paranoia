#include "ClientBackend.h"
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <QCryptographicHash>
#include <QThreadPool>
#include <QPointer>

ClientBackend::ClientBackend(QObject *parent) : QObject(parent)
{
    m_pollTimer = new QTimer(this);
    m_pollTimer->setInterval(2500);
    connect(m_pollTimer, &QTimer::timeout, this, &ClientBackend::onPollTimer);
}

ClientBackend::~ClientBackend()
{
    m_pollTimer->stop();
    QMutexLocker locker(&m_handleMutex);
    if (m_handle) {
        paranoia_client_free(m_handle);
        m_handle = nullptr;
    }
}

bool ClientBackend::isLoggedIn() const
{
    QMutexLocker locker(&m_handleMutex);
    return m_handle != nullptr;
}

QString ClientBackend::username() const { return m_username; }
QString ClientBackend::server() const { return m_server; }

bool ClientBackend::hasAdminAccess() const
{
    return !admin::Admin::admins.empty();
}

QString ClientBackend::activePeer() const { return m_activePeer; }

// ── Key Generation ────────────────────────────────────────────────────────────

void ClientBackend::generateKeyPair()
{
    QThreadPool::globalInstance()->start([this]() {
        char *secret = nullptr;
        char *pubkey = nullptr;
        paranoia_generate_keypair(&secret, &pubkey);
        QString secretStr = secret ? QString::fromUtf8(secret) : QString();
        QString pubkeyStr = pubkey ? QString::fromUtf8(pubkey) : QString();
        paranoia_free_string(secret);
        paranoia_free_string(pubkey);
        QMetaObject::invokeMethod(this, [this, pubkeyStr, secretStr]() {
            emit keyPairGenerated(pubkeyStr, secretStr);
        });
    });
}

// ── Client Login ──────────────────────────────────────────────────────────────

void ClientBackend::loginClient(const QString &server, const QString &username, const QString &privkey)
{
    QString url = server;
    if (!url.startsWith("http://") && !url.startsWith("https://"))
        url = "https://" + url;

    QString dbPath = QString("paranoia_%1.db").arg(username);

    QPointer<ClientBackend> self(this);
    QThreadPool::globalInstance()->start([self, url, username, privkey, dbPath]() {
        auto *handle = paranoia_client_new(
            url.toUtf8().constData(),
            username.toUtf8().constData(),
            privkey.toUtf8().constData(),
            dbPath.toUtf8().constData()
        );
        QMetaObject::invokeMethod(self, [self, handle, url, username]() {
            if (!self) {
                if (handle) paranoia_client_free(handle);
                return;
            }
            {
                QMutexLocker locker(&self->m_handleMutex);
                if (self->m_handle) {
                    paranoia_client_free(self->m_handle);
                }
                self->m_handle = handle;
            }
            if (handle) {
                self->m_server   = url;
                self->m_username = username;
                emit self->loginStateChanged();
            } else {
                emit self->loginError("Не удалось подключиться. Проверьте адрес сервера и ключ.");
            }
        });
    });
}

// ── Admin Connect ─────────────────────────────────────────────────────────────

void ClientBackend::connectAdmin(const QString &server, const QString &privkey)
{
    QByteArray keyBytes = QByteArray::fromBase64(privkey.toUtf8());
    if (keyBytes.size() != 32) {
        emit connectError("Неверный формат ключа (ожидается 32 байта в base64).");
        return;
    }

    QString url = server;
    if (!url.startsWith("http://") && !url.startsWith("https://"))
        url = "https://" + url;

    bool exists = false;
    for (auto &a : admin::Admin::admins) {
        if (a.domain == url) {
            a.private_key = privkey;
            exists = true;
            break;
        }
    }
    if (!exists)
        admin::Admin::admins.push_back({url, privkey});
    admin::Admin::saveAdmins();

    emit adminStateChanged();
    emit adminConnected();
}

// ── Register User (admin action) ──────────────────────────────────────────────

void ClientBackend::registerUser(const QString &domain, const QString &username, const QString &pubkey)
{
    admin::Admin *found = nullptr;
    for (auto &a : admin::Admin::admins)
        if (a.domain == domain) { found = &a; break; }

    if (!found) {
        emit registerUserError("Нет прав администратора для этого сервера.");
        return;
    }

    found->regUser(username, pubkey).then([this](bool ok) {
        QMetaObject::invokeMethod(this, [this, ok]() {
            if (ok) emit userRegistered();
            else    emit registerUserError("Ошибка регистрации. Проверьте данные.");
        });
    });
}

// ── Dialogs Management ────────────────────────────────────────────────────────

void ClientBackend::addDialog(const QString &peer, const QString &sharedSecret)
{
    for (auto &d : m_dialogs) {
        if (d.peer == peer) {
            d.sessionKey = deriveKey(sharedSecret);
            emit dialogsChanged();
            return;
        }
    }
    m_dialogs.append({peer, deriveKey(sharedSecret), QString()});
    emit dialogsChanged();
}

void ClientBackend::removeDialog(const QString &peer)
{
    m_dialogs.removeIf([&peer](const Dialog &d) { return d.peer == peer; });
    m_messageCache.remove(peer);
    m_seenIds.remove(peer);
    emit dialogsChanged();
}

QVariantList ClientBackend::getDialogs() const
{
    QVariantList result;
    for (const auto &d : m_dialogs) {
        QVariantMap m;
        m["peer"]    = d.peer;
        m["lastMsg"] = d.lastMsg;
        result.append(m);
    }
    return result;
}

QVariantList ClientBackend::getAdminServers() const
{
    QVariantList result;
    for (const auto &a : admin::Admin::admins) {
        QVariantMap m;
        m["domain"] = a.domain;
        result.append(m);
    }
    return result;
}

// ── Chat ──────────────────────────────────────────────────────────────────────

void ClientBackend::openChat(const QString &peer)
{
    m_activePeer = peer;
    if (isLoggedIn() && findDialog(peer)) {
        fetchMessages();
        m_pollTimer->start();
    }
}

void ClientBackend::stopChat()
{
    m_pollTimer->stop();
    m_activePeer.clear();
}

void ClientBackend::sendText(const QString &text)
{
    if (m_activePeer.isEmpty()) {
        emit sendError("Нет активного диалога.");
        return;
    }
    auto *dlg = findDialog(m_activePeer);
    if (!dlg) {
        emit sendError("Диалог не найден.");
        return;
    }

    QString peer     = m_activePeer;
    QString username = m_username;
    QByteArray key   = dlg->sessionKey;

    QPointer<ClientBackend> self(this);
    QThreadPool::globalInstance()->start([self, peer, username, text, key]() {
        if (!self) return;
        QMutexLocker locker(&self->m_handleMutex);
        if (!self->m_handle) return;
        int res = paranoia_send_text(
            self->m_handle,
            username.toUtf8().constData(),
            peer.toUtf8().constData(),
            reinterpret_cast<const uint8_t *>(key.constData()),
            text.toUtf8().constData()
        );
        QMetaObject::invokeMethod(self, [self, res]() {
            if (!self) return;
            if (res == 0) self->fetchMessages();
            else          emit self->sendError("Ошибка отправки сообщения.");
        });
    });
}

void ClientBackend::fetchMessages()
{
    if (m_activePeer.isEmpty()) return;
    auto *dlg = findDialog(m_activePeer);
    if (!dlg) return;

    QString peer     = m_activePeer;
    QString username = m_username;
    QByteArray key   = dlg->sessionKey;

    QPointer<ClientBackend> self(this);
    QThreadPool::globalInstance()->start([self, peer, username, key]() {
        if (!self) return;
        QMutexLocker locker(&self->m_handleMutex);
        if (!self->m_handle) return;
        char *json = paranoia_receive(
            self->m_handle,
            username.toUtf8().constData(),
            peer.toUtf8().constData(),
            reinterpret_cast<const uint8_t *>(key.constData())
        );
        if (!json) return;
        QString jsonStr = QString::fromUtf8(json);
        paranoia_free_string(json);

        QMetaObject::invokeMethod(self, [self, jsonStr, peer]() {
            if (!self) return;
            auto newMsgs = self->parseMessages(jsonStr);
            if (newMsgs.isEmpty()) return;

            auto &cache = self->m_messageCache[peer];
            auto &seen  = self->m_seenIds[peer];
            for (const auto &msg : std::as_const(newMsgs)) {
                QString id = msg.toMap()["id"].toString();
                if (!seen.contains(id)) {
                    seen.insert(id);
                    cache.append(msg);
                }
            }

            for (auto &d : self->m_dialogs) {
                if (d.peer == peer) {
                    d.lastMsg = cache.last().toMap()["text"].toString();
                    break;
                }
            }

            emit self->messagesReceived(cache);
            emit self->dialogsChanged();
        });
    });
}

QVariantList ClientBackend::getCachedMessages(const QString &peer) const
{
    return m_messageCache.value(peer);
}

void ClientBackend::onPollTimer()
{
    fetchMessages();
}

// ── Helpers ───────────────────────────────────────────────────────────────────

QByteArray ClientBackend::deriveKey(const QString &sharedSecret) const
{
    return QCryptographicHash::hash(sharedSecret.toUtf8(), QCryptographicHash::Sha256);
}

QVariantList ClientBackend::parseMessages(const QString &json) const
{
    auto doc = QJsonDocument::fromJson(json.toUtf8());
    if (!doc.isArray()) return {};

    QVariantList result;
    for (const auto &val : doc.array()) {
        auto obj = val.toObject();
        QVariantMap msg;
        msg["id"]     = obj["id"].toString();
        msg["sender"] = obj["sender"].toString();
        msg["text"]   = extractText(obj["content"].toString());
        msg["ts"]     = obj["ts"].toVariant();
        msg["seq"]    = obj["seq"].toVariant();
        msg["isMe"]   = (obj["sender"].toString() == m_username);
        // Skip service messages (read receipts, deletes)
        if (!msg["text"].toString().isEmpty())
            result.append(msg);
    }
    return result;
}

QString ClientBackend::extractText(const QString &raw) const
{
    // Parse Rust Debug format: Text("hello") → hello
    if (raw.startsWith("Text(\"") && raw.endsWith("\")"))
        return raw.mid(6, raw.length() - 8);
    if (raw.startsWith("Image("))  return "[Изображение]";
    if (raw.startsWith("File("))   return "[Файл]";
    if (raw.startsWith("Voice("))  return "[Голосовое]";
    if (raw.startsWith("ReadReceipt(") || raw.startsWith("Delete("))
        return QString();
    return raw;
}

ClientBackend::Dialog *ClientBackend::findDialog(const QString &peer)
{
    for (auto &d : m_dialogs)
        if (d.peer == peer) return &d;
    return nullptr;
}
