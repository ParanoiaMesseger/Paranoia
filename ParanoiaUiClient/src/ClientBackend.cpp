#include "ClientBackend.h"

#include "Utils.hpp"

#include <QJsonArray>
#include <QJsonObject>
#include <QJsonParseError>
#include <QCryptographicHash>
#include <QThreadPool>
#include <QPointer>
#include <QDebug>
#include <QDir>
#include <QFileInfo>
#include <algorithm>

ClientBackend::ClientBackend(QObject *parent) : QObject(parent)
{
    m_pollTimer = new QTimer(this);
    m_pollTimer->setInterval(2500);
    connect(m_pollTimer, &QTimer::timeout, this, &ClientBackend::onPollTimer);
    loadDeviceKey();
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

bool ClientBackend::hasAdminAccess() const { return !admin::Admin::admins.empty(); }

QString ClientBackend::devicePubkey() const
{
    if (m_devicePrivkey.isEmpty()) return {};
    char *pub = paranoia_ecies_pubkey(m_devicePrivkey.toUtf8().constData());
    if (!pub) return {};
    QString result = QString::fromUtf8(pub);
    paranoia_free_string(pub);
    return result;
}

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
        QMetaObject::invokeMethod(this,
                                  [this, pubkeyStr, secretStr]() { emit keyPairGenerated(pubkeyStr, secretStr); });
    });
}

// ── Client Login ──────────────────────────────────────────────────────────────

void ClientBackend::loginClient(const QString &server, const QString &username, const QString &private_key)
{
    const QString url             = Utils::normalizedServerUrl(server);
    const QString trimmedUsername = username.trimmed();
    const QString profileId       = Utils::profileIdFor(url, trimmedUsername);
    if (!Utils::ensureProfileDir(profileId)) {
        emit loginError("Не удалось подготовить каталог профиля.");
        return;
    }
    const QString dbPath = Utils::profileDbPath(profileId);

    QPointer self(this);
    QThreadPool::globalInstance()->start([self, url, trimmedUsername, private_key, dbPath, profileId]() {
        auto *handle = paranoia_client_new(url.toUtf8().constData(), trimmedUsername.toUtf8().constData(),
                                           private_key.toUtf8().constData(), dbPath.toUtf8().constData());
        QMetaObject::invokeMethod(self, [self, handle, url, trimmedUsername, private_key, profileId]() {
            if (!self) {
                if (handle) paranoia_client_free(handle);
                return;
            }
            {
                QMutexLocker locker(&self->m_handleMutex);
                if (self->m_handle) { paranoia_client_free(self->m_handle); }
                self->m_handle = handle;
            }
            if (handle) {
                self->m_server      = url;
                self->m_username    = trimmedUsername;
                self->m_private_key = private_key;
                self->m_profileId   = profileId;
                self->m_activePeer.clear();
                self->m_messageCache.clear();
                self->m_seenIds.clear();
                self->loadDialogs();
                emit self->loginStateChanged();
                emit self->dialogsChanged();
                self->saveClientConfig();
            } else {
                emit self->loginError("Не удалось подключиться. Проверьте адрес сервера и ключ.");
            }
        });
    });
}

// ── Register User (admin action) ──────────────────────────────────────────────

void ClientBackend::registerUser(const QString &domain, const QString &username, const QString &pubkey)
{
    const admin::Admin *found = nullptr;
    for (auto &a : admin::Admin::admins)
        if (a.domain == domain) {
            found = &a;
            break;
        }

    if (!found) {
        emit registerUserError("Нет прав администратора для этого сервера.");
        return;
    }

    found->regUser(username, pubkey).then([this](bool ok) {
        QMetaObject::invokeMethod(this, [this, ok]() {
            if (ok)
                emit userRegistered();
            else
                emit registerUserError("Ошибка регистрации. Проверьте данные.");
        });
    });
}

// ── Dialogs Management ────────────────────────────────────────────────────────

void ClientBackend::addDialog(const QString &peer, const QString &sharedSecret)
{ upsertDialogKeyringEntry(peer.trimmed(), deriveKey(sharedSecret), 1, true, false); }

void ClientBackend::updateDialogKey(const QString &peer, const QString &newSharedSecret)
{
    const QString trimmedPeer = peer.trimmed();
    upsertDialogKeyringEntry(trimmedPeer, deriveKey(newSharedSecret), nextKeyStartSeq(trimmedPeer), false, false);
}

