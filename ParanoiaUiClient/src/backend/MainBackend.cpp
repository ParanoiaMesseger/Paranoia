#include "MainBackend.hpp"

#include "Paths.hpp"
#include "utils/adminStorage.hpp"
#include "session/Dialog.hpp"
#include "platform/PlatformNotifications.hpp"
#include "session/ServerSession.hpp"
#include "session/SessionStore.hpp"
#include "utils/Utils.hpp"
#include <ParanoiaFFI>

#include <QCryptographicHash>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QGuiApplication>
#include <QNetworkInformation>
#include <QRandomGenerator>
#include <QStandardPaths>
#include <QThreadPool>
#include <QPointer>
#include <QDebug>
#include <QDir>
#include <QFileInfo>
#include <algorithm>

namespace
{
    QStringList reserveUrlsFromObject(const QJsonObject &obj, const QString &primaryUrl)
    {
        return Utils::normalizedServerUrls(
            Utils::stringListFromJsonArray(obj.value("reserve_server_urls").toArray()), primaryUrl);
    }

    QStringList appendReserveUrl(QStringList urls, const QString &primaryUrl, const QString &reserveUrl)
    {
        urls.append(reserveUrl);
        return Utils::normalizedServerUrls(urls, primaryUrl);
    }
}

MainBackend::MainBackend(QObject *parent) : QObject(parent)
{
    m_pollTimer = new QTimer(this);
    m_pollTimer->setSingleShot(true);
    connect(m_pollTimer, &QTimer::timeout, this, &MainBackend::onPollTimer);
    if (QNetworkInformation::loadDefaultBackend()) {
        if (auto *networkInfo = QNetworkInformation::instance()) {
            connect(networkInfo, &QNetworkInformation::reachabilityChanged, this, &MainBackend::onNetworkChanged);
            connect(networkInfo, &QNetworkInformation::transportMediumChanged, this, &MainBackend::onNetworkChanged);
        }
    }
    connect(SessionStore::instance(), &SessionStore::activeSessionChanged, this, &MainBackend::loginStateChanged);
    connect(SessionStore::instance(), &SessionStore::sessionsChanged, this, &MainBackend::sessionsChanged);
    connect(SessionStore::instance(), &SessionStore::activeSessionChanged, this, &MainBackend::sessionsChanged);
    QPointer self(this);
    PlatformNotifications::setBackgroundPollCallback([self]() {
        if (!self) return;
        QMetaObject::invokeMethod(self, [self]() {
            if (!self) return;
            self->onNetworkChanged();
        });
    });
    loadDeviceKey();
    loadClientConfig();
}

MainBackend::~MainBackend()
{
    m_pollTimer->stop();
    PlatformNotifications::setBackgroundPollCallback({});
    PlatformNotifications::stopBackgroundPollingService();
}

bool MainBackend::isLoggedIn() const
{
    const auto session = SessionStore::instance()->activeSession();
    return session && session->isLoggedIn();
}

QString MainBackend::username() const
{
    const auto session = SessionStore::instance()->activeSession();
    return session ? session->username : QString();
}

QString MainBackend::server() const
{
    const auto session = SessionStore::instance()->activeSession();
    return session ? session->server : QString();
}

bool MainBackend::hasAdminAccess() const { return !admin::Admin::admins.empty(); }

QString MainBackend::devicePubkey() const { return ParanoiaFFI::ecies_pubkey(m_devicePrivkey); }

QString MainBackend::notificationHintPeer() const { return m_notificationHintPeer; }

QString MainBackend::notificationHintProfileId() const { return m_notificationHintProfileId; }

// ── Key Generation ────────────────────────────────────────────────────────────

void MainBackend::generateKeyPair()
{
    QThreadPool::globalInstance()->start([this]() {
        auto [secret, pubkey] = ParanoiaFFI::generate_keypair();
        QMetaObject::invokeMethod(this, [this, pubkey, secret]() { emit keyPairGenerated(pubkey, secret); });
    });
}

// ── Client Login ──────────────────────────────────────────────────────────────

void MainBackend::loginClient(const QString &server, const QString &reserveServer, const QString &username,
                              const QString &private_key)
{
    QStringList reserveUrls;
    if (!reserveServer.trimmed().isEmpty()) reserveUrls.append(reserveServer);
    loginClientInternal(server, username, private_key, reserveUrls, true);
}

void MainBackend::loginClientInternal(const QString &server, const QString &username, const QString &private_key,
                                      const QStringList &reserveServerUrls, bool makeActive)
{
    const QString url                    = Utils::normalizedServerUrl(server);
    const QStringList normalizedReserves = Utils::normalizedServerUrls(reserveServerUrls, url);
    const QString reserveUrlsJson        = Utils::reserveServerUrlsJson(normalizedReserves);
    const QString trimmedUsername        = username.trimmed();
    const QString serverId               = ParanoiaFFI::derive_server_id(private_key);
    if (serverId.isEmpty()) {
        if (makeActive) emit loginError("Не удалось вычислить server ID из ключа.");
        return;
    }
    const QString profileId = Utils::profileIdFor(url, serverId);
    if (!Paths::ensureProfileDir(profileId)) {
        if (makeActive) emit loginError("Не удалось подготовить каталог профиля.");
        return;
    }
    const QString dbPath = Paths::profileDb(profileId);
    QPointer self(this);
    QThreadPool::globalInstance()->start([self, url, normalizedReserves, reserveUrlsJson, trimmedUsername, serverId,
                                           private_key, dbPath, profileId, makeActive]() {
        QMetaObject::invokeMethod(self, [self, dbPath, url, normalizedReserves, reserveUrlsJson, trimmedUsername,
                                          serverId, private_key, profileId, makeActive]() {
            auto handle = std::make_unique<ParanoiaFFI>(url, reserveUrlsJson, serverId, private_key, dbPath);
            if (!self) return;
            if (!handle || !handle->isRawOk()) {
                if (makeActive) emit self->loginError("Не удалось подключиться. Проверьте адрес сервера и ключ.");
                return;
            }
            auto *store  = SessionStore::instance();
            auto session = store->addSession(std::move(handle), url, trimmedUsername, serverId, private_key, profileId,
                                             normalizedReserves);
            session->loadDialogs();
            const bool notificationTargetsThisProfile = !self->m_notificationHintProfileId.isEmpty() &&
                                                        self->m_notificationHintProfileId == profileId;
            const bool notificationTargetsOtherProfile = !self->m_notificationHintProfileId.isEmpty() &&
                                                         !notificationTargetsThisProfile;
            if (notificationTargetsThisProfile ||
                (makeActive && (!notificationTargetsOtherProfile || !store->activeSession()))) {
                store->setActiveSession(session);
                emit self->sessionReset();
                emit self->loginStateChanged();
                emit self->dialogsChanged();
            }
            session->saveClientConfig();
            self->scheduleNotifyPoll(0);
        });
    });
}

