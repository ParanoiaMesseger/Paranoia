#include "ClientBackend.hpp"

#include "PlatformNotifications.hpp"
#include "Utils.hpp"
#include "paranoia_lib.h"

#include <QJsonArray>
#include <QJsonObject>
#include <QJsonParseError>
#include <QCryptographicHash>
#include <QDateTime>
#include <QFile>
#include <QGuiApplication>
#include <QInputMethod>
#include <QMimeDatabase>
#include <QNetworkInformation>
#include <QRandomGenerator>
#include <QStandardPaths>
#include <QThreadPool>
#include <QUrl>
#include <QPointer>
#include <QDebug>
#include <QDir>
#include <QFileInfo>
#include <QUuid>
#include <algorithm>

#if defined(Q_OS_ANDROID)
#include <QCoreApplication>
#include <QJniEnvironment>
#include <QJniObject>
#endif

namespace
{
    QString localPathFromUrlOrPath(const QString &urlOrPath)
    {
        const QUrl url(urlOrPath);
        if (url.isValid() && url.isLocalFile()) return url.toLocalFile();
        if (urlOrPath.startsWith(QStringLiteral("file://"))) return QUrl(urlOrPath).toLocalFile();
        return urlOrPath;
    }

    bool isContentUri(const QString &urlOrPath)
    {
        return urlOrPath.startsWith(QStringLiteral("content://"), Qt::CaseInsensitive);
    }

    QString temporaryAttachmentPath()
    {
        QString cacheRoot = QStandardPaths::writableLocation(QStandardPaths::CacheLocation);
        if (cacheRoot.isEmpty()) cacheRoot = QDir::tempPath();
        QDir dir(cacheRoot);
        if (!dir.mkpath(QStringLiteral("attachments"))) return {};
        dir.cd(QStringLiteral("attachments"));
        return dir.filePath(
            QStringLiteral("attachment-%1.bin").arg(QUuid::createUuid().toString(QUuid::WithoutBraces)));
    }

    QString safeAttachmentName(const QString &name)
    {
        QString value = name.trimmed();
        if (value.isEmpty()) value = QStringLiteral("attachment.bin");
        for (const QChar ch : QStringLiteral("\\/:*?\"<>|")) value.replace(ch, QLatin1Char('_'));
        while (value.endsWith(QLatin1Char('.')) || value.endsWith(QLatin1Char(' '))) value.chop(1);
        return value.isEmpty() ? QStringLiteral("attachment.bin") : value;
    }

    QString uniqueFilePath(const QString &directoryPath, const QString &filename)
    {
        QDir dir(directoryPath);
        if (!dir.exists() && !dir.mkpath(QStringLiteral("."))) return {};

        const QString safeName = safeAttachmentName(filename);
        QFileInfo info(safeName);
        const QString suffix = info.completeSuffix();
        const QString base = suffix.isEmpty()
                                 ? safeName
                                 : safeName.left(safeName.size() - suffix.size() - 1);
        QString candidate = safeName;
        for (int i = 1; dir.exists(candidate); ++i) {
            candidate = suffix.isEmpty()
                            ? QStringLiteral("%1 (%2)").arg(base).arg(i)
                            : QStringLiteral("%1 (%2).%3").arg(base).arg(i).arg(suffix);
        }
        return dir.filePath(candidate);
    }

    bool isImageAttachment(const QString &kind, const QString &mimeType)
    {
        return kind == QStringLiteral("image") || mimeType.startsWith(QStringLiteral("image/"), Qt::CaseInsensitive);
    }

    QString localFileUrlIfReadable(const QString &path)
    {
        if (path.trimmed().isEmpty()) return {};
        const QFileInfo info(path);
        if (!info.exists() || !info.isFile() || !info.isReadable()) return {};
        return QUrl::fromLocalFile(info.absoluteFilePath()).toString();
    }

    QString userFacingAttachmentError(const QString &error)
    {
        if (error.contains(QStringLiteral("attachment_incomplete"), Qt::CaseInsensitive))
            return QStringLiteral("Вложение загружено на сервер не полностью. Попросите отправить файл повторно.");
        if (error.contains(QStringLiteral("attachment_bad_size"), Qt::CaseInsensitive)
            || error.contains(QStringLiteral("attachment_bad_chunk"), Qt::CaseInsensitive))
            return QStringLiteral("Вложение повреждено. Попросите отправить файл повторно.");
        return error;
    }

#if defined(Q_OS_ANDROID)
    QJniObject androidContext() { return QNativeInterface::QAndroidApplication::context(); }

    void clearPendingAndroidException()
    {
        QJniEnvironment env;
        if (env->ExceptionCheck()) {
            env->ExceptionDescribe();
            env->ExceptionClear();
        }
    }

    void requestAndroidFileAccessIfNeeded()
    {
        const QJniObject context = androidContext();
        if (!context.isValid()) return;
        QJniObject::callStaticMethod<void>("app/paranoia/client/ParanoiaAndroidUtils", "requestFileAccessIfNeeded",
                                           "(Landroid/content/Context;)V", context.object<jobject>());
        clearPendingAndroidException();
    }

    QString copyAndroidContentUriToCache(const QString &uri)
    {
        const QJniObject context = androidContext();
        if (!context.isValid()) return {};
        const QJniObject javaUri = QJniObject::fromString(uri);
        const QJniObject result =
            QJniObject::callStaticObjectMethod("app/paranoia/client/ParanoiaAndroidUtils", "copyUriToCache",
                                               "(Landroid/content/Context;Ljava/lang/String;)Ljava/lang/String;",
                                               context.object<jobject>(), javaUri.object<jstring>());
        clearPendingAndroidException();
        return result.isValid() ? result.toString() : QString();
    }

    bool copyAndroidFileToContentUri(const QString &sourcePath, const QString &uri)
    {
        const QJniObject context = androidContext();
        if (!context.isValid()) return false;
        const QJniObject javaPath = QJniObject::fromString(sourcePath);
        const QJniObject javaUri  = QJniObject::fromString(uri);
        const bool ok             = QJniObject::callStaticMethod<jboolean>(
            "app/paranoia/client/ParanoiaAndroidUtils", "copyFileToUri",
            "(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)Z", context.object<jobject>(),
            javaPath.object<jstring>(), javaUri.object<jstring>());
        clearPendingAndroidException();
        return ok;
    }