QVariantMap ClientBackend::createDialogKeyInvitation(const QString &peer) const
{
    const QString trimmedPeer = peer.trimmed();
    if (m_username.isEmpty() || trimmedPeer.isEmpty())
        return Utils::errorResult("Не указан пользователь или собеседник.");

    const QString bundleJson = Utils::takeRustString(
        paranoia_qr_create_invitation(m_username.toUtf8().constData(), trimmedPeer.toUtf8().constData()));
    if (bundleJson.isEmpty()) return Utils::lastRustErrorResult();

    const auto doc = QJsonDocument::fromJson(bundleJson.toUtf8());
    if (!doc.isObject()) return Utils::errorResult("Некорректный JSON invitation.");
    const auto obj            = doc.object();
    const QString stateJson   = Utils::compactJson(obj.value("state"));
    const QString payloadJson = Utils::compactJson(obj.value("payload"));
    if (stateJson.isEmpty() || payloadJson.isEmpty()) return Utils::errorResult("Некорректный JSON invitation.");
    return QVariantMap{
        {"ok", true},
        {"peer", trimmedPeer},
        {"stateJson", stateJson},
        {"payloadJson", payloadJson},
    };
}

QVariantMap ClientBackend::createDialogKeyResponse(const QString &invitationPayloadJson)
{
    if (m_username.isEmpty() || invitationPayloadJson.trimmed().isEmpty())
        return Utils::errorResult("Нет invitation payload или имени пользователя.");
    const QString bundleJson = Utils::takeRustString(
        paranoia_qr_create_response(invitationPayloadJson.toUtf8().constData(), m_username.toUtf8().constData()));
    if (bundleJson.isEmpty()) { return Utils::lastRustErrorResult(); }
    const auto doc = QJsonDocument::fromJson(bundleJson.toUtf8());
    if (!doc.isObject()) { return Utils::errorResult("Некорректный JSON response."); }
    const auto obj            = doc.object();
    const QString stateJson   = Utils::compactJson(obj.value("state"));
    const QString payloadJson = Utils::compactJson(obj.value("payload"));
    if (stateJson.isEmpty() || payloadJson.isEmpty()) return Utils::errorResult("Некорректный JSON response.");
    QVariantMap fingerprint = dialogKeyFingerprint(stateJson, invitationPayloadJson);
    if (!fingerprint.value("ok").toBool()) return fingerprint;
    return QVariantMap{
        {"ok", true},
        {"stateJson", stateJson},
        {"payloadJson", payloadJson},
        {"fingerprint", fingerprint.value("fingerprint").toString()},
    };
}

QVariantMap ClientBackend::dialogKeyFingerprint(const QString &localStateJson, const QString &peerPayloadJson)
{
    if (localStateJson.trimmed().isEmpty() || peerPayloadJson.trimmed().isEmpty())
        return Utils::errorResult("Нет state или payload для расчёта SAS.");
    const QString fingerprint = Utils::takeRustString(
        paranoia_qr_fingerprint(localStateJson.toUtf8().constData(), peerPayloadJson.toUtf8().constData()));
    if (fingerprint.isEmpty()) return Utils::lastRustErrorResult();
    return QVariantMap{{"ok", true}, {"fingerprint", fingerprint}};
}

QVariantMap ClientBackend::confirmDialogKeyExchange(const QString &peer, const QString &localStateJson,
                                                    const QString &peerPayloadJson, const QString &fingerprint,
                                                    const bool updateExisting)
{
    const QString trimmedPeer = peer.trimmed();
    if (trimmedPeer.isEmpty()) return Utils::errorResult("Не указан собеседник.");
    const QString completedJson = Utils::takeRustString(paranoia_qr_confirm_exchange(
        localStateJson.toUtf8().constData(), peerPayloadJson.toUtf8().constData(), fingerprint.toUtf8().constData()));
    if (completedJson.isEmpty()) return Utils::lastRustErrorResult();

    const auto doc = QJsonDocument::fromJson(completedJson.toUtf8());
    if (!doc.isObject()) return Utils::errorResult("Некорректный JSON завершения обмена.");
    const QByteArray sessionKey = QByteArray::fromBase64(doc.object().value("session_key_b64").toString().toLatin1());
    if (sessionKey.size() != 32) return Utils::errorResult("Некорректный ключ диалога.");
    upsertDialogKeyringEntry(trimmedPeer, sessionKey, updateExisting ? nextKeyStartSeq(trimmedPeer) : 1,
                             !updateExisting, false);
    return QVariantMap{
        {"ok", true},
        {"peer", trimmedPeer},
        {"fingerprint", doc.object().value("fingerprint").toString()},
    };
}

void ClientBackend::removeDialog(const QString &peer)
{
    m_dialogs.removeIf([&peer](const Dialog &d) { return d.peer == peer; });
    m_messageCache.remove(peer);
    m_seenIds.remove(peer);
    emit dialogsChanged();
    saveDialogs();
}