// ── Activate Profile ─────────────────────────────────────────────────────────

void MainBackend::activateProfile(const QString &profileId)
{
    const auto obj = Utils::readJsonObjectFile(Paths::profileClient(profileId));
    if (obj.isEmpty()) { emit loginError("Профиль не найден."); return; }
    const QString server             = obj.value("server").toString();
    const QString username           = obj.value("username").toString();
    const QString private_key        = obj.value("private_key").toString();
    const QStringList reserveUrls    = reserveUrlsFromObject(obj, server);
    if (server.isEmpty() || private_key.isEmpty()) { emit loginError("Профиль повреждён."); return; }
    loginClientInternal(server, username, private_key, reserveUrls, true);
}

// ── Register User (admin action) ──────────────────────────────────────────────

void MainBackend::registerUser(const QString &domain, const QString &pubkey)
{
    const auto found =
        std::ranges::find_if(admin::Admin::admins, [&](const admin::Admin &a) { return a.domain == domain; });
    if (found == admin::Admin::admins.end()) {
        emit registerUserError("Нет прав администратора для этого сервера.");
        return;
    }
    const QByteArray pubkeyBytes = QByteArray::fromBase64(pubkey.toUtf8());
    if (pubkeyBytes.size() != 32) {
        emit registerUserError("Некорректный публичный ключ.");
        return;
    }
    QCryptographicHash hasher(QCryptographicHash::Sha256);
    hasher.addData(QByteArrayLiteral("paranoia:server-id:v1\n"));
    hasher.addData(pubkeyBytes);
    const QString serverId = QString::fromLatin1(hasher.result().toHex());
    found->regUser(serverId, pubkey).then([this](bool ok) {
        QMetaObject::invokeMethod(this, [this, ok]() {
            if (ok)
                emit userRegistered();
            else
                emit registerUserError("Ошибка регистрации. Проверьте данные.");
        });
    });
}

void MainBackend::addAdminReserveDomain(const QString &primaryDomain, const QString &reserveDomain)
{
    const QString primaryUrl = Utils::normalizedServerUrl(primaryDomain);
    auto found = std::ranges::find_if(admin::Admin::admins,
                                      [&](const admin::Admin &a) { return a.domain == primaryUrl; });
    if (found == admin::Admin::admins.end()) {
        emit reserveDomainError("Нет прав администратора для этого сервера.");
        return;
    }

    const QString reserveUrl = Utils::normalizedServerUrl(reserveDomain);
    if (reserveUrl.isEmpty()) {
        emit reserveDomainError("Укажите резервный домен.");
        return;
    }
    if (reserveUrl == found->domain) {
        emit reserveDomainError("Резервный домен совпадает с основным.");
        return;
    }
    if (Utils::normalizedServerUrls(found->reserveServerUrls, found->domain).contains(reserveUrl)) {
        emit reserveDomainError("Этот резервный домен уже добавлен.");
        return;
    }

    found->reserveServerUrls = appendReserveUrl(found->reserveServerUrls, found->domain, reserveUrl);
    admin::Admin::saveAdmins();
    emit adminStateChanged();
    emit reserveDomainAdded("admin", found->domain, reserveUrl);
}

void MainBackend::addClientReserveDomain(const QString &profileId, const QString &reserveDomain)
{
    if (profileId.trimmed().isEmpty()) {
        emit reserveDomainError("Не выбран клиентский профиль.");
        return;
    }

    auto *store                 = SessionStore::instance();
    const auto session          = store->sessionForProfile(profileId);
    const auto activeSession    = store->activeSession();
    const QJsonObject obj       = Utils::readJsonObjectFile(Paths::profileClient(profileId));
    QString primaryUrl          = obj.value("server").toString();
    QString username            = obj.value("username").toString();
    QString privateKey          = obj.value("private_key").toString();
    QString serverId            = obj.value("server_id").toString();
    QStringList reserveUrls     = reserveUrlsFromObject(obj, primaryUrl);
    if (session) {
        if (primaryUrl.isEmpty()) primaryUrl = session->server;
        if (username.isEmpty()) username = session->username;
        if (privateKey.isEmpty()) privateKey = session->private_key;
        if (serverId.isEmpty()) serverId = session->serverId;
        reserveUrls.append(session->reserveServerUrls);
    }
    primaryUrl  = Utils::normalizedServerUrl(primaryUrl);
    reserveUrls = Utils::normalizedServerUrls(reserveUrls, primaryUrl);
    if (primaryUrl.isEmpty() || privateKey.isEmpty()) {
        emit reserveDomainError("Клиентский профиль повреждён.");
        return;
    }

    const QString reserveUrl = Utils::normalizedServerUrl(reserveDomain);
    if (reserveUrl.isEmpty()) {
        emit reserveDomainError("Укажите резервный домен.");
        return;
    }
    if (reserveUrl == primaryUrl) {
        emit reserveDomainError("Резервный домен совпадает с основным.");
        return;
    }
    if (reserveUrls.contains(reserveUrl)) {
        emit reserveDomainError("Этот резервный домен уже добавлен.");
        return;
    }
    if (serverId.isEmpty()) serverId = ParanoiaFFI::derive_server_id(privateKey);
    if (serverId.isEmpty()) {
        emit reserveDomainError("Не удалось вычислить server ID из ключа профиля.");
        return;
    }

    const QStringList updatedReserveUrls = appendReserveUrl(reserveUrls, primaryUrl, reserveUrl);
    ServerSession::saveClientConfigForProfile(profileId, primaryUrl, username, serverId, privateKey,
                                              updatedReserveUrls);
    const QJsonObject manifest = Utils::loadProfilesManifest();
    Utils::upsertProfileManifest(profileId, primaryUrl, username,
                                 manifest.value("last_profile_id").toString() == profileId);
    if (session)
        loginClientInternal(primaryUrl, username, privateKey, updatedReserveUrls, session == activeSession);
    else
        emit sessionsChanged();
    emit reserveDomainAdded("client", profileId, reserveUrl);
}

// ── Dialogs Management ────────────────────────────────────────────────────────

