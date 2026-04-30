#include "ClientBackend.h"
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <QCryptographicHash>
#include <QThreadPool>
#include <QPointer>
#include <QDebug>
#include <QFile>
#include <algorithm>

ClientBackend::ClientBackend(QObject *parent) : QObject(parent)
{
    m_pollTimer = new QTimer(this);
    m_pollTimer->setInterval(2500);
    connect(m_pollTimer, &QTimer::timeout, this, &ClientBackend::onPollTimer);
    loadDialogs();
    loadClientConfig();
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
        QMetaObject::invokeMethod(self, [self, handle, url, username, privkey]() {
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
                self->m_privkey  = privkey;
                emit self->loginStateChanged();
                self->saveClientConfig();
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
            saveDialogs();
            return;
        }
    }
    m_dialogs.append({peer, deriveKey(sharedSecret), QString()});
    emit dialogsChanged();
    saveDialogs();
}

void ClientBackend::updateDialogKey(const QString &peer, const QString &newSharedSecret)
{
    for (auto &d : m_dialogs) {
        if (d.peer == peer) {
            d.sessionKey = deriveKey(newSharedSecret);
            // Сбрасываем кэш — при новом ключе старые сообщения нечитаемы
            m_messageCache.remove(peer);
            m_seenIds.remove(peer);
            emit dialogsChanged();
            saveDialogs();
            return;
        }
    }
}

void ClientBackend::removeDialog(const QString &peer)
{
    m_dialogs.removeIf([&peer](const Dialog &d) { return d.peer == peer; });
    m_messageCache.remove(peer);
    m_seenIds.remove(peer);
    emit dialogsChanged();
    saveDialogs();
}

bool ClientBackend::hasDialogKey(const QString &peer) const
{
    const Dialog *dlg = findDialog(peer);
    return dlg != nullptr && dlg->sessionKey.size() == 32;
}