QVariantList ClientBackend::getDialogs() const
{
    QVariantList result;
    for (const auto &[peer, keyring, lastMsg] : m_dialogs)
        result.append(QVariantMap{{"peer", peer}, {"lastMsg", lastMsg}, {"hasKey", !keyring.isEmpty()}});
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

    QPointer<ClientBackend> self(this);
    QThreadPool::globalInstance()->start([self, peerCopy, username]() {
        if (!self) return;
        QMutexLocker locker(&self->m_handleMutex);
        if (!self->m_handle) return;
        int rc = paranoia_delete_local_dialogue(self->m_handle, username.toUtf8().constData(),
                                                peerCopy.toUtf8().constData());
        QMetaObject::invokeMethod(self, [self, peerCopy, rc]() {
            if (!self) return;
            if (rc == 0) {
                self->m_messageCache.remove(peerCopy);
                self->m_seenIds.remove(peerCopy);
                emit self->dialogDeleted(peerCopy);
                emit self->messagesReceived({});
            } else {
                const QString err = QString::fromUtf8(paranoia_last_error());
                emit self->serverHistoryError("Ошибка удаления локальной истории: " + err);
            }
        });
    });
}

void ClientBackend::clearServerHistory(const QString &peer, quint64 cutSeq)
{
    const auto *dlg = findDialog(peer);
    if (!dlg) {
        emit serverHistoryError("Диалог не найден.");
        return;
    }

    QString peerCopy    = peer;
    QString username    = m_username;
    QString keyringJson = dialogKeyringJson(*dlg);

    QPointer<ClientBackend> self(this);
    QThreadPool::globalInstance()->start([self, peerCopy, username, keyringJson, cutSeq]() {
        if (!self) return;
        QMutexLocker locker(&self->m_handleMutex);
        if (!self->m_handle) return;
        int rc = paranoia_determinate_keyring(self->m_handle, username.toUtf8().constData(),
                                              peerCopy.toUtf8().constData(), keyringJson.toUtf8().constData(), cutSeq);
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

    QString peer        = m_activePeer;
    QString username    = m_username;
    QString keyringJson = dialogKeyringJson(*dlg);

    QPointer<ClientBackend> self(this);
    QThreadPool::globalInstance()->start([self, peer, username, text, keyringJson]() {
        if (!self) return;
        QMutexLocker locker(&self->m_handleMutex);
        if (!self->m_handle) return;
        char *json =
            paranoia_send_text_json_keyring(self->m_handle, username.toUtf8().constData(), peer.toUtf8().constData(),
                                            keyringJson.toUtf8().constData(), text.toUtf8().constData());
        if (!json) {
            QString err = QString::fromUtf8(paranoia_last_error());
            QMetaObject::invokeMethod(self, [self, err]() {
                if (!self) return;
                if (err == "duplicate_seq" || err == "invalid_seq")
                    emit self->sendError("Ошибка синхронизации seq. Повторите отправку после обновления диалога.");
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
    const auto *dlg = findDialog(m_activePeer);
    if (!dlg) return;

    QString peer        = m_activePeer;
    QString username    = m_username;
    QString keyringJson = dialogKeyringJson(*dlg);

    QPointer<ClientBackend> self(this);
    QThreadPool::globalInstance()->start([self, peer, username, keyringJson]() {
        if (!self) return;
        QMutexLocker locker(&self->m_handleMutex);
        if (!self->m_handle) return;
        char *json = paranoia_receive_keyring(self->m_handle, username.toUtf8().constData(), peer.toUtf8().constData(),
                                              keyringJson.toUtf8().constData());

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

void ClientBackend::loadHistory(const QString &peer)
{
    const auto *dlg = findDialog(peer);
    if (!dlg) return;

    QString username    = m_username;
    QString keyringJson = dialogKeyringJson(*dlg);
    QPointer<ClientBackend> self(this);
    QThreadPool::globalInstance()->start([self, peer, username, keyringJson]() {
        if (!self) return;
        QMutexLocker locker(&self->m_handleMutex);
        if (!self->m_handle) return;
        char *json = paranoia_history_keyring(self->m_handle, username.toUtf8().constData(), peer.toUtf8().constData(),
                                              keyringJson.toUtf8().constData(), 500);
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
    auto &seen  = m_seenIds[peer];
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

void ClientBackend::upsertDialogKeyringEntry(const QString &peer, const QByteArray &sessionKey, quint64 startSeq,
                                             bool resetKeyring, bool clearCache)
{
    if (peer.isEmpty() || sessionKey.size() != 32 || startSeq == 0) return;

    for (auto &d : m_dialogs) {
        if (d.peer == peer) {
            if (resetKeyring) { d.keyring.clear(); }
            bool replaced = false;
            for (auto &entry : d.keyring) {
                if (entry.startSeq == startSeq) {
                    entry.key = sessionKey;
                    replaced  = true;
                    break;
                }
            }
            if (!replaced) { d.keyring.append({startSeq, sessionKey}); }
            std::sort(d.keyring.begin(), d.keyring.end(),
                      [](const DialogKeyEntry &lhs, const DialogKeyEntry &rhs) { return lhs.startSeq < rhs.startSeq; });
            if (clearCache) {
                m_messageCache.remove(peer);
                m_seenIds.remove(peer);
            }
            emit dialogsChanged();
            saveDialogs();
            return;
        }
    }

    m_dialogs.append({peer, QList<DialogKeyEntry>{{startSeq, sessionKey}}, QString()});
    emit dialogsChanged();
    saveDialogs();
}

void ClientBackend::onPollTimer() { fetchMessages(); }

// ── Helpers ───────────────────────────────────────────────────────────────────

QByteArray ClientBackend::deriveKey(const QString &sharedSecret) const
{ return QCryptographicHash::hash(sharedSecret.toUtf8(), QCryptographicHash::Sha256); }

QString ClientBackend::dialogKeyringJson(const Dialog &dialog) const
{
    QJsonArray arr;
    for (const auto &entry : dialog.keyring) {
        if (entry.key.size() != 32 || entry.startSeq == 0) continue;
        QJsonObject obj;
        obj["start_seq"] = static_cast<double>(entry.startSeq);
        obj["key"]       = QString::fromLatin1(entry.key.toBase64());
        arr.append(obj);
    }
    return QString::fromUtf8(QJsonDocument(arr).toJson(QJsonDocument::Compact));
}

quint64 ClientBackend::nextKeyStartSeq(const QString &peer) const
{
    quint64 maxSeq = 0;
    for (const auto &msg : m_messageCache.value(peer)) {
        bool ok     = false;
        quint64 seq = msg.toMap().value("seq").toULongLong(&ok);
        if (ok && seq > maxSeq) maxSeq = seq;
    }

    QMutexLocker locker(&m_handleMutex);
    if (m_handle) {
        uint64_t lastPulled = 0;
        int rc =
            paranoia_last_pulled_seq(m_handle, m_username.toUtf8().constData(), peer.toUtf8().constData(), &lastPulled);
        if (rc == 0 && lastPulled > maxSeq) maxSeq = static_cast<quint64>(lastPulled);
    }

    return maxSeq + 1;
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
        if (!msg["text"].toString().isEmpty()) result.append(msg);
    }
    return result;
}

QString ClientBackend::extractText(const QString &raw) const
{
    // Parse Rust Debug format: Text("hello") → hello
    if (raw.startsWith("Text(\"") && raw.endsWith("\")")) return raw.mid(6, raw.length() - 8);
    if (raw.startsWith("Image(")) return "[Изображение]";
    if (raw.startsWith("File(")) return "[Файл]";
    if (raw.startsWith("Voice(")) return "[Голосовое]";
    if (raw.startsWith("ReadReceipt(") || raw.startsWith("Delete(")) return QString();
    return raw;
}

// ── Export / Import ───────────────────────────────────────────────────────────

QVariantMap ClientBackend::exportProfile(const QString &profileType, const QStringList &peers,
                                         const QString &receiverPubkeyB64, const QString &filePath)
{
    const QString normalizedProfile = profileType.trimmed();
    if (!Utils::isSupportedExportProfile(normalizedProfile))
        return Utils::errorResult("Неподдерживаемый тип профиля экспорта.");
    if (receiverPubkeyB64.trimmed().isEmpty())
        return Utils::errorResult("Не указан публичный ключ принимающего устройства.");
    if (filePath.trimmed().isEmpty()) return Utils::errorResult("Не указан путь к файлу.");

    // Собрать payload
    QJsonObject payload;
    payload["format_version"] = 1;
    payload["profile_type"]   = normalizedProfile;

    const bool includeClient = (normalizedProfile == "client" || normalizedProfile == "full");
    const bool includeAdmin  = (normalizedProfile == "admin" || normalizedProfile == "full");
    int exportedDialogues    = 0;
    int exportedKeyEntries   = 0;

    if (includeClient) {
        if (m_server.isEmpty() || m_username.isEmpty() || m_private_key.isEmpty())
            return Utils::errorResult("Нет активной клиентской сессии для экспорта.");

        QJsonArray dialoguesArr;
        for (const auto &dlg : m_dialogs) {
            if (!peers.isEmpty() && !peers.contains(dlg.peer)) continue;
            if (dlg.keyring.isEmpty()) continue;
            QJsonObject dlgObj;
            dlgObj["peer"] = dlg.peer;
            QJsonArray keyringArr;
            for (const auto &entry : dlg.keyring) {
                if (entry.key.size() != 32 || entry.startSeq == 0) continue;
                QJsonObject keyObj;
                keyObj["start_seq"] = static_cast<double>(entry.startSeq);
                keyObj["key"]       = QString::fromLatin1(entry.key.toBase64());
                keyringArr.append(keyObj);
            }
            if (keyringArr.isEmpty()) continue;
            dlgObj["keyring"] = keyringArr;
            dialoguesArr.append(dlgObj);
            ++exportedDialogues;
            exportedKeyEntries += keyringArr.size();
        }

        if (!peers.isEmpty() && exportedDialogues == 0)
            return Utils::errorResult("Нет выбранных диалогов с keyring для экспорта.");

        QJsonObject serverObj;
        serverObj["url"]             = m_server;
        serverObj["username"]        = m_username;
        serverObj["signing_key_b64"] = m_private_key;
        serverObj["dialogues"]       = dialoguesArr;

        payload["servers"] = QJsonArray{serverObj};
    }

    if (includeAdmin) {
        QJsonArray adminArr;
        for (const auto &a : admin::Admin::admins) {
            QJsonObject adminObj;
            adminObj["url"]                   = a.domain;
            adminObj["admin_private_key_b64"] = a.private_key;
            adminArr.append(adminObj);
        }
        payload["admin_servers"] = adminArr;
    }

    if (!includeClient) payload["servers"] = QJsonArray{};
    if (!includeAdmin) payload["admin_servers"] = QJsonArray{};

    const QString payloadJson = QString::fromUtf8(QJsonDocument(payload).toJson(QJsonDocument::Compact));

    // Зашифровать
    char *envelopePtr =
        paranoia_ecies_encrypt(receiverPubkeyB64.trimmed().toUtf8().constData(), payloadJson.toUtf8().constData());
    if (!envelopePtr) {
        const QString err = Utils::lastRustError();
        if (err == "invalid_device_key")
            return Utils::errorResult("Некорректный публичный ключ принимающего устройства.");
        return Utils::errorResult("Ошибка шифрования экспорта.");
    }
    const QString envelopeJson = Utils::takeRustString(envelopePtr);

    // Сохранить в файл
    QFile file(filePath);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate))
        return Utils::errorResult("Не удалось открыть файл для записи: " + filePath);
    const QByteArray envelopeBytes = envelopeJson.toUtf8();
    if (file.write(envelopeBytes) != envelopeBytes.size()) {
        file.close();
        return Utils::errorResult("Не удалось полностью записать файл экспорта.");
    }
    file.close();
    Utils::setOwnerOnlyPermissions(filePath);

    return QVariantMap{
        {"ok", true},
        {"path", filePath},
        {"dialogues", exportedDialogues},
        {"keyEntries", exportedKeyEntries},
    };
}

QVariantMap ClientBackend::importProfile(const QString &filePath)
{
    if (m_devicePrivkey.isEmpty()) return Utils::errorResult("Device keypair не инициализирован.");
    if (filePath.trimmed().isEmpty()) return Utils::errorResult("Не указан путь к файлу.");

    QFile file(filePath);
    if (!file.open(QIODevice::ReadOnly)) return Utils::errorResult("Не удалось открыть файл: " + filePath);
    if (file.size() > Utils::MaxExportFileBytes) {
        file.close();
        return Utils::errorResult("Файл экспорта слишком большой.");
    }
    const QString envelopeJson = QString::fromUtf8(file.readAll());
    file.close();

    if (envelopeJson.trimmed().isEmpty()) return Utils::errorResult("Файл пуст.");

    // Расшифровать
    char *plaintextPtr =
        paranoia_ecies_decrypt(m_devicePrivkey.toUtf8().constData(), envelopeJson.toUtf8().constData());
    if (!plaintextPtr) {
        const QString err = Utils::lastRustError();
        if (err == "ecies_decrypt_error")
            return Utils::errorResult("Не удалось расшифровать файл. Файл зашифрован на другой ключ или повреждён.");
        if (err == "ecies_unsupported_version") return Utils::errorResult("Неподдерживаемая версия формата экспорта.");
        return Utils::errorResult("Ошибка расшифровки.");
    }
    const QString payloadJson = Utils::takeRustString(plaintextPtr);

    QJsonParseError parseError;
    const auto doc = QJsonDocument::fromJson(payloadJson.toUtf8(), &parseError);
    if (parseError.error != QJsonParseError::NoError || !doc.isObject())
        return Utils::errorResult("Некорректный формат payload после расшифровки.");

    const auto payload = doc.object();
    if (payload["format_version"].toInt() != 1) return Utils::errorResult("Неподдерживаемая версия формата payload.");
    const QString profileType = payload["profile_type"].toString();
    if (!Utils::isSupportedExportProfile(profileType))
        return Utils::errorResult("Неподдерживаемый тип профиля в payload.");
    const bool allowClientImport = (profileType == "client" || profileType == "full");
    const bool allowAdminImport  = (profileType == "admin" || profileType == "full");

    int importedDialogues    = 0;
    int importedKeyEntries   = 0;
    int importedAdminServers = 0;
    int skippedEntries       = 0;
    int conflicts            = 0;
    int importedProfiles     = 0;
    QString activateServer;
    QString activateUsername;
    QString activatePrivkey;

    const auto mergeKeyringEntry = [](QList<Dialog> &dialogs, const QString &peer, const QByteArray &key,
                                      quint64 startSeq) -> int {
        for (auto &dlg : dialogs) {
            if (dlg.peer != peer) continue;
            for (const auto &entry : dlg.keyring) {
                if (entry.startSeq != startSeq) continue;
                return entry.key == key ? 0 : -1;
            }
            dlg.keyring.append({startSeq, key});
            std::sort(dlg.keyring.begin(), dlg.keyring.end(),
                      [](const DialogKeyEntry &lhs, const DialogKeyEntry &rhs) { return lhs.startSeq < rhs.startSeq; });
            return 1;
        }
        dialogs.append({peer, QList<DialogKeyEntry>{{startSeq, key}}, QString()});
        return 1;
    };

    // Импорт client-данных: merge по server+username+peer+start_seq (Z2a)
    if (allowClientImport) {
        const QJsonArray servers = payload["servers"].toArray();
        if (servers.size() > Utils::MaxImportServers)
            return Utils::errorResult("Слишком много client-профилей в export payload.");
        int totalDialogues  = 0;
        int totalKeyEntries = 0;
        for (const auto &serverVal : servers) {
            const auto serverObj     = serverVal.toObject();
            const QString url        = Utils::normalizedServerUrl(serverObj["url"].toString());
            const QString username   = serverObj["username"].toString().trimmed();
            const QString signingKey = serverObj["signing_key_b64"].toString().trimmed();
            if (url.isEmpty() || username.isEmpty()) continue;
            if (!Utils::decodeFixedBase64(signingKey, 32))
                return Utils::errorResult("Некорректный private signing key в client-профиле export payload.");

            const QString profileId    = Utils::profileIdFor(url, username);
            const bool isCurrentClient = (profileId == m_profileId);
            const bool profileExists   = QFile::exists(Utils::profileClientPath(profileId));
            if (profileExists) {
                const QJsonObject existing = Utils::readJsonObjectFile(Utils::profileClientPath(profileId));
                const QString existingKey  = existing.value("private_key").toString().trimmed();
                if (!existingKey.isEmpty() && existingKey != signingKey) {
                    ++conflicts;
                    continue;
                }
            }

            QList<Dialog> targetDialogs =
                isCurrentClient ? m_dialogs : loadDialogsFromPath(Utils::profileDialogsPath(profileId));
            QSet<QString> touchedDialogues;

            const QJsonArray dialogues = serverObj["dialogues"].toArray();
            if (totalDialogues + dialogues.size() > Utils::MaxImportDialogues)
                return Utils::errorResult("Слишком много диалогов в export payload.");
            totalDialogues += dialogues.size();

            for (const auto &dlgVal : dialogues) {
                const auto dlgObj  = dlgVal.toObject();
                const QString peer = dlgObj["peer"].toString();
                if (peer.isEmpty()) {
                    ++skippedEntries;
                    continue;
                }

                const QJsonArray keyringArr = dlgObj["keyring"].toArray();
                if (keyringArr.isEmpty()) {
                    ++skippedEntries;
                    continue;
                }
                if (totalKeyEntries + keyringArr.size() > Utils::MaxImportKeyEntries)
                    return Utils::errorResult("Слишком много keyring entries в export payload.");
                totalKeyEntries += keyringArr.size();

                for (const auto &keyVal : keyringArr) {
                    const auto keyObj      = keyVal.toObject();
                    bool seqOk             = false;
                    const quint64 startSeq = Utils::readSeq(keyObj["start_seq"], &seqOk);
                    QByteArray key;
                    if (!seqOk || !Utils::decodeFixedBase64(keyObj["key"].toString(), 32, &key)) {
                        ++skippedEntries;
                        continue;
                    }

                    const int mergeResult = mergeKeyringEntry(targetDialogs, peer, key, startSeq);
                    if (mergeResult < 0) {
                        ++conflicts;
                        continue;
                    }
                    if (mergeResult == 0) {
                        ++skippedEntries;
                        continue;
                    }
                    ++importedKeyEntries;
                    if (!touchedDialogues.contains(peer)) {
                        touchedDialogues.insert(peer);
                        ++importedDialogues;
                    }
                }
            }

            saveClientConfigForProfile(profileId, url, username, signingKey);
            saveDialogsToPath(Utils::profileDialogsPath(profileId), targetDialogs);
            Utils::upsertProfileManifest(profileId, url, username, isCurrentClient || m_profileId.isEmpty());
            if (!profileExists) ++importedProfiles;
            if (m_profileId.isEmpty() && activatePrivkey.isEmpty()) {
                activateServer   = url;
                activateUsername = username;
                activatePrivkey  = signingKey;
            }
            if (isCurrentClient) {
                m_dialogs = targetDialogs;
                m_messageCache.clear();
                m_seenIds.clear();
                emit dialogsChanged();
            }
        }
    }

    // Импорт admin-данных
    if (allowAdminImport) {
        const QJsonArray adminServers = payload["admin_servers"].toArray();
        if (adminServers.size() > Utils::MaxImportAdminServers)
            return Utils::errorResult("Слишком много admin-профилей в export payload.");
        for (const auto &adminVal : adminServers) {
            const auto adminObj       = adminVal.toObject();
            const QString url         = Utils::normalizedServerUrl(adminObj["url"].toString());
            const QString private_key = adminObj["admin_private_key_b64"].toString().trimmed();
            if (url.isEmpty() || private_key.isEmpty()) continue;
            if (!Utils::decodeFixedBase64(private_key, 32))
                return Utils::errorResult("Некорректный private admin key в export payload.");
            bool found = false;
            for (auto &a : admin::Admin::admins)
                if (a.domain == url) {
                    found = true;
                    break;
                }
            if (!found) {
                admin::Admin::admins.push_back({url, private_key});
                ++importedAdminServers;
            }
        }
    }

    if (importedAdminServers > 0) {
        admin::Admin::saveAdmins();
        emit adminStateChanged();
    }

    if (!activatePrivkey.isEmpty()) loginClient(activateServer, activateUsername, activatePrivkey);

    return QVariantMap{
        {"ok", true},
        {"importedDialogues", importedDialogues},
        {"importedKeyEntries", importedKeyEntries},
        {"importedAdminServers", importedAdminServers},
        {"importedProfiles", importedProfiles},
        {"skippedEntries", skippedEntries},
        {"conflicts", conflicts},
    };
}

QVariantMap ClientBackend::deleteExportFile(const QString &filePath)
{
    const QString trimmedPath = filePath.trimmed();
    if (trimmedPath.isEmpty()) return Utils::errorResult("Не указан путь к файлу.");
    if (!QFile::exists(trimmedPath))
        return QVariantMap{{"ok", true}, {"deleted", false}, {"message", "Файл уже удалён."}};
    if (!QFile::remove(trimmedPath)) return Utils::errorResult("Не удалось удалить файл экспорта: " + trimmedPath);
    return QVariantMap{{"ok", true}, {"deleted", true}};
}

// ── Persistence ───────────────────────────────────────────────────────────────

void ClientBackend::saveClientConfig() const
{
    if (m_server.isEmpty() || m_username.isEmpty() || m_private_key.isEmpty()) return;
    const QString profileId = m_profileId.isEmpty() ? Utils::profileIdFor(m_server, m_username) : m_profileId;
    saveClientConfigForProfile(profileId, m_server, m_username, m_private_key);
    Utils::upsertProfileManifest(profileId, m_server, m_username, true);
}

void ClientBackend::saveClientConfigForProfile(const QString &profileId, const QString &server, const QString &username,
                                               const QString &private_key)
{
    if (profileId.isEmpty() || server.isEmpty() || username.isEmpty() || private_key.isEmpty()) return;
    if (!Utils::ensureProfileDir(profileId)) return;
    QJsonObject obj;
    obj["server"]      = Utils::normalizedServerUrl(server);
    obj["username"]    = username;
    obj["private_key"] = private_key;
    Utils::writeJsonObjectFile(Utils::profileClientPath(profileId), obj);
}

void ClientBackend::loadClientConfig()
{
    const QJsonObject manifest = Utils::loadProfilesManifest();
    QString profileId          = manifest.value("last_profile_id").toString();
    QJsonObject obj;
    if (!profileId.isEmpty()) obj = Utils::readJsonObjectFile(Utils::profileClientPath(profileId));
    if (obj.isEmpty()) {
        const QJsonArray profiles = manifest.value("profiles").toArray();
        for (const auto &value : profiles) {
            const QString candidate = value.toObject().value("id").toString();
            obj                     = Utils::readJsonObjectFile(Utils::profileClientPath(candidate));
            if (!obj.isEmpty()) {
                profileId = candidate;
                break;
            }
        }
    }
    if (obj.isEmpty()) {
        const auto doc = QJsonDocument::fromJson(Utils::readAll("client.json"));
        if (!doc.isObject()) return;
        obj       = doc.object();
        profileId = Utils::profileIdFor(obj.value("server").toString(), obj.value("username").toString());
    }

    QString server      = obj.value("server").toString();
    QString username    = obj.value("username").toString();
    QString private_key = obj.value("private_key").toString();
    if (server.isEmpty() || username.isEmpty() || private_key.isEmpty()) return;
    loginClient(server, username, private_key);
}

void ClientBackend::saveDialogs() const
{
    if (m_profileId.isEmpty()) return;
    saveDialogsToPath(Utils::profileDialogsPath(m_profileId), m_dialogs);
}

void ClientBackend::saveDialogsToPath(const QString &path, const QList<Dialog> &dialogs)
{
    const QString profileId = QDir(Utils::profilesRootPath()).relativeFilePath(QFileInfo(path).dir().path());
    if (!profileId.isEmpty() && !profileId.startsWith("..")) Utils::ensureProfileDir(profileId);
    QJsonArray arr;
    for (const auto &d : dialogs) {
        QJsonObject o;
        o["peer"] = d.peer;
        QJsonArray keyring;
        for (const auto &entry : d.keyring) {
            if (entry.key.size() != 32 || entry.startSeq == 0) continue;
            QJsonObject keyObj;
            keyObj["start_seq"] = static_cast<double>(entry.startSeq);
            keyObj["key"]       = QString::fromLatin1(entry.key.toBase64());
            keyring.append(keyObj);
        }
        o["keyring"] = keyring;
        o["lastMsg"] = d.lastMsg;
        arr.append(QJsonValue(o));
    }
    QFile f(path);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) return;
    f.write(QJsonDocument(arr).toJson());
    f.close();
    Utils::setOwnerOnlyPermissions(path);
}

void ClientBackend::loadDialogs()
{
    m_dialogs.clear();
    if (m_profileId.isEmpty()) return;
    const QString path = Utils::profileDialogsPath(m_profileId);
    if (QFile::exists(path)) {
        m_dialogs = loadDialogsFromPath(path);
        return;
    }
    if (QFile::exists("dialogs.json")) {
        m_dialogs = loadDialogsFromPath("dialogs.json");
        saveDialogs();
    }
}

QList<ClientBackend::Dialog> ClientBackend::loadDialogsFromPath(const QString &path)
{
    QList<Dialog> dialogs;
    const QJsonArray jsonArr = Utils::readJsonArrayFile(path);
    for (const auto &val : jsonArr) {
        auto obj        = val.toObject();
        QString peer    = obj["peer"].toString();
        QString lastMsg = obj["lastMsg"].toString();
        QList<DialogKeyEntry> keyring;

        const QJsonArray keyringJson = obj["keyring"].toArray();
        for (const auto &keyVal : keyringJson) {
            const auto keyObj      = keyVal.toObject();
            bool ok                = false;
            const quint64 startSeq = Utils::readSeq(keyObj["start_seq"], &ok);
            const QByteArray key   = QByteArray::fromBase64(keyObj["key"].toString().toLatin1());
            if (ok && key.size() == 32) { keyring.append({startSeq, key}); }
        }

        if (keyring.isEmpty()) {
            const QByteArray legacyKey = QByteArray::fromBase64(obj["key"].toString().toLatin1());
            if (legacyKey.size() == 32) { keyring.append({1, legacyKey}); }
        }

        std::sort(keyring.begin(), keyring.end(),
                  [](const DialogKeyEntry &lhs, const DialogKeyEntry &rhs) { return lhs.startSeq < rhs.startSeq; });
        if (!peer.isEmpty() && !keyring.isEmpty()) dialogs.append({peer, keyring, lastMsg});
    }
    return dialogs;
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

void ClientBackend::saveDeviceKey() const
{
    QFile f("device_key.json");
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) return;
    QJsonObject obj;
    obj["private_key_b64"] = m_devicePrivkey;
    f.write(QJsonDocument(obj).toJson());
    f.close();
    Utils::setOwnerOnlyPermissions("device_key.json");
}

void ClientBackend::loadDeviceKey()
{
    auto doc = QJsonDocument::fromJson(Utils::readAll("device_key.json"));
    if (doc.isObject()) {
        const QString priv = doc.object()["private_key_b64"].toString();
        if (!priv.isEmpty() && QByteArray::fromBase64(priv.toLatin1()).size() == 32) {
            m_devicePrivkey = priv;
            return;
        }
    }
    // Генерируем новый keypair при первом запуске
    char *privPtr = nullptr;
    char *pubPtr  = nullptr;
    paranoia_ecies_generate_keypair(&privPtr, &pubPtr);
    if (privPtr) {
        m_devicePrivkey = QString::fromUtf8(privPtr);
        paranoia_free_string(privPtr);
    }
    if (pubPtr) paranoia_free_string(pubPtr);
    saveDeviceKey();
    emit deviceKeyChanged();
}