void MainBackend::addDialog(const QString &peer, const QString &sharedSecret)
{
    upsertDialogKeyringEntry(peer.trimmed(), {}, Dialog::deriveKey(sharedSecret), 1, true);
}

void MainBackend::updateDialogKey(const QString &peer, const QString &newSharedSecret)
{
    const QString trimmedPeer = peer.trimmed();
    const QByteArray key      = Dialog::deriveKey(newSharedSecret);
    auto session              = SessionStore::instance()->activeSession();
    if (!session) return;
    const auto *dlg = session->findDialog(trimmedPeer);
    if (!dlg) return;
    const QString peerServerId = dlg->peerServerId;
    const QString serverId     = session->serverId;
    QPointer self(this);
    QThreadPool::globalInstance()->start([self, session, trimmedPeer, peerServerId, serverId, key]() {
        if (!self) return;
        quint64 seq = 1;
        {
            QMutexLocker locker(&session->ffiMutex);
            if (session->ffi && !serverId.isEmpty() && !peerServerId.isEmpty()) {
                uint64_t last = 0;
                session->ffi->last_pulled_seq(serverId, peerServerId, last);
                seq = static_cast<quint64>(last) + 1;
            }
        }
        QMetaObject::invokeMethod(self, [self, trimmedPeer, key, seq]() {
            if (self) self->upsertDialogKeyringEntry(trimmedPeer, {}, key, seq, false);
        });
    });
}

QVariantMap MainBackend::createDialogKeyInvitation(const QString &peer) const
{
    const auto session        = SessionStore::instance()->activeSession();
    const QString trimmedPeer = peer.trimmed();
    if (!session || session->serverId.isEmpty() || trimmedPeer.isEmpty())
        return ParanoiaFFI::errorResult("Не указан server ID или собеседник.");

    const QString bundleJson = ParanoiaFFI::qr_create_invitation(session->serverId);
    if (bundleJson.isEmpty()) return ParanoiaFFI::lastRustErrorResult();
    const auto doc = QJsonDocument::fromJson(bundleJson.toUtf8());
    if (!doc.isObject()) return ParanoiaFFI::errorResult("Некорректный JSON invitation.");
    const auto obj            = doc.object();
    const QString stateJson   = Utils::compactJson(obj.value("state"));
    const QString payloadJson = Utils::compactJson(obj.value("payload"));
    if (stateJson.isEmpty() || payloadJson.isEmpty()) return ParanoiaFFI::errorResult("Некорректный JSON invitation.");
    return QVariantMap{
        {"ok", true},
        {"peer", trimmedPeer},
        {"stateJson", stateJson},
        {"payloadJson", payloadJson},
    };
}

QVariantMap MainBackend::createDialogKeyResponse(const QString &invitationPayloadJson)
{
    const auto session = SessionStore::instance()->activeSession();
    if (!session || session->serverId.isEmpty() || invitationPayloadJson.trimmed().isEmpty())
        return ParanoiaFFI::errorResult("Нет invitation payload или server ID.");
    const QString bundleJson = ParanoiaFFI::qr_create_response(invitationPayloadJson, session->serverId);
    if (bundleJson.isEmpty()) return ParanoiaFFI::lastRustErrorResult();
    const auto doc = QJsonDocument::fromJson(bundleJson.toUtf8());
    if (!doc.isObject()) return ParanoiaFFI::errorResult("Некорректный JSON response.");
    const auto obj            = doc.object();
    const QString stateJson   = Utils::compactJson(obj.value("state"));
    const QString payloadJson = Utils::compactJson(obj.value("payload"));
    if (stateJson.isEmpty() || payloadJson.isEmpty()) return ParanoiaFFI::errorResult("Некорректный JSON response.");
    QVariantMap fingerprint = dialogKeyFingerprint(stateJson, invitationPayloadJson);
    if (!fingerprint.value("ok").toBool()) return fingerprint;
    return QVariantMap{
        {"ok", true},
        {"stateJson", stateJson},
        {"payloadJson", payloadJson},
        {"fingerprint", fingerprint.value("fingerprint").toString()},
    };
}

QVariantMap MainBackend::dialogKeyFingerprint(const QString &localStateJson, const QString &peerPayloadJson)
{
    if (localStateJson.trimmed().isEmpty() || peerPayloadJson.trimmed().isEmpty())
        return ParanoiaFFI::errorResult("Нет state или payload для расчёта SAS.");
    const QString fingerprint = ParanoiaFFI::qr_fingerprint(localStateJson, peerPayloadJson);
    if (fingerprint.isEmpty()) return ParanoiaFFI::lastRustErrorResult();
    return QVariantMap{{"ok", true}, {"fingerprint", fingerprint}};
}

QVariantMap MainBackend::confirmDialogKeyExchange(const QString &peer, const QString &localStateJson,
                                                  const QString &peerPayloadJson, const QString &fingerprint,
                                                  const bool updateExisting)
{
    const QString trimmedPeer = peer.trimmed();
    if (trimmedPeer.isEmpty()) return ParanoiaFFI::errorResult("Не указан собеседник.");
    const QString completedJson = ParanoiaFFI::qr_confirm_exchange(localStateJson, peerPayloadJson, fingerprint);
    if (completedJson.isEmpty()) return ParanoiaFFI::lastRustErrorResult();

    const auto doc = QJsonDocument::fromJson(completedJson.toUtf8());
    if (!doc.isObject()) return ParanoiaFFI::errorResult("Некорректный JSON завершения обмена.");
    const auto completedObj     = doc.object();
    const QByteArray sessionKey = QByteArray::fromBase64(completedObj.value("session_key_b64").toString().toLatin1());
    const QString fpResult      = completedObj.value("fingerprint").toString();
    if (sessionKey.size() != 32) return ParanoiaFFI::errorResult("Некорректный ключ диалога.");

    auto session               = SessionStore::instance()->activeSession();
    const QString initiatorId  = completedObj.value("initiator_id").toString();
    const QString responderId  = completedObj.value("responder_id").toString();
    const QString peerServerId = (session && initiatorId == session->serverId) ? responderId : initiatorId;

    if (!updateExisting) {
        upsertDialogKeyringEntry(trimmedPeer, peerServerId, sessionKey, 1, true);
    } else {
        if (session) {
            QPointer self(this);
            QThreadPool::globalInstance()->start([self, session, trimmedPeer, peerServerId, sessionKey]() {
                if (!self) return;
                quint64 seq = 1;
                {
                    QMutexLocker locker(&session->ffiMutex);
                    if (session->ffi && !session->serverId.isEmpty() && !peerServerId.isEmpty()) {
                        uint64_t last = 0;
                        session->ffi->last_pulled_seq(session->serverId, peerServerId, last);
                        seq = static_cast<quint64>(last) + 1;
                    }
                }
                QMetaObject::invokeMethod(self, [self, trimmedPeer, peerServerId, sessionKey, seq]() {
                    if (self) self->upsertDialogKeyringEntry(trimmedPeer, peerServerId, sessionKey, seq, false);
                });
            });
        }
    }
    return QVariantMap{
        {"ok", true},
        {"peer", trimmedPeer},
        {"fingerprint", fpResult},
    };
}