QVariantList ClientBackend::getDialogs() const
{
    QVariantList result;
    for (const auto &d : m_dialogs) {
        QVariantMap m;
        m["peer"]    = d.peer;
        m["lastMsg"] = d.lastMsg;
        m["hasKey"]  = (d.sessionKey.size() == 32);
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

// ── History Management ────────────────────────────────────────────────────────

void ClientBackend::deleteDialogLocal(const QString &peer)
{
    auto *dlg = findDialog(peer);
    if (!dlg) return;

    QString peerCopy = peer;
    QString username = m_username;
    QByteArray key   = dlg->sessionKey;

    QPointer<ClientBackend> self(this);
    QThreadPool::globalInstance()->start([self, peerCopy, username]() {
        if (!self) return;
        QMutexLocker locker(&self->m_handleMutex);
        if (!self->m_handle) return;
        int rc = paranoia_delete_local_dialogue(
            self->m_handle,
            username.toUtf8().constData(),
            peerCopy.toUtf8().constData()
        );
        QMetaObject::invokeMethod(self, [self, peerCopy, rc]() {
            if (!self) return;
            if (rc == 0) {
                self->m_messageCache.remove(peerCopy);
                self->m_seenIds.remove(peerCopy);
                emit self->dialogDeleted(peerCopy);
                emit self->messagesReceived({});
            } else {
                QString err = QString::fromUtf8(paranoia_last_error());
                emit self->serverHistoryError("Ошибка удаления локальной истории: " + err);
            }
        });
    });
}

void ClientBackend::clearServerHistory(const QString &peer, quint64 cutSeq)
{
    auto *dlg = findDialog(peer);
    if (!dlg) {
        emit serverHistoryError("Диалог не найден.");
        return;
    }

    QString peerCopy = peer;
    QString username = m_username;
    QByteArray key   = dlg->sessionKey;

    QPointer<ClientBackend> self(this);
    QThreadPool::globalInstance()->start([self, peerCopy, username, key, cutSeq]() {
        if (!self) return;
        QMutexLocker locker(&self->m_handleMutex);
        if (!self->m_handle) return;
        int rc = paranoia_determinate(
            self->m_handle,
            username.toUtf8().constData(),
            peerCopy.toUtf8().constData(),
            reinterpret_cast<const uint8_t *>(key.constData()),
            cutSeq
        );
        QMetaObject::invokeMethod(self, [self, peerCopy, rc]() {
            if (!self) return;
            if (rc == 0) {
                emit self->serverHistoryCleared(peerCopy);
            } else {
                QString err = QString::fromUtf8(paranoia_last_error());
                if (err == "server_unavailable")
                    emit self->serverHistoryError("Сервер недоступен.");
                else
                    emit self->serverHistoryError("Ошибка удаления серверной истории: " + err);
            }
        });
    });
}

// ── Chat ──────────────────────────────────────────────────────────────────────

void ClientBackend::openChat(const QString &peer)
{
    m_activePeer = peer;
    if (isLoggedIn() && findDialog(peer)) {
        loadHistory(peer);
        m_pollTimer->start();
        fetchMessages();
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
        char *json = paranoia_send_text_json(
            self->m_handle,
            username.toUtf8().constData(),
            peer.toUtf8().constData(),
            reinterpret_cast<const uint8_t *>(key.constData()),
            text.toUtf8().constData()
        );
        if (!json) {
            QString err = QString::fromUtf8(paranoia_last_error());
            QMetaObject::invokeMethod(self, [self, err]() {
                if (!self) return;
                if (err == "duplicate_seq")
                    emit self->sendError("Ошибка синхронизации: дублирующийся номер пакета. Перезайдите.");
                else if (err == "server_unavailable")
                    emit self->sendError("Сервер недоступен. Проверьте соединение.");
                else
                    emit self->sendError("Ошибка отправки сообщения.");
            });
            return;
        }
        QString jsonStr = QString::fromUtf8(json);
        paranoia_free_string(json);
        QMetaObject::invokeMethod(self, [self, peer, jsonStr]() {
            if (!self) return;
            self->appendMessages(peer, self->parseMessages(jsonStr));
            self->fetchMessages();
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

        // Проверяем на ошибки расшифровки даже при успешном получении
        QString lastErr = QString::fromUtf8(paranoia_last_error());

        if (!json) {
            QMetaObject::invokeMethod(self, [self, lastErr]() {
                if (!self) return;
                if (lastErr == "server_unavailable")
                    emit self->receiveError("Сервер недоступен.");
                else if (!lastErr.isEmpty())
                    emit self->receiveError("Ошибка получения: " + lastErr);
            });
            return;
        }

        QString jsonStr = QString::fromUtf8(json);
        paranoia_free_string(json);

        QMetaObject::invokeMethod(self, [self, jsonStr, peer, lastErr]() {
            if (!self) return;
            if (lastErr.startsWith("decryption_failed:")) {
                emit self->receiveError("Ошибка расшифровки: неверный ключ диалога или повреждённые данные.");
            }
            self->appendMessages(peer, self->parseMessages(jsonStr));
        });
    });
}

QVariantList ClientBackend::getCachedMessages(const QString &peer) const
{
    return m_messageCache.value(peer);
}

void ClientBackend::loadHistory(const QString &peer)
{
    auto *dlg = findDialog(peer);
    if (!dlg) return;

    QString username = m_username;
    QByteArray key = dlg->sessionKey;
    QPointer<ClientBackend> self(this);
    QThreadPool::globalInstance()->start([self, peer, username, key]() {
        if (!self) return;
        QMutexLocker locker(&self->m_handleMutex);
        if (!self->m_handle) return;
        char *json = paranoia_history(
            self->m_handle,
            username.toUtf8().constData(),
            peer.toUtf8().constData(),
            reinterpret_cast<const uint8_t *>(key.constData()),
            500
        );
        if (!json) return;
        QString jsonStr = QString::fromUtf8(json);
        paranoia_free_string(json);
        QMetaObject::invokeMethod(self, [self, peer, jsonStr]() {
            if (!self) return;
            self->m_messageCache[peer].clear();
            self->m_seenIds[peer].clear();
            self->appendMessages(peer, self->parseMessages(jsonStr));
        });
    });
}

void ClientBackend::appendMessages(const QString &peer, const QVariantList &messages)
{
    if (messages.isEmpty()) return;

    auto &cache = m_messageCache[peer];
    auto &seen = m_seenIds[peer];
    for (const auto &msg : messages) {
        QString id = msg.toMap()["id"].toString();
        if (!id.isEmpty() && !seen.contains(id)) {
            seen.insert(id);
            cache.append(msg);
        }
    }

    std::sort(cache.begin(), cache.end(), [](const QVariant &lhs, const QVariant &rhs) {
        return lhs.toMap()["ts"].toLongLong() < rhs.toMap()["ts"].toLongLong();
    });

    if (!cache.isEmpty()) {
        for (auto &d : m_dialogs) {
            if (d.peer == peer) {
                d.lastMsg = cache.last().toMap()["text"].toString();
                break;
            }
        }
    }

    saveDialogs();
    emit messagesReceived(cache);
    emit dialogsChanged();
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
        // Пропускаем служебные сообщения (подтверждения прочтения, удаления)
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

// ── Persistence ───────────────────────────────────────────────────────────────

void ClientBackend::saveClientConfig() const
{
    QFile f("client.json");
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) return;
    QJsonObject obj;
    obj["server"]   = m_server;
    obj["username"] = m_username;
    obj["privkey"]  = m_privkey;
    f.write(QJsonDocument(obj).toJson());
}

void ClientBackend::loadClientConfig()
{
    QFile f("client.json");
    if (!f.open(QIODevice::ReadOnly)) return;
    auto doc = QJsonDocument::fromJson(f.readAll());
    if (!doc.isObject()) return;
    auto obj = doc.object();
    QString server   = obj["server"].toString();
    QString username = obj["username"].toString();
    QString privkey  = obj["privkey"].toString();
    if (server.isEmpty() || username.isEmpty() || privkey.isEmpty()) return;
    loginClient(server, username, privkey);
}

void ClientBackend::saveDialogs() const
{
    QJsonArray arr;
    for (const auto &d : m_dialogs) {
        QJsonObject o;
        o["peer"] = d.peer;
        o["key"]  = QString::fromLatin1(d.sessionKey.toBase64());
        o["lastMsg"] = d.lastMsg;
        arr.append(QJsonValue(o));
    }
    QFile f("dialogs.json");
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) return;
    f.write(QJsonDocument(arr).toJson());
}

void ClientBackend::loadDialogs()
{
    QFile f("dialogs.json");
    if (!f.open(QIODevice::ReadOnly)) return;
    auto doc = QJsonDocument::fromJson(f.readAll());
    if (!doc.isArray()) return;
    const QJsonArray jsonArr = doc.array();
    for (const auto &val : jsonArr) {
        auto obj = val.toObject();
        QString peer   = obj["peer"].toString();
        QByteArray key = QByteArray::fromBase64(obj["key"].toString().toLatin1());
        QString lastMsg = obj["lastMsg"].toString();
        if (!peer.isEmpty() && key.size() == 32)
            m_dialogs.append({peer, key, lastMsg});
    }
}

ClientBackend::Dialog *ClientBackend::findDialog(const QString &peer)
{
    for (auto &d : m_dialogs)
        if (d.peer == peer) return &d;
    return nullptr;
}

const ClientBackend::Dialog *ClientBackend::findDialog(const QString &peer) const
{
    for (const auto &d : m_dialogs)
        if (d.peer == peer) return &d;
    return nullptr;
}