    bool copyAndroidFileToDirectoryUri(const QString &sourcePath, const QString &uri, const QString &filename)
    {
        const QJniObject context = androidContext();
        if (!context.isValid()) return false;
        const QJniObject javaPath = QJniObject::fromString(sourcePath);
        const QJniObject javaUri  = QJniObject::fromString(uri);
        const QJniObject javaName = QJniObject::fromString(safeAttachmentName(filename));
        const bool ok             = QJniObject::callStaticMethod<jboolean>(
            "app/paranoia/client/ParanoiaAndroidUtils", "copyFileToDirectoryUri",
            "(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Z",
            context.object<jobject>(), javaPath.object<jstring>(), javaUri.object<jstring>(), javaName.object<jstring>());
        clearPendingAndroidException();
        return ok;
    }
#else
    void requestAndroidFileAccessIfNeeded() {}
#endif
}

ClientBackend::ClientBackend(QObject *parent) : QObject(parent)
{
    m_pollTimer = new QTimer(this);
    m_pollTimer->setSingleShot(true);
    connect(m_pollTimer, &QTimer::timeout, this, &ClientBackend::onPollTimer);
    m_activePollTimer = new QTimer(this);
    m_activePollTimer->setSingleShot(true);
    connect(m_activePollTimer, &QTimer::timeout, this, &ClientBackend::onActivePollTimer);
    if (QNetworkInformation::loadDefaultBackend()) {
        if (auto *networkInfo = QNetworkInformation::instance()) {
            connect(networkInfo, &QNetworkInformation::reachabilityChanged, this, &ClientBackend::onNetworkChanged);
            connect(networkInfo, &QNetworkInformation::transportMediumChanged, this, &ClientBackend::onNetworkChanged);
        }
    }
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

ClientBackend::~ClientBackend()
{
    m_pollTimer->stop();
    m_activePollTimer->stop();
    PlatformNotifications::setBackgroundPollCallback({});
    PlatformNotifications::stopBackgroundPollingService();
    QMutexLocker locker(&m_ffiMutex);
    m_ffi.reset();
}

bool ClientBackend::isLoggedIn() const
{
    QMutexLocker locker(&m_ffiMutex);
    return m_ffi != nullptr && m_ffi->isRawOk();
}

QString ClientBackend::username() const { return m_username; }

QString ClientBackend::server() const { return m_server; }

bool ClientBackend::hasAdminAccess() const { return !admin::Admin::admins.empty(); }

QString ClientBackend::devicePubkey() const { return ParanoiaFFI::ecies_pubkey(m_devicePrivkey); }

bool ClientBackend::messagesLoading() const { return m_messageLoadingJobs > 0; }

QString ClientBackend::notificationHintPeer() const { return m_notificationHintPeer; }

// ── Key Generation ────────────────────────────────────────────────────────────

void ClientBackend::generateKeyPair()
{
    QThreadPool::globalInstance()->start([this]() {
        auto [secret, pubkey] = ParanoiaFFI::generate_keypair();
        QMetaObject::invokeMethod(this, [this, pubkey, secret]() { emit keyPairGenerated(pubkey, secret); });
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
        QMetaObject::invokeMethod(self, [self, dbPath, url, trimmedUsername, private_key, profileId]() {
            auto handle = std::make_unique<ParanoiaFFI>(url, trimmedUsername, private_key, dbPath);
            if (!self) return;
            if (!handle || !handle->isRawOk()) {
                emit self->loginError("Не удалось подключиться. Проверьте адрес сервера и ключ.");
                return;
            }
            {
                QMutexLocker locker(&self->m_ffiMutex);
                self->m_ffi = std::move(handle);
            }
            self->m_server      = url;
            self->m_username    = trimmedUsername;
            self->m_private_key = private_key;
            self->m_profileId   = profileId;
            self->m_activePeer.clear();
            self->m_messageCache.clear();
            self->m_seenIds.clear();
            self->m_notifiedPendingByPeer.clear();
            self->setNotificationHintPeer({});
            self->loadDialogs();
            emit self->loginStateChanged();
            emit self->dialogsChanged();
            self->saveClientConfig();
            self->scheduleNotifyPoll(0);
        });
    });
}

// ── Register User (admin action) ──────────────────────────────────────────────

void ClientBackend::registerUser(const QString &domain, const QString &username, const QString &pubkey)
{
    const auto found =
        std::ranges::find_if(admin::Admin::admins, [&](const admin::Admin &a) { return a.domain == domain; });
    if (found == admin::Admin::admins.end()) {
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
{
    upsertDialogKeyringEntry(peer.trimmed(), deriveKey(sharedSecret), 1, true, false);
}

void ClientBackend::updateDialogKey(const QString &peer, const QString &newSharedSecret)
{
    const QString trimmedPeer = peer.trimmed();
    upsertDialogKeyringEntry(trimmedPeer, deriveKey(newSharedSecret), nextKeyStartSeq(trimmedPeer), false, false);
}

QVariantMap ClientBackend::createDialogKeyInvitation(const QString &peer) const
{
    const QString trimmedPeer = peer.trimmed();
    if (m_username.isEmpty() || trimmedPeer.isEmpty())
        return ParanoiaFFI::errorResult("Не указан пользователь или собеседник.");

    const QString bundleJson = ParanoiaFFI::qr_create_invitation(m_username, trimmedPeer);
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

QVariantMap ClientBackend::createDialogKeyResponse(const QString &invitationPayloadJson)
{
    if (m_username.isEmpty() || invitationPayloadJson.trimmed().isEmpty())
        return ParanoiaFFI::errorResult("Нет invitation payload или имени пользователя.");
    const QString bundleJson = ParanoiaFFI::qr_create_response(invitationPayloadJson, m_username);
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

QVariantMap ClientBackend::dialogKeyFingerprint(const QString &localStateJson, const QString &peerPayloadJson)
{
    if (localStateJson.trimmed().isEmpty() || peerPayloadJson.trimmed().isEmpty())
        return ParanoiaFFI::errorResult("Нет state или payload для расчёта SAS.");
    const QString fingerprint = ParanoiaFFI::qr_fingerprint(localStateJson, peerPayloadJson);
    if (fingerprint.isEmpty()) return ParanoiaFFI::lastRustErrorResult();
    return QVariantMap{{"ok", true}, {"fingerprint", fingerprint}};
}

QVariantMap ClientBackend::confirmDialogKeyExchange(const QString &peer, const QString &localStateJson,
                                                    const QString &peerPayloadJson, const QString &fingerprint,
                                                    const bool updateExisting)
{
    const QString trimmedPeer = peer.trimmed();
    if (trimmedPeer.isEmpty()) return ParanoiaFFI::errorResult("Не указан собеседник.");
    const QString completedJson = ParanoiaFFI::qr_confirm_exchange(localStateJson, peerPayloadJson, fingerprint);
    if (completedJson.isEmpty()) return ParanoiaFFI::lastRustErrorResult();

    const auto doc = QJsonDocument::fromJson(completedJson.toUtf8());
    if (!doc.isObject()) return ParanoiaFFI::errorResult("Некорректный JSON завершения обмена.");
    const QByteArray sessionKey = QByteArray::fromBase64(doc.object().value("session_key_b64").toString().toLatin1());
    if (sessionKey.size() != 32) return ParanoiaFFI::errorResult("Некорректный ключ диалога.");
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
    m_notifiedPendingByPeer.remove(peer);
    if (m_notificationHintPeer == peer) setNotificationHintPeer({});
    emit dialogsChanged();
    saveDialogs();
    scheduleNotifyPoll();
}

QVariantList ClientBackend::getDialogs() const
{
    QVariantList result;
    for (const auto &[peer, keyring, lastMsg] : m_dialogs)
        result.append(QVariantMap{{"peer", peer},
                                  {"lastMsg", lastMsg},
                                  {"hasKey", !keyring.isEmpty()},
                                  {"unreadCount", m_notifiedPendingByPeer.value(peer, 0)},
                                  {"notificationHint", peer == m_notificationHintPeer}});
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

void ClientBackend::requestFileAccessPermissions() { requestAndroidFileAccessIfNeeded(); }

void ClientBackend::commitInputMethod()
{
    if (auto *inputMethod = QGuiApplication::inputMethod()) inputMethod->commit();
}

QString ClientBackend::takeNotificationPeer()
{
    const QString peer = PlatformNotifications::takeOpenPeerFromNotification();
    if (!peer.isEmpty()) setNotificationHintPeer(peer);
    return m_notificationHintPeer;
}

// ── History Management ────────────────────────────────────────────────────────

void ClientBackend::deleteDialogLocal(const QString &peer)
{
    if (!findDialog(peer)) return;
    QString peerCopy = peer, username = m_username;
    QPointer self(this);
    QThreadPool::globalInstance()->start([self, peerCopy, username]() {
        if (!self) return;
        QMutexLocker locker(&self->m_ffiMutex);
        if (!self->m_ffi) return;
        int rc   = self->m_ffi->delete_local_dialogue(username, peerCopy);
        auto err = ParanoiaFFI::last_error();
        QMetaObject::invokeMethod(self, [self, peerCopy, rc, err]() {
            if (!self) return;
            if (rc == 0) {
                self->m_messageCache.remove(peerCopy);
                self->m_seenIds.remove(peerCopy);
                self->m_notifiedPendingByPeer.remove(peerCopy);
                if (self->m_notificationHintPeer == peerCopy) self->setNotificationHintPeer({});
                emit self->dialogDeleted(peerCopy);
                emit self->messagesReceived(peerCopy, QVariantList{});
            } else
                emit self->serverHistoryError("Ошибка удаления локальной истории: " + err);
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
    QPointer self(this);
    QThreadPool::globalInstance()->start([self, peerCopy, username, keyringJson, cutSeq]() {
        if (!self) return;
        QMutexLocker locker(&self->m_ffiMutex);
        if (!self->m_ffi) return;
        int rc      = self->m_ffi->determinate_keyring(username, peerCopy, keyringJson, cutSeq);
        QString err = ParanoiaFFI::last_error();
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

// ── Chat ──────────────────────────────────────────────────────────────────────

void ClientBackend::openChat(const QString &peer)
{
    m_activePeer          = peer;
    const bool hadPending = m_notifiedPendingByPeer.remove(peer) > 0;
    if (m_notificationHintPeer == peer) setNotificationHintPeer({});
    if (hadPending) emit dialogsChanged();
    if (isLoggedIn() && findDialog(peer)) {
        loadHistory(peer);
        fetchMessages();
        scheduleActiveChatPoll(0);
    }
}

void ClientBackend::stopChat()
{
    m_activePeer.clear();
    m_activePollTimer->stop();
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
    QString peer          = m_activePeer;
    QString username      = m_username;
    QString keyringJson   = dialogKeyringJson(*dlg);
    const QString sendKey = peer + QChar('\n') + text;
    const qint64 nowMs    = QDateTime::currentMSecsSinceEpoch();
    for (auto it = m_recentSendAtMs.begin(); it != m_recentSendAtMs.end();) {
        if (nowMs - it.value() > 10'000)
            it = m_recentSendAtMs.erase(it);
        else
            ++it;
    }
    if (nowMs - m_recentSendAtMs.value(sendKey, 0) < 1'500) return;
    if (m_sendInFlightKeys.contains(sendKey)) return;
    m_sendInFlightKeys.insert(sendKey);
    m_recentSendAtMs[sendKey] = nowMs;

    QPointer self(this);
    QThreadPool::globalInstance()->start([self, peer, username, text, keyringJson, sendKey]() {
        if (!self) return;
        QString json;
        QString err;
        {
            QMutexLocker locker(&self->m_ffiMutex);
            if (!self->m_ffi) {
                err = "client_not_ready";
            } else {
                json = self->m_ffi->send_text_json_keyring(username, peer, keyringJson, text);
                if (json.isEmpty()) err = ParanoiaFFI::last_error();
            }
        }
        if (json.isEmpty()) {
            QMetaObject::invokeMethod(self, [self, err, sendKey]() {
                if (!self) return;
                self->m_sendInFlightKeys.remove(sendKey);
                self->m_recentSendAtMs.remove(sendKey);
                if (err == "duplicate_seq" || err == "invalid_seq")
                    emit self->sendError("Ошибка синхронизации seq. Повторите отправку после обновления диалога.");
                else if (err == "server_unavailable")
                    emit self->sendError("Сервер недоступен. Проверьте соединение.");
                else
                    emit self->sendError("Ошибка отправки сообщения.");
            });
            return;
        }
        QMetaObject::invokeMethod(self, [self, peer, json, sendKey]() {
            if (!self) return;
            self->m_sendInFlightKeys.remove(sendKey);
            self->appendMessages(peer, self->parseMessages(json));
            if (peer == self->m_activePeer) self->loadHistory(peer);
        });
    });
}

void ClientBackend::sendFile(const QString &fileUrlOrPath)
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
    requestAndroidFileAccessIfNeeded();

    const QString source       = fileUrlOrPath.trimmed();
    const bool sourceIsContent = isContentUri(source);
    const QString originalPath = sourceIsContent ? QString() : localPathFromUrlOrPath(source);
    qint64 originalSize        = -1;
    QString originalMimeType;
    if (!sourceIsContent) {
        const QFileInfo info(originalPath);
        if (!info.exists() || !info.isFile() || !info.isReadable()) {
            emit sendError("Файл недоступен для чтения.");
            return;
        }
        originalSize     = info.size();
        originalMimeType = QMimeDatabase().mimeTypeForFile(info).name();
    }

    const QString peer        = m_activePeer;
    const QString username    = m_username;
    const QString keyringJson = dialogKeyringJson(*dlg);
    const QString sendKey =
        peer + QChar('\n') + (sourceIsContent ? source : originalPath) + QChar('\n') + QString::number(originalSize);
    if (m_sendInFlightKeys.contains(sendKey)) return;
    m_sendInFlightKeys.insert(sendKey);

    QPointer self(this);
    QThreadPool::globalInstance()->start(
        [self, peer, username, keyringJson, source, sourceIsContent, originalPath, originalMimeType, sendKey]() {
            if (!self) return;
            QString json;
            QString err;
            QString path = originalPath;
#if defined(Q_OS_ANDROID)
            if (sourceIsContent) path = copyAndroidContentUriToCache(source);
#endif
            if (path.isEmpty()) err = "file_read_error";
            const QFileInfo info(path);
            if (err.isEmpty() && (!info.exists() || !info.isFile() || !info.isReadable())) err = "file_read_error";
            const QString mimeType =
                originalMimeType.isEmpty() ? QMimeDatabase().mimeTypeForFile(info).name() : originalMimeType;
            {
                QMutexLocker locker(&self->m_ffiMutex);
                if (!err.isEmpty()) {
                    // keep the classified file error from the Android/content resolver path
                } else if (!self->m_ffi) {
                    err = "client_not_ready";
                } else {
                    json = self->m_ffi->send_file_json_keyring(username, peer, keyringJson, path, mimeType);
                    if (json.isEmpty()) err = ParanoiaFFI::last_error();
                }
            }
            if (json.isEmpty()) {
                QMetaObject::invokeMethod(self, [self, err, sendKey]() {
                    if (!self) return;
                    self->m_sendInFlightKeys.remove(sendKey);
                    if (err == "file_read_error")
                        emit self->sendError("Не удалось прочитать файл.");
                    else if (err == "server_unavailable")
                        emit self->sendError("Сервер недоступен. Проверьте соединение.");
                    else
                        emit self->sendError("Ошибка отправки файла: " + err);
                });
                return;
            }
            QMetaObject::invokeMethod(self, [self, peer, json, sendKey]() {
                if (!self) return;
                self->m_sendInFlightKeys.remove(sendKey);
                self->appendMessages(peer, self->parseMessages(json));
                if (peer == self->m_activePeer) self->loadHistory(peer);
            });
        });
}

void ClientBackend::saveAttachment(const QString &messageId, const QString &targetUrlOrPath)
{
    if (m_activePeer.isEmpty() || messageId.isEmpty()) return;
    const auto *dlg = findDialog(m_activePeer);
    if (!dlg) return;
    requestAndroidFileAccessIfNeeded();
    const QString target       = targetUrlOrPath.trimmed();
    const bool targetIsContent = isContentUri(target);

    QString filename = QStringLiteral("attachment.bin");
    for (const auto &cached : m_messageCache.value(m_activePeer)) {
        const QVariantMap msg = cached.toMap();
        if (msg.value("id").toString() == messageId) {
            const QString fn = msg.value("filename").toString();
            const QString txt = msg.value("text").toString();
            filename = !fn.isEmpty() ? fn : (!txt.isEmpty() ? txt : filename);
            break;
        }
    }
    filename = safeAttachmentName(filename);

    QString path;
    if (targetIsContent) {
        path = temporaryAttachmentPath();
    } else {
        const QString localTarget = localPathFromUrlOrPath(target);
        const QFileInfo targetInfo(localTarget);
        path = targetInfo.exists() && targetInfo.isDir()
                   ? uniqueFilePath(localTarget, filename)
                   : localTarget;
    }
    if (path.isEmpty()) return;
    const QString peer        = m_activePeer;
    const QString username    = m_username;
    const QString keyringJson = dialogKeyringJson(*dlg);
    QPointer self(this);
    QThreadPool::globalInstance()->start(
        [self, peer, username, keyringJson, messageId, path, target, targetIsContent, filename]() {
            if (!self) return;
            int rc = -1;
            QString err;
            {
                QMutexLocker locker(&self->m_ffiMutex);
                if (!self->m_ffi) {
                    err = "client_not_ready";
                } else {
                    rc = self->m_ffi->save_attachment_keyring(username, peer, keyringJson, messageId, path);
                    if (rc != 0) err = ParanoiaFFI::last_error();
                }
            }
#if defined(Q_OS_ANDROID)
            if (rc == 0 && targetIsContent) {
                if (!copyAndroidFileToDirectoryUri(path, target, filename) && !copyAndroidFileToContentUri(path, target)) {
                    rc  = -1;
                    err = "file_write_error";
                }
            }
            if (targetIsContent) QFile::remove(path);
#endif
            const QString savedPath = targetIsContent ? target + QStringLiteral("/") + filename : path;
            QMetaObject::invokeMethod(self, [self, peer, savedPath, rc, err]() {
                if (!self) return;
                if (rc == 0) {
                    emit self->attachmentSaved(savedPath);
                    if (peer == self->m_activePeer) self->loadHistory(peer);
                } else {
                    emit self->receiveError("Не удалось сохранить файл: " + userFacingAttachmentError(err));
                }
            });
        });
}

void ClientBackend::ensureImagePreview(const QString &messageId)
{
    if (m_activePeer.isEmpty() || messageId.isEmpty()) return;
    const auto *dlg = findDialog(m_activePeer);
    if (!dlg) return;

    bool imageMessage = false;
    bool hasPreview   = false;
    for (const auto &cached : m_messageCache.value(m_activePeer)) {
        const QVariantMap msg = cached.toMap();
        if (msg.value("id").toString() != messageId) continue;
        imageMessage = isImageAttachment(msg.value("kind").toString(), msg.value("mime_type").toString());
        hasPreview   = !msg.value("preview_source").toString().isEmpty();
        break;
    }
    if (!imageMessage || hasPreview) return;

    const QString requestKey = m_activePeer + QChar('\n') + messageId;
    if (m_previewInFlightIds.contains(requestKey)) return;
    m_previewInFlightIds.insert(requestKey);

    const QString peer        = m_activePeer;
    const QString username    = m_username;
    const QString keyringJson = dialogKeyringJson(*dlg);
    QPointer self(this);
    QThreadPool::globalInstance()->start([self, peer, username, keyringJson, messageId, requestKey]() {
        if (!self) return;
        QString path;
        QString err;
        {
            QMutexLocker locker(&self->m_ffiMutex);
            if (!self->m_ffi) {
                err = QStringLiteral("client_not_ready");
            } else {
                path = self->m_ffi->cache_attachment_keyring(username, peer, keyringJson, messageId);
                if (path.isEmpty()) err = ParanoiaFFI::last_error();
            }
        }

        QMetaObject::invokeMethod(self, [self, peer, requestKey, path, err]() {
            if (!self) return;
            self->m_previewInFlightIds.remove(requestKey);
            if (!path.isEmpty()) {
                if (peer == self->m_activePeer) self->loadHistory(peer);
                return;
            }
            if (!err.isEmpty()) qWarning().noquote() << "Image preview cache failed:" << err;
        });
    });
}

void ClientBackend::deleteMessagesUntil(quint64 cutSeq)
{
    if (m_activePeer.isEmpty() || cutSeq == 0) return;
    const auto *dlg = findDialog(m_activePeer);
    if (!dlg) return;

    const QString peer        = m_activePeer;
    const QString username    = m_username;
    const QString keyringJson = dialogKeyringJson(*dlg);
    QPointer self(this);
    QThreadPool::globalInstance()->start([self, peer, username, keyringJson, cutSeq]() {
        if (!self) return;
        int localRc = -1;
        int serverRc = -1;
        QString err;
        {
            QMutexLocker locker(&self->m_ffiMutex);
            if (!self->m_ffi) {
                err = "client_not_ready";
            } else {
                localRc = self->m_ffi->delete_local_until_keyring(username, peer, keyringJson, cutSeq);
                if (localRc != 0) {
                    err = ParanoiaFFI::last_error();
                } else {
                    serverRc = self->m_ffi->determinate_keyring(username, peer, keyringJson, cutSeq);
                    if (serverRc != 0) err = ParanoiaFFI::last_error();
                }
            }
        }

        QMetaObject::invokeMethod(self, [self, peer, cutSeq, localRc, serverRc, err]() {
            if (!self) return;
            if (localRc == 0) {
                auto &cache = self->m_messageCache[peer];
                QVariantList kept;
                QSet<QString> keptIds;
                for (const auto &msg : cache) {
                    const QVariantMap map = msg.toMap();
                    bool ok               = false;
                    const quint64 seq      = map.value("seq").toULongLong(&ok);
                    if (ok && seq <= cutSeq) continue;
                    kept.append(msg);
                    const QString id = map.value("id").toString();
                    if (!id.isEmpty()) keptIds.insert(id);
                }
                cache = kept;
                self->m_seenIds[peer] = keptIds;
                emit self->messagesReceived(peer, cache);
                emit self->dialogsChanged();
            }

            if (localRc != 0) {
                emit self->receiveError("Не удалось удалить локальные сообщения: " + err);
            } else if (serverRc != 0) {
                if (err == "server_unavailable")
                    emit self->serverHistoryError("Сообщения удалены локально, но сервер недоступен.");
                else
                    emit self->serverHistoryError("Сообщения удалены локально, ошибка сервера: " + err);
            } else {
                emit self->serverHistoryCleared(peer);
            }
        });
    });
}

void ClientBackend::fetchMessages()
{
    if (m_activePeer.isEmpty()) return;
    if (m_receiveInFlight) {
        m_receiveAgainAfterCurrent = true;
        return;
    }
    const auto *dlg = findDialog(m_activePeer);
    if (!dlg) return;
    QString peer        = m_activePeer;
    QString username    = m_username;
    QString keyringJson = dialogKeyringJson(*dlg);
    QPointer self(this);
    m_receiveInFlight = true;
    beginMessagesLoading();
    QThreadPool::globalInstance()->start([self, peer, username, keyringJson]() {
        if (!self) return;
        QString json;
        QString lastErr;
        {
            QMutexLocker locker(&self->m_ffiMutex);
            if (!self->m_ffi) {
                lastErr = "client_not_ready";
            } else {
                json = self->m_ffi->receive_keyring(username, peer, keyringJson);
                // Проверяем на ошибки расшифровки даже при успешном получении
                lastErr = ParanoiaFFI::last_error();
            }
        }
        if (json.isEmpty()) {
            QMetaObject::invokeMethod(self, [self, lastErr]() {
                if (!self) return;
                self->m_receiveInFlight = false;
                self->endMessagesLoading();
                if (lastErr == "server_unavailable")
                    emit self->receiveError("Сервер недоступен.");
                else if (!lastErr.isEmpty())
                    emit self->receiveError("Ошибка получения: " + lastErr);
                if (self->m_receiveAgainAfterCurrent) {
                    self->m_receiveAgainAfterCurrent = false;
                    self->fetchMessages();
                }
            });
            return;
        }
        QMetaObject::invokeMethod(self, [self, json, peer, lastErr]() {
            if (!self) return;
            self->m_receiveInFlight = false;
            self->endMessagesLoading();
            if (lastErr.startsWith("decryption_failed:"))
                emit self->receiveError("Ошибка расшифровки: неверный ключ диалога или повреждённые данные.");
            if (peer == self->m_activePeer) {
                self->appendMessages(peer, self->parseMessages(json));
                const bool hadPending = self->m_notifiedPendingByPeer.remove(peer) > 0;
                if (self->m_notificationHintPeer == peer) self->setNotificationHintPeer({});
                if (hadPending) emit self->dialogsChanged();
            }
            if (self->m_receiveAgainAfterCurrent) {
                self->m_receiveAgainAfterCurrent = false;
                self->fetchMessages();
            }
        });
    });
}

void ClientBackend::loadHistory(const QString &peer)
{
    const auto *dlg = findDialog(peer);
    if (!dlg) return;
    QString username    = m_username;
    QString keyringJson = dialogKeyringJson(*dlg);
    QPointer self(this);
    beginMessagesLoading();
    QThreadPool::globalInstance()->start([self, peer, username, keyringJson]() {
        if (!self) return;
        QString json;
        {
            QMutexLocker locker(&self->m_ffiMutex);
            if (self->m_ffi) json = self->m_ffi->history_keyring(username, peer, keyringJson, 500);
        }
        QMetaObject::invokeMethod(self, [self, peer, json]() {
            if (!self) return;
            self->endMessagesLoading();
            if (peer != self->m_activePeer) return;
            if (json.isEmpty()) return;
            const QVariantList messages = self->parseMessages(json);
            self->m_messageCache[peer].clear();
            self->m_seenIds[peer].clear();
            if (messages.isEmpty()) {
                emit self->messagesReceived(peer, QVariantList{});
                emit self->dialogsChanged();
                return;
            }
            self->appendMessages(peer, messages);
        });
    });
}

void ClientBackend::appendMessages(const QString &peer, const QVariantList &messages)
{
    if (messages.isEmpty()) return;
    auto &cache = m_messageCache[peer];
    auto &seen  = m_seenIds[peer];
    for (const auto &msg : messages) {
        const QVariantMap map = msg.toMap();
        const QString id      = map["id"].toString();
        bool hasSeq           = false;
        const quint64 seq     = map["seq"].toULongLong(&hasSeq);
        auto found = cache.end();
        if (!id.isEmpty()) {
            found = std::ranges::find_if(cache, [&id](const QVariant &cached) {
                return cached.toMap().value("id").toString() == id;
            });
        }
        if (found == cache.end() && hasSeq) {
            found = std::ranges::find_if(cache, [seq](const QVariant &cached) {
                bool cachedHasSeq       = false;
                const quint64 cachedSeq = cached.toMap().value("seq").toULongLong(&cachedHasSeq);
                return cachedHasSeq && cachedSeq == seq;
            });
        }
        if (found != cache.end()) {
            *found = msg;
        } else {
            if (!id.isEmpty()) seen.insert(id);
            cache.append(msg);
        }
    }
    std::sort(cache.begin(), cache.end(), [](const QVariant &lhs, const QVariant &rhs) {
        return lhs.toMap()["ts"].toLongLong() < rhs.toMap()["ts"].toLongLong();
    });
    if (!cache.isEmpty())
        if (const auto found = std::ranges::find_if(m_dialogs, [&](const Dialog &d) { return d.peer == peer; });
            found != m_dialogs.end())
            found->lastMsg = cache.last().toMap()["text"].toString();
    saveDialogs();
    seen.clear();
    for (const auto &msg : cache) {
        const QString id = msg.toMap().value("id").toString();
        if (!id.isEmpty()) seen.insert(id);
    }
    emit messagesReceived(peer, cache);
    emit dialogsChanged();
}

void ClientBackend::beginMessagesLoading()
{
    const bool wasLoading = messagesLoading();
    ++m_messageLoadingJobs;
    if (!wasLoading) emit messagesLoadingChanged();
}

void ClientBackend::endMessagesLoading()
{
    const bool wasLoading = messagesLoading();
    m_messageLoadingJobs  = std::max(0, m_messageLoadingJobs - 1);
    if (wasLoading && !messagesLoading()) emit messagesLoadingChanged();
}

void ClientBackend::setNotificationHintPeer(const QString &peer)
{
    if (m_notificationHintPeer == peer) return;
    m_notificationHintPeer = peer;
    emit notificationHintPeerChanged();
}

void ClientBackend::upsertDialogKeyringEntry(const QString &peer, const QByteArray &sessionKey, quint64 startSeq,
                                             bool resetKeyring, bool clearCache)
{
    if (peer.isEmpty() || sessionKey.size() != 32 || startSeq == 0) return;
    for (auto &d : m_dialogs) {
        if (d.peer == peer) {
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
            if (clearCache) {
                m_messageCache.remove(peer);
                m_seenIds.remove(peer);
            }
            emit dialogsChanged();
            saveDialogs();
            scheduleNotifyPoll();
            return;
        }
    }
    m_dialogs.append({peer, QList<DialogKeyEntry>{{startSeq, sessionKey}}, QString()});
    emit dialogsChanged();
    saveDialogs();
    scheduleNotifyPoll();
}

void ClientBackend::onPollTimer() { pollNotifications(false); }

void ClientBackend::onActivePollTimer() { pollNotifications(true); }

void ClientBackend::pollNotifications(bool activeOnly)
{
    if (m_notifyPollInFlight) {
        if (activeOnly)
            scheduleActiveChatPoll();
        else
            scheduleNotifyPoll();
        return;
    }
    if (!isLoggedIn() || m_dialogs.isEmpty()) {
        m_pollTimer->stop();
        m_activePollTimer->stop();
        m_notifiedPendingByPeer.clear();
        return;
    }

    struct NotifyTarget {
        QString peer;
        QString keyringJson;
    };

    QList<NotifyTarget> targets;
    const QString activePeer = m_activePeer;
    if (activeOnly) {
        const auto *dialog = activePeer.isEmpty() ? nullptr : findDialog(activePeer);
        if (dialog) {
            const QString keyringJson = dialogKeyringJson(*dialog);
            if (!keyringJson.isEmpty()) targets.append({dialog->peer, keyringJson});
        }
    } else {
        targets.reserve(m_dialogs.size());
        for (const auto &dialog : m_dialogs) {
            if (!activePeer.isEmpty() && dialog.peer == activePeer) continue;
            const QString keyringJson = dialogKeyringJson(dialog);
            if (!dialog.peer.isEmpty() && !keyringJson.isEmpty()) targets.append({dialog.peer, keyringJson});
        }
    }
    if (targets.isEmpty()) {
        if (activeOnly)
            m_activePollTimer->stop();
        else
            scheduleNotifyPoll();
        return;
    }

    const QString username = m_username;
    QPointer self(this);
    m_notifyPollInFlight = true;
    QThreadPool::globalInstance()->start([self, username, targets, activeOnly]() {
        quint64 total = 0;
        QList<QPair<QString, quint64>> counts;
        QString error;
        bool failed = false;
        if (!self) return;
        {
            QMutexLocker locker(&self->m_ffiMutex);
            if (!self->m_ffi) {
                failed = true;
                error  = "client_not_ready";
            } else {
                for (const auto &target : targets) {
                    uint64_t count = 0;
                    const int rc = self->m_ffi->notify_count_keyring(username, target.peer, target.keyringJson, count);
                    if (rc != 0) {
                        failed = true;
                        error  = ParanoiaFFI::last_error();
                        break;
                    }
                    total += static_cast<quint64>(count);
                    counts.append({target.peer, static_cast<quint64>(count)});
                }
            }
        }
        if (!self) return;
        QMetaObject::invokeMethod(self, [self, total, counts, failed, error, activeOnly]() {
            if (!self) return;
            self->m_notifyPollInFlight = false;
            if (failed) {
                qWarning().noquote() << "Notify polling failed:" << error;
                ++self->m_notifyRetryCount;
                if (activeOnly)
                    self->scheduleActiveChatPoll(self->retryNotifyDelayMs());
                else
                    self->scheduleNotifyPoll(self->retryNotifyDelayMs());
                return;
            }
            self->m_notifyRetryCount = 0;
            if (total > 0) {
                if (activeOnly)
                    self->fetchMessages();
                else {
                    bool hasNewPending  = false;
                    bool pendingChanged = false;
                    QString hintPeer;
                    int pendingPeers = 0;
                    for (const auto &item : counts) {
                        const QString &peer = item.first;
                        const quint64 count = item.second;
                        if (count == 0) {
                            pendingChanged = self->m_notifiedPendingByPeer.remove(peer) > 0 || pendingChanged;
                            continue;
                        }
                        ++pendingPeers;
                        if (pendingPeers == 1)
                            hintPeer = peer;
                        else
                            hintPeer.clear();
                        const quint64 previous = self->m_notifiedPendingByPeer.value(peer, 0);
                        if (count != previous) pendingChanged = true;
                        if (count > previous) hasNewPending = true;
                        self->m_notifiedPendingByPeer[peer] = count;
                    }
                    if (pendingChanged) emit self->dialogsChanged();
                    if (hasNewPending) {
                        self->setNotificationHintPeer(hintPeer);
                        emit self->notificationAvailable(total, hintPeer);
                    }
                }
            } else if (!activeOnly) {
                for (const auto &item : counts) self->m_notifiedPendingByPeer.remove(item.first);
                self->setNotificationHintPeer({});
                emit self->dialogsChanged();
            }
            if (activeOnly)
                self->scheduleActiveChatPoll();
            else
                self->scheduleNotifyPoll();
        });
    });
}

void ClientBackend::onNetworkChanged()
{
    m_notifyRetryCount = 0;
    scheduleNotifyPoll(0);
    if (!m_activePeer.isEmpty()) scheduleActiveChatPoll(0);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

void ClientBackend::scheduleNotifyPoll(int delayMs)
{
    if (!isLoggedIn() || m_dialogs.isEmpty()) {
        m_pollTimer->stop();
        m_activePollTimer->stop();
        PlatformNotifications::stopBackgroundPollingService();
        return;
    }
    PlatformNotifications::startBackgroundPollingService();
    if (delayMs < 0) delayMs = randomNotifyDelayMs();
    m_pollTimer->start(delayMs);
}

void ClientBackend::scheduleActiveChatPoll(int delayMs)
{
    if (!isLoggedIn() || m_activePeer.isEmpty() || !findDialog(m_activePeer)) {
        m_activePollTimer->stop();
        return;
    }
    PlatformNotifications::startBackgroundPollingService();
    if (delayMs < 0) delayMs = randomActiveNotifyDelayMs();
    m_activePollTimer->start(delayMs);
}

int ClientBackend::randomNotifyDelayMs() const { return QRandomGenerator::global()->bounded(2'000, 15'001); }

int ClientBackend::randomActiveNotifyDelayMs() const { return QRandomGenerator::global()->bounded(500, 1'001); }

int ClientBackend::retryNotifyDelayMs() const
{
    const int shift  = std::min(m_notifyRetryCount, 6);
    const int base   = std::min(1000 * (1 << shift), 60'000);
    const int jitter = QRandomGenerator::global()->bounded((base / 5) + 1);
    return base + jitter;
}

QByteArray ClientBackend::deriveKey(const QString &sharedSecret) const
{
    return QCryptographicHash::hash(sharedSecret.toUtf8(), QCryptographicHash::Sha256);
}

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
    QMutexLocker locker(&m_ffiMutex);
    if (m_ffi) {
        uint64_t lastPulled = 0;
        int rc              = m_ffi->last_pulled_seq(m_username, peer, lastPulled);
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
        const QString kind  = obj["kind"].toString(QStringLiteral("text"));
        const QString mimeType = obj["mime_type"].toString();
        const QString cachePath = obj["cache_path"].toString();
        const QString previewSource = isImageAttachment(kind, mimeType) ? localFileUrlIfReadable(cachePath) : QString();
        msg["id"]           = obj["id"].toString();
        msg["sender"]       = obj["sender"].toString();
        msg["kind"]         = kind;
        msg["filename"]     = obj["filename"].toString();
        msg["mime_type"]    = mimeType;
        msg["size"]         = obj.value("size").toVariant().toLongLong();
        msg["downloadable"] = obj["downloadable"].toBool(false);
        msg["downloaded"]   = obj["downloaded"].toBool(false) || !previewSource.isEmpty();
        msg["transfer_id"]  = obj.value("transfer_id").toString();
        msg["body_from_seq"] = obj.value("body_from_seq").toVariant().toULongLong();
        msg["body_to_seq"]  = obj.value("body_to_seq").toVariant().toULongLong();
        msg["cache_path"]   = cachePath;
        msg["preview_source"] = previewSource;
        if (kind == "text")
            msg["text"] = obj.contains("text") ? obj["text"].toString() : extractText(obj["content"].toString());
        else if (kind == "file" || kind == "image" || kind == "voice")
            msg["text"] = obj["filename"].toString(obj["text"].toString("Файл"));
        else
            msg["text"] = QString();
        msg["ts"]   = obj.value("ts").toVariant().toLongLong();
        msg["seq"]  = obj.value("seq").toVariant().toULongLong();
        msg["isMe"] = (obj["sender"].toString() == m_username);
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
        return ParanoiaFFI::errorResult("Неподдерживаемый тип профиля экспорта.");
    if (receiverPubkeyB64.trimmed().isEmpty())
        return ParanoiaFFI::errorResult("Не указан публичный ключ принимающего устройства.");
    if (filePath.trimmed().isEmpty()) return ParanoiaFFI::errorResult("Не указан путь к файлу.");
    // Собрать payload
    QJsonObject payload;
    payload["format_version"] = 1;
    payload["profile_type"]   = normalizedProfile;
    const bool includeClient  = (normalizedProfile == "client" || normalizedProfile == "full");
    const bool includeAdmin   = (normalizedProfile == "admin" || normalizedProfile == "full");
    int exportedDialogues     = 0;
    int exportedKeyEntries    = 0;
    if (includeClient) {
        if (m_server.isEmpty() || m_username.isEmpty() || m_private_key.isEmpty())
            return ParanoiaFFI::errorResult("Нет активной клиентской сессии для экспорта.");
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
            return ParanoiaFFI::errorResult("Нет выбранных диалогов с keyring для экспорта.");
        QJsonObject serverObj;
        serverObj["url"]             = m_server;
        serverObj["username"]        = m_username;
        serverObj["signing_key_b64"] = m_private_key;
        serverObj["dialogues"]       = dialoguesArr;
        payload["servers"]           = QJsonArray{serverObj};
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
    auto envelope = ParanoiaFFI::ecies_encrypt(receiverPubkeyB64.trimmed(), payloadJson);
    if (envelope.isEmpty()) {
        if (ParanoiaFFI::last_error() == "invalid_device_key")
            return ParanoiaFFI::errorResult("Некорректный публичный ключ принимающего устройства.");
        return ParanoiaFFI::errorResult("Ошибка шифрования экспорта.");
    }
    // Сохранить в файл
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

QVariantMap ClientBackend::importProfile(const QString &filePath)
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
    // Расшифровать
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
            return ParanoiaFFI::errorResult("Слишком много client-профилей в export payload.");
        int totalDialogues  = 0;
        int totalKeyEntries = 0;
        for (const auto &serverVal : servers) {
            const auto serverObj     = serverVal.toObject();
            const QString url        = Utils::normalizedServerUrl(serverObj["url"].toString());
            const QString username   = serverObj["username"].toString().trimmed();
            const QString signingKey = serverObj["signing_key_b64"].toString().trimmed();
            if (url.isEmpty() || username.isEmpty()) continue;
            if (!Utils::decodeFixedBase64(signingKey, 32))
                return ParanoiaFFI::errorResult("Некорректный private signing key в client-профиле export payload.");
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
            return ParanoiaFFI::errorResult("Слишком много admin-профилей в export payload.");
        for (const auto &adminVal : adminServers) {
            const auto adminObj       = adminVal.toObject();
            const QString url         = Utils::normalizedServerUrl(adminObj["url"].toString());
            const QString private_key = adminObj["admin_private_key_b64"].toString().trimmed();
            if (url.isEmpty() || private_key.isEmpty()) continue;
            if (!Utils::decodeFixedBase64(private_key, 32))
                return ParanoiaFFI::errorResult("Некорректный private admin key в export payload.");
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
    if (trimmedPath.isEmpty()) return ParanoiaFFI::errorResult("Не указан путь к файлу.");
    if (!QFile::exists(trimmedPath))
        return QVariantMap{{"ok", true}, {"deleted", false}, {"message", "Файл уже удалён."}};
    if (!QFile::remove(trimmedPath))
        return ParanoiaFFI::errorResult("Не удалось удалить файл экспорта: " + trimmedPath);
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
    if (obj.isEmpty()) return;

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
    m_dialogs          = loadDialogsFromPath(path);
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
    auto [privateKey, publicKey] = ParanoiaFFI::ecies_generate_keypair();
    if (!privateKey.isEmpty()) m_devicePrivkey = privateKey;
    saveDeviceKey();
    emit deviceKeyChanged();
}