void MainBackend::removeDialog(const QString &peer)
{
    auto session = SessionStore::instance()->activeSession();
    if (!session) return;
    session->dialogs.removeIf([&peer](const Dialog &d) { return d.peer == peer; });
    m_notifiedPendingByPeer.remove(session->profileId + ":" + peer);
    m_locallyReceivedPendingByPeer.remove(session->profileId + ":" + peer);
    if (m_notificationHintProfileId == session->profileId && m_notificationHintPeer == peer) setNotificationHint({}, {});
    emit dialogRemoved(peer);
    emit dialogsChanged();
    session->saveDialogs();
    scheduleNotifyPoll();
}

QVariantList MainBackend::getDialogs() const
{
    const auto session = SessionStore::instance()->activeSession();
    if (!session) return {};
    const QString profileId = session->profileId;
    QVariantList result;
    for (const auto &dlg : session->dialogs)
        result.append(QVariantMap{{"peer", dlg.peer},
                                  {"lastMsg", dlg.lastMsg},
                                  {"hasKey", !dlg.keyring.isEmpty()},
                                  {"unreadCount", m_notifiedPendingByPeer.value(profileId + ":" + dlg.peer, 0)},
                                  {"notificationHint", profileId == m_notificationHintProfileId &&
                                                           dlg.peer == m_notificationHintPeer}});
    return result;
}

QVariantList MainBackend::getAdminServers() const
{
    QVariantList result;
    for (const auto &a : admin::Admin::admins) {
        QVariantMap m;
        QVariantList reserveDomains;
        for (const auto &url : Utils::normalizedServerUrls(a.reserveServerUrls, a.domain)) reserveDomains.append(url);
        m["domain"]         = a.domain;
        m["reserveDomains"] = reserveDomains;
        result.append(m);
    }
    return result;
}

QString MainBackend::takeNotificationPeer()
{
    const auto target = PlatformNotifications::takeOpenTargetFromNotification();
    if (!target.peer.isEmpty()) {
        auto *store = SessionStore::instance();
        QString profileId = target.profileId;
        if (!profileId.isEmpty()) {
            auto session = store->sessionForProfile(profileId);
            if (session && session != store->activeSession()) {
                store->setActiveSession(session);
                m_activePeer.clear();
                emit sessionReset();
                emit dialogsChanged();
                emit sessionSwitched();
                scheduleNotifyPoll(0);
            }
        }
        if (profileId.isEmpty()) {
            const auto session = store->activeSession();
            if (session) profileId = session->profileId;
        }
        setNotificationHint(profileId, target.peer);
        emit dialogsChanged();
    }
    return m_notificationHintPeer;
}

// ── History Management ────────────────────────────────────────────────────────

void MainBackend::deleteDialogLocal(const QString &peer)
{
    auto session = SessionStore::instance()->activeSession();
    if (!session || !session->findDialog(peer)) return;
    const QString peerCopy     = peer;
    const QString serverId     = session->serverId;
    const QString profileId    = session->profileId;
    const auto *dlg            = session->findDialog(peer);
    const QString peerServerId = dlg ? dlg->peerServerId : QString();
    QPointer self(this);
    QThreadPool::globalInstance()->start([self, session, peerCopy, serverId, peerServerId, profileId]() {
        if (!self) return;
        QMutexLocker locker(&session->ffiMutex);
        if (!session->ffi) return;
        int rc   = (!serverId.isEmpty() && !peerServerId.isEmpty())
                       ? session->ffi->delete_local_dialogue(serverId, peerServerId)
                       : session->ffi->delete_local_dialogue(session->username, peerCopy);
        auto err = ParanoiaFFI::last_error();
        QMetaObject::invokeMethod(self, [self, peerCopy, profileId, rc, err]() {
            if (!self) return;
            if (rc == 0) {
                self->m_notifiedPendingByPeer.remove(profileId + ":" + peerCopy);
                self->m_locallyReceivedPendingByPeer.remove(profileId + ":" + peerCopy);
                if (self->m_notificationHintProfileId == profileId && self->m_notificationHintPeer == peerCopy)
                    self->setNotificationHint({}, {});
                emit self->dialogRemoved(peerCopy);
                emit self->dialogDeleted(peerCopy);
            } else
                emit self->serverHistoryError("Ошибка удаления локальной истории: " + err);
        });
    });
}

void MainBackend::clearServerHistory(const QString &peer, quint64 cutSeq)
{
    auto session = SessionStore::instance()->activeSession();
    if (!session) {
        emit serverHistoryError("Нет активной сессии.");
        return;
    }
    const auto *dlg = session->findDialog(peer);
    if (!dlg) {
        emit serverHistoryError("Диалог не найден.");
        return;
    }
    const QString peerCopy     = peer;
    const QString serverId     = session->serverId;
    const QString peerServerId = dlg->peerServerId;
    const QString keyringJson  = dlg->keyringJson();
    QPointer self(this);
    QThreadPool::globalInstance()->start([self, session, peerCopy, serverId, peerServerId, keyringJson, cutSeq]() {
        if (!self) return;
        QMutexLocker locker(&session->ffiMutex);
        if (!session->ffi) return;
        const QString myId   = serverId.isEmpty() ? session->username : serverId;
        const QString peerId = peerServerId.isEmpty() ? peerCopy : peerServerId;
        int rc               = session->ffi->determinate_keyring(myId, peerId, keyringJson, cutSeq);
        QString err          = ParanoiaFFI::last_error();
        QMetaObject::invokeMethod(self, [self, err, peerCopy, rc]() {
            if (!self) return;
            if (rc == 0) {
                emit self->serverHistoryCleared(peerCopy);
            } else {
                if (err == "server_unavailable")
                    emit self->serverHistoryError("Сервер недоступен.");
                else
                    emit self->serverHistoryError("Ошибка удаления серверной истории: " + err);
            }
        });
    });
}

// ── Cross-backend slots ───────────────────────────────────────────────────────

void MainBackend::onActivePeerChanged(const QString &peer)
{
    m_activePeer = peer;
    if (!peer.isEmpty()) {
        const auto session    = SessionStore::instance()->activeSession();
        const QString profileId = session ? session->profileId : QString();
        const QString key     = profileId + ":" + peer;
        const bool hadPending = m_notifiedPendingByPeer.remove(key) > 0;
        m_locallyReceivedPendingByPeer.remove(key);
        if (m_notificationHintProfileId == profileId && m_notificationHintPeer == peer) setNotificationHint({}, {});
        if (hadPending) emit dialogsChanged();
    }
}

void MainBackend::onPeerMessagesRead(const QString &peer)
{
    const auto session    = SessionStore::instance()->activeSession();
    const QString profileId = session ? session->profileId : QString();
    const QString key     = profileId + ":" + peer;
    const bool hadPending = m_notifiedPendingByPeer.remove(key) > 0;
    m_locallyReceivedPendingByPeer.remove(key);
    if (m_notificationHintProfileId == profileId && m_notificationHintPeer == peer) setNotificationHint({}, {});
    if (hadPending) emit dialogsChanged();
}

void MainBackend::onBackgroundMessagesReceived(const QString &profileId, const QString &peer, quint64 count)
{
    if (profileId.isEmpty() || peer.isEmpty() || count == 0) return;
    const QString key = profileId + ":" + peer;
    m_locallyReceivedPendingByPeer[key] = m_locallyReceivedPendingByPeer.value(key, 0) + count;
    m_notifiedPendingByPeer[key] = m_notifiedPendingByPeer.value(key, 0) + count;
    quint64 total = 0;
    for (auto it = m_notifiedPendingByPeer.constBegin(); it != m_notifiedPendingByPeer.constEnd(); ++it)
        total += it.value();
    setNotificationHint(profileId, peer);
    emit dialogsChanged();
    emit notificationAvailable(total, profileId, peer);
}

// ── Export / Import ───────────────────────────────────────────────────────────

QVariantMap MainBackend::exportProfile(const QString &profileType, const QStringList &peers,
                                       const QString &receiverPubkeyB64, const QString &filePath)
{
    const QString normalizedProfile = profileType.trimmed();
    if (!Utils::isSupportedExportProfile(normalizedProfile))
        return ParanoiaFFI::errorResult("Неподдерживаемый тип профиля экспорта.");
    if (receiverPubkeyB64.trimmed().isEmpty())
        return ParanoiaFFI::errorResult("Не указан публичный ключ принимающего устройства.");
    if (filePath.trimmed().isEmpty()) return ParanoiaFFI::errorResult("Не указан путь к файлу.");
    QJsonObject payload;
    payload["format_version"] = 1;
    payload["profile_type"]   = normalizedProfile;
    const bool includeClient  = (normalizedProfile == "client" || normalizedProfile == "full");
    const bool includeAdmin   = (normalizedProfile == "admin" || normalizedProfile == "full");
    int exportedDialogues     = 0;
    int exportedKeyEntries    = 0;
    if (includeClient) {
        auto session = SessionStore::instance()->activeSession();
        if (!session || session->server.isEmpty() || session->private_key.isEmpty())
            return ParanoiaFFI::errorResult("Нет активной клиентской сессии для экспорта.");
        QJsonArray dialoguesArr;
        for (const auto &dlg : session->dialogs) {
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
            return ParanoiaFFI::errorResult("Нет выбранных диалогов с keyring для экспорта.");
        QJsonObject serverObj;
        serverObj["url"]             = session->server;
        serverObj["reserve_server_urls"] = Utils::stringListToJsonArray(session->reserveServerUrls);
        serverObj["username"]        = session->username;
        serverObj["signing_key_b64"] = session->private_key;
        serverObj["dialogues"]       = dialoguesArr;
        payload["servers"]           = QJsonArray{serverObj};
    }

    if (includeAdmin) {
        QJsonArray adminArr;
        for (const auto &a : admin::Admin::admins) {
            QJsonObject adminObj;
            adminObj["url"]                   = a.domain;
            adminObj["admin_private_key_b64"] = a.private_key;
            adminObj["reserve_server_urls"]   = Utils::stringListToJsonArray(
                Utils::normalizedServerUrls(a.reserveServerUrls, a.domain));
            adminArr.append(adminObj);
        }
        payload["admin_servers"] = adminArr;
    }
    if (!includeClient) payload["servers"] = QJsonArray{};
    if (!includeAdmin) payload["admin_servers"] = QJsonArray{};
    const QString payloadJson = QString::fromUtf8(QJsonDocument(payload).toJson(QJsonDocument::Compact));
    auto envelope             = ParanoiaFFI::ecies_encrypt(receiverPubkeyB64.trimmed(), payloadJson);
    if (envelope.isEmpty()) {
        if (ParanoiaFFI::last_error() == "invalid_device_key")
            return ParanoiaFFI::errorResult("Некорректный публичный ключ принимающего устройства.");
        return ParanoiaFFI::errorResult("Ошибка шифрования экспорта.");
    }
    QFile file(filePath);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate))
        return ParanoiaFFI::errorResult("Не удалось открыть файл для записи: " + filePath);
    const QByteArray envelopeBytes = envelope.toUtf8();
    if (file.write(envelopeBytes) != envelopeBytes.size()) {
        file.close();
        return ParanoiaFFI::errorResult("Не удалось полностью записать файл экспорта.");
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

QVariantMap MainBackend::importProfile(const QString &filePath)
{
    if (m_devicePrivkey.isEmpty()) return ParanoiaFFI::errorResult("Device keypair не инициализирован.");
    if (filePath.trimmed().isEmpty()) return ParanoiaFFI::errorResult("Не указан путь к файлу.");
    QFile file(filePath);
    if (!file.open(QIODevice::ReadOnly)) return ParanoiaFFI::errorResult("Не удалось открыть файл: " + filePath);
    if (file.size() > Utils::MaxExportFileBytes) {
        file.close();
        return ParanoiaFFI::errorResult("Файл экспорта слишком большой.");
    }
    const QString envelopeJson = QString::fromUtf8(file.readAll());
    file.close();
    if (envelopeJson.trimmed().isEmpty()) return ParanoiaFFI::errorResult("Файл пуст.");
    auto payloadJson = ParanoiaFFI::ecies_decrypt(m_devicePrivkey, envelopeJson);
    if (payloadJson.isEmpty()) {
        const QString err = ParanoiaFFI::last_error();
        if (err == "ecies_decrypt_error")
            return ParanoiaFFI::errorResult(
                "Не удалось расшифровать файл. Файл зашифрован другим ключом или повреждён.");
        if (err == "ecies_unsupported_version")
            return ParanoiaFFI::errorResult("Неподдерживаемая версия формата экспорта.");
        return ParanoiaFFI::errorResult("Ошибка расшифровки.");
    }
    QJsonParseError parseError;
    const auto doc = QJsonDocument::fromJson(payloadJson.toUtf8(), &parseError);
    if (parseError.error != QJsonParseError::NoError || !doc.isObject())
        return ParanoiaFFI::errorResult("Некорректный формат payload после расшифровки.");
    const auto payload = doc.object();
    if (payload["format_version"].toInt() != 1)
        return ParanoiaFFI::errorResult("Неподдерживаемая версия формата payload.");
    const QString profileType = payload["profile_type"].toString();
    if (!Utils::isSupportedExportProfile(profileType))
        return ParanoiaFFI::errorResult("Неподдерживаемый тип профиля в payload.");
    const bool allowClientImport = (profileType == "client" || profileType == "full");
    const bool allowAdminImport  = (profileType == "admin" || profileType == "full");
    int importedDialogues        = 0;
    int importedKeyEntries       = 0;
    int importedAdminServers     = 0;
    int skippedEntries           = 0;
    int conflicts                = 0;
    int importedProfiles         = 0;
    QString activateServer;
    QString activateUsername;
    QString activatePrivkey;
    QStringList activateReserveServerUrls;
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
        dialogs.append({peer, QString(), QList<DialogKeyEntry>{{startSeq, key}}, QString()});
        return 1;
    };
    if (allowClientImport) {
        auto session              = SessionStore::instance()->activeSession();
        const QString myProfileId = session ? session->profileId : QString();
        const QJsonArray servers  = payload["servers"].toArray();
        if (servers.size() > Utils::MaxImportServers)
            return ParanoiaFFI::errorResult("Слишком много client-профилей в export payload.");
        int totalDialogues  = 0;
        int totalKeyEntries = 0;
        for (const auto &serverVal : servers) {
            const auto serverObj     = serverVal.toObject();
            const QString url        = Utils::normalizedServerUrl(serverObj["url"].toString());
            QStringList reserveUrls  = Utils::normalizedServerUrls(
                Utils::stringListFromJsonArray(serverObj["reserve_server_urls"].toArray()), url);
            const QString username   = serverObj["username"].toString().trimmed();
            const QString signingKey = serverObj["signing_key_b64"].toString().trimmed();
            if (url.isEmpty()) continue;
            if (!Utils::decodeFixedBase64(signingKey, 32))
                return ParanoiaFFI::errorResult("Некорректный private signing key в client-профиле export payload.");
            const QString importedServerId = ParanoiaFFI::derive_server_id(signingKey);
            if (importedServerId.isEmpty())
                return ParanoiaFFI::errorResult("Не удалось вычислить server_id из ключа в export payload.");
            const QString profileId    = Utils::profileIdFor(url, importedServerId);
            const bool isCurrentClient = !myProfileId.isEmpty() && (profileId == myProfileId);
            const bool profileExists   = QFile::exists(Paths::profileClient(profileId));
            if (profileExists) {
                const QJsonObject existing = Utils::readJsonObjectFile(Paths::profileClient(profileId));
                const QString existingKey  = existing.value("private_key").toString().trimmed();
                if (!existingKey.isEmpty() && existingKey != signingKey) {
                    ++conflicts;
                    continue;
                }
                reserveUrls.append(reserveUrlsFromObject(existing, url));
                reserveUrls = Utils::normalizedServerUrls(reserveUrls, url);
            }
            QList<Dialog> targetDialogs =
                isCurrentClient ? session->dialogs : Dialog::loadFromPath(Paths::profileDialogs(profileId));
            QSet<QString> touchedDialogues;
            const QJsonArray dialogues = serverObj["dialogues"].toArray();
            if (totalDialogues + dialogues.size() > Utils::MaxImportDialogues)
                return ParanoiaFFI::errorResult("Слишком много диалогов в export payload.");
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
                    return ParanoiaFFI::errorResult("Слишком много keyring entries в export payload.");
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
            ServerSession::saveClientConfigForProfile(profileId, url, username, importedServerId, signingKey,
                                                      reserveUrls);
            Dialog::saveToPath(Paths::profileDialogs(profileId), targetDialogs);
            Utils::upsertProfileManifest(profileId, url, username, isCurrentClient || myProfileId.isEmpty());
            if (!profileExists) ++importedProfiles;
            if (myProfileId.isEmpty() && activatePrivkey.isEmpty()) {
                activateServer   = url;
                activateUsername = username;
                activatePrivkey  = signingKey;
                activateReserveServerUrls = reserveUrls;
            }
            if (isCurrentClient) {
                session->dialogs = targetDialogs;
                emit sessionReset();
                emit dialogsChanged();
            }
        }
    }
    if (allowAdminImport) {
        const QJsonArray adminServers = payload["admin_servers"].toArray();
        if (adminServers.size() > Utils::MaxImportAdminServers)
            return ParanoiaFFI::errorResult("Слишком много admin-профилей в export payload.");
        for (const auto &adminVal : adminServers) {
            const auto adminObj       = adminVal.toObject();
            const QString url         = Utils::normalizedServerUrl(adminObj["url"].toString());
            const QString private_key = adminObj["admin_private_key_b64"].toString().trimmed();
            const QStringList reserveUrls = Utils::normalizedServerUrls(
                Utils::stringListFromJsonArray(adminObj["reserve_server_urls"].toArray()), url);
            if (url.isEmpty() || private_key.isEmpty()) continue;
            if (!Utils::decodeFixedBase64(private_key, 32))
                return ParanoiaFFI::errorResult("Некорректный private admin key в export payload.");
            bool found = false;
            for (auto &a : admin::Admin::admins)
                if (a.domain == url) {
                    if (a.private_key == private_key) {
                        const QStringList merged = Utils::normalizedServerUrls(a.reserveServerUrls + reserveUrls, url);
                        if (merged != a.reserveServerUrls) {
                            a.reserveServerUrls = merged;
                            ++importedAdminServers;
                        }
                    }
                    found = true;
                    break;
                }
            if (!found) {
                admin::Admin::admins.push_back({url, private_key, reserveUrls});
                ++importedAdminServers;
            }
        }
    }
    if (importedAdminServers > 0) {
        admin::Admin::saveAdmins();
        emit adminStateChanged();
    }
    if (!activatePrivkey.isEmpty()) loginClientInternal(activateServer, activateUsername, activatePrivkey,
                                                        activateReserveServerUrls, true);
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

QVariantMap MainBackend::deleteExportFile(const QString &filePath)
{
    const QString trimmedPath = filePath.trimmed();
    if (trimmedPath.isEmpty()) return ParanoiaFFI::errorResult("Не указан путь к файлу.");
    if (!QFile::exists(trimmedPath))
        return QVariantMap{{"ok", true}, {"deleted", false}, {"message", "Файл уже удалён."}};
    if (!QFile::remove(trimmedPath))
        return ParanoiaFFI::errorResult("Не удалось удалить файл экспорта: " + trimmedPath);
    return QVariantMap{{"ok", true}, {"deleted", true}};
}

// ── Polling ───────────────────────────────────────────────────────────────────

void MainBackend::onPollTimer() { pollNotifications(); }

void MainBackend::pollNotifications()
{
    if (m_notifyPollInFlight) {
        scheduleNotifyPoll();
        return;
    }

    struct NotifyTarget {
        std::shared_ptr<ServerSession> session;
        QString peer;
        QString peerServerId;
        QString keyringJson;
        QString profileId;
    };
    struct NotifyCount {
        QString key;
        QString profileId;
        QString peer;
        quint64 count;
    };
    QList<NotifyTarget> targets;
    const auto activeSession = SessionStore::instance()->activeSession();
    const QString activePeer = m_activePeer;
    const bool appActive     = QGuiApplication::applicationState() == Qt::ApplicationActive;

    for (const auto &session : SessionStore::instance()->allSessions()) {
        if (!session || !session->isLoggedIn()) continue;
        const QString profileId = session->profileId;
        for (const auto &dialog : session->dialogs) {
            if (appActive && session == activeSession && !activePeer.isEmpty() && dialog.peer == activePeer) continue;
            const QString keyringJson = dialog.keyringJson();
            if (!dialog.peer.isEmpty() && !keyringJson.isEmpty())
                targets.append({session, dialog.peer, dialog.peerServerId, keyringJson, profileId});
        }
    }

    if (targets.isEmpty()) {
        const bool hadPending = !m_notifiedPendingByPeer.isEmpty();
        m_notifiedPendingByPeer.clear();
        m_locallyReceivedPendingByPeer.clear();
        setNotificationHint({}, {});
        if (hadPending) emit dialogsChanged();
        scheduleNotifyPoll();
        return;
    }

    QPointer self(this);
    m_notifyPollInFlight = true;
    QThreadPool::globalInstance()->start([self, targets]() {
        QList<NotifyCount> counts;
        QString error;
        bool anyFailed = false;
        if (!self) return;
        for (const auto &target : targets) {
            uint64_t count    = 0;
            const QString key = target.profileId + ":" + target.peer;
            {
                QMutexLocker locker(&target.session->ffiMutex);
                if (!target.session->ffi) continue;
                const QString myId =
                    target.session->serverId.isEmpty() ? target.session->username : target.session->serverId;
                const QString peerId = target.peerServerId.isEmpty() ? target.peer : target.peerServerId;
                const int rc = target.session->ffi->notify_count_keyring(myId, peerId, target.keyringJson, count);
                if (rc != 0) {
                    anyFailed = true;
                    if (error.isEmpty()) error = ParanoiaFFI::last_error();
                    continue;
                }
            }
            counts.append({key, target.profileId, target.peer, static_cast<quint64>(count)});
        }
        if (!self) return;
        QMetaObject::invokeMethod(self, [self, counts, anyFailed, error]() {
            if (!self) return;
            self->m_notifyPollInFlight = false;
            bool hasNewPending  = false;
            bool pendingChanged = false;
            QString newPendingProfileId;
            QString newPendingPeer;
            int newPendingPeers = 0;
            QString hintProfileId;
            QString hintPeer;
            int pendingPeers = 0;
            for (const auto &item : counts) {
                const QString &key          = item.key;
                const quint64 serverCount   = item.count;
                const quint64 localCount    = self->m_locallyReceivedPendingByPeer.value(key, 0);
                const quint64 combinedCount = localCount + serverCount;
                if (combinedCount == 0) {
                    pendingChanged = self->m_notifiedPendingByPeer.remove(key) > 0 || pendingChanged;
                    continue;
                }

                ++pendingPeers;
                if (pendingPeers == 1) {
                    hintProfileId = item.profileId;
                    hintPeer      = item.peer;
                } else {
                    hintProfileId.clear();
                    hintPeer.clear();
                }

                const quint64 previousCombined = self->m_notifiedPendingByPeer.value(key, 0);
                const quint64 previousLocal    = self->m_locallyReceivedPendingByPeer.value(key, 0);
                const quint64 previousServer = previousCombined > previousLocal ? previousCombined - previousLocal : 0;
                if (combinedCount != previousCombined) pendingChanged = true;
                if (serverCount > previousServer) {
                    hasNewPending = true;
                    ++newPendingPeers;
                    if (newPendingPeers == 1) {
                        newPendingProfileId = item.profileId;
                        newPendingPeer      = item.peer;
                    } else {
                        newPendingProfileId.clear();
                        newPendingPeer.clear();
                    }
                }
                self->m_notifiedPendingByPeer[key] = combinedCount;
            }

            quint64 total = 0;
            for (auto it = self->m_notifiedPendingByPeer.constBegin(); it != self->m_notifiedPendingByPeer.constEnd(); ++it)
                total += it.value();
            if (hintPeer.isEmpty() && newPendingPeers == 1) {
                hintProfileId = newPendingProfileId;
                hintPeer      = newPendingPeer;
            }
            if (total == 0) {
                self->setNotificationHint({}, {});
            } else if (pendingChanged) {
                self->setNotificationHint(hintProfileId, hintPeer);
            }
            if (pendingChanged) {
                emit self->dialogsChanged();
            }
            if (hasNewPending) emit self->notificationAvailable(total, hintProfileId, hintPeer);
            if (anyFailed) {
                qWarning().noquote() << "Notify polling failed for some sessions:" << error;
                ++self->m_notifyRetryCount;
                self->scheduleNotifyPoll(self->retryNotifyDelayMs());
            } else {
                self->m_notifyRetryCount = 0;
                self->scheduleNotifyPoll();
            }
        });
    });
}

void MainBackend::onNetworkChanged()
{
    m_notifyRetryCount = 0;
    scheduleNotifyPoll(0);
    emit networkRestored();
}

// ── Helpers ───────────────────────────────────────────────────────────────────

void MainBackend::scheduleNotifyPoll(int delayMs)
{
    const auto &sessions = SessionStore::instance()->allSessions();
    bool anyActive       = false;
    for (const auto &s : sessions)
        if (s && s->isLoggedIn() && !s->dialogs.isEmpty()) {
            anyActive = true;
            break;
        }
    if (!anyActive) {
        m_pollTimer->stop();
        PlatformNotifications::stopBackgroundPollingService();
        return;
    }
    PlatformNotifications::startBackgroundPollingService();
    if (delayMs < 0) delayMs = randomNotifyDelayMs();
    m_pollTimer->start(delayMs);
}

void MainBackend::setNotificationHint(const QString &profileId, const QString &peer)
{
    if (m_notificationHintProfileId == profileId && m_notificationHintPeer == peer) return;
    m_notificationHintProfileId = profileId;
    m_notificationHintPeer      = peer;
    emit notificationHintPeerChanged();
}

int MainBackend::randomNotifyDelayMs() const { return QRandomGenerator::global()->bounded(2'000, 15'001); }

int MainBackend::retryNotifyDelayMs() const
{
    const int shift  = std::min(m_notifyRetryCount, 6);
    const int base   = std::min(1000 * (1 << shift), 60'000);
    const int jitter = QRandomGenerator::global()->bounded((base / 5) + 1);
    return base + jitter;
}

void MainBackend::upsertDialogKeyringEntry(const QString &peer, const QString &peerServerId,
                                           const QByteArray &sessionKey, quint64 startSeq, bool resetKeyring)
{
    if (peer.isEmpty() || sessionKey.size() != 32 || startSeq == 0) return;
    auto session = SessionStore::instance()->activeSession();
    if (!session) return;
    auto &dialogs = session->dialogs;
    for (auto &d : dialogs) {
        if (d.peer == peer) {
            if (!peerServerId.isEmpty()) d.peerServerId = peerServerId;
            if (resetKeyring) d.keyring.clear();
            bool replaced = false;
            for (auto &entry : d.keyring)
                if (entry.startSeq == startSeq) {
                    entry.key = sessionKey;
                    replaced  = true;
                    break;
                }
            if (!replaced) { d.keyring.append({startSeq, sessionKey}); }
            std::sort(d.keyring.begin(), d.keyring.end(),
                      [](const DialogKeyEntry &lhs, const DialogKeyEntry &rhs) { return lhs.startSeq < rhs.startSeq; });
            emit dialogsChanged();
            session->saveDialogs();
            scheduleNotifyPoll();
            return;
        }
    }
    dialogs.append({peer, peerServerId, QList<DialogKeyEntry>{{startSeq, sessionKey}}, QString()});
    emit dialogsChanged();
    session->saveDialogs();
    scheduleNotifyPoll();
}

// ── Session Management ────────────────────────────────────────────────────────

QVariantList MainBackend::getSessionList() const
{
    const auto activeSession = SessionStore::instance()->activeSession();
    QVariantList result;
    for (const auto &session : SessionStore::instance()->allSessions()) {
        quint64 total        = 0;
        const QString prefix = session->profileId + ":";
        for (auto it = m_notifiedPendingByPeer.constBegin(); it != m_notifiedPendingByPeer.constEnd(); ++it)
            if (it.key().startsWith(prefix)) total += it.value();
        result.append(QVariantMap{
            {"profileId", session->profileId},
            {"server", session->server},
            {"reserveServerUrls", Utils::stringListToJsonArray(session->reserveServerUrls).toVariantList()},
            {"username", session->username},
            {"isActive", session == activeSession},
            {"totalUnread", total},
        });
    }
    return result;
}

void MainBackend::switchSession(const QString &profileId)
{
    auto session = SessionStore::instance()->sessionForProfile(profileId);
    if (!session || session == SessionStore::instance()->activeSession()) return;
    SessionStore::instance()->setActiveSession(session);
    m_activePeer.clear();
    setNotificationHint({}, {});
    emit sessionReset();
    emit dialogsChanged();
    emit sessionSwitched();
    scheduleNotifyPoll(0);
}

// ── Persistence ───────────────────────────────────────────────────────────────

void MainBackend::loadClientConfig()
{
    const QJsonObject manifest  = Utils::loadProfilesManifest();
    const QString lastProfileId = manifest.value("last_profile_id").toString();
    const QJsonArray profiles   = manifest.value("profiles").toArray();

    QSet<QString> loaded;
    auto tryLoad = [&](const QString &profileId, bool makeActive) {
        if (profileId.isEmpty() || loaded.contains(profileId)) return;
        const auto obj = Utils::readJsonObjectFile(Paths::profileClient(profileId));
        if (obj.isEmpty()) return;
        const QString server      = obj.value("server").toString();
        const QString username    = obj.value("username").toString();
        const QString private_key = obj.value("private_key").toString();
        const QStringList reserveUrls = reserveUrlsFromObject(obj, server);
        if (server.isEmpty() || private_key.isEmpty()) return;
        loaded.insert(profileId);
        loginClientInternal(server, username, private_key, reserveUrls, makeActive);
    };

    for (const auto &value : profiles) {
        const QString id = value.toObject().value("id").toString();
        tryLoad(id, id == lastProfileId);
    }
    // Also try lastProfileId directly in case it's not in the profiles array yet
    if (!loaded.contains(lastProfileId)) tryLoad(lastProfileId, true);
}

void MainBackend::saveDeviceKey() const
{
    QFile f("device_key.json");
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) return;
    QJsonObject obj;
    obj["private_key_b64"] = m_devicePrivkey;
    f.write(QJsonDocument(obj).toJson());
    f.close();
    Utils::setOwnerOnlyPermissions("device_key.json");
}

void MainBackend::loadDeviceKey()
{
    auto doc = QJsonDocument::fromJson(Utils::readAll("device_key.json"));
    if (doc.isObject()) {
        const QString priv = doc.object()["private_key_b64"].toString();
        if (!priv.isEmpty() && QByteArray::fromBase64(priv.toLatin1()).size() == 32) {
            m_devicePrivkey = priv;
            return;
        }
    }
    auto [privateKey, publicKey] = ParanoiaFFI::ecies_generate_keypair();
    if (!privateKey.isEmpty()) m_devicePrivkey = privateKey;
    saveDeviceKey();
    emit deviceKeyChanged();
}
