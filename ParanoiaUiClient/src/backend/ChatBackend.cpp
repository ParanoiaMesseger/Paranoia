#include "ChatBackend.hpp"

#include "session/Dialog.hpp"
#include "session/SessionStore.hpp"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QDateTime>
#include <QGuiApplication>
#include <QInputMethod>
#include <QMimeDatabase>
#include <QRandomGenerator>
#include <QStandardPaths>
#include <QThreadPool>
#include <QPointer>
#include <QDebug>
#include <QDir>
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
    { return urlOrPath.startsWith(QStringLiteral("content://"), Qt::CaseInsensitive); }

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
        const QString base   = suffix.isEmpty() ? safeName : safeName.left(safeName.size() - suffix.size() - 1);
        QString candidate    = safeName;
        for (int i = 1; dir.exists(candidate); ++i) {
            candidate = suffix.isEmpty() ? QStringLiteral("%1 (%2)").arg(base).arg(i)
                                         : QStringLiteral("%1 (%2).%3").arg(base).arg(i).arg(suffix);
        }
        return dir.filePath(candidate);
    }

    bool isImageAttachment(const QString &kind, const QString &mimeType)
    { return kind == QStringLiteral("image") || mimeType.startsWith(QStringLiteral("image/"), Qt::CaseInsensitive); }

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
        if (error.contains(QStringLiteral("attachment_bad_size"), Qt::CaseInsensitive) ||
            error.contains(QStringLiteral("attachment_bad_chunk"), Qt::CaseInsensitive))
            return QStringLiteral("Вложение повреждено. Попросите отправить файл повторно.");
        return error;
    }

    QVariantList reactionsForEvents(const QVariantList &events, const QString &myId, const QString &myUsername,
                                    const QMap<QString, QString> &peerIdToUsername)
    {
        QVariantList reactions;
        QSet<QString> seen;
        for (const auto &eventValue : events) {
            const QVariantMap event = eventValue.toMap();
            const QString emoji     = event.value(QStringLiteral("emoji")).toString();
            const QString sender    = event.value(QStringLiteral("sender")).toString();
            if (emoji.isEmpty() || sender.isEmpty()) continue;
            const QString key = sender + QChar('\n') + emoji;
            if (seen.contains(key)) continue;
            seen.insert(key);
            const bool mine = !myId.isEmpty() && sender == myId;
            QString senderName;
            if (mine)
                senderName = myUsername;
            else
                senderName = peerIdToUsername.value(sender);
            if (senderName.isEmpty()) senderName = sender;
            reactions.append(QVariantMap{
                {QStringLiteral("emoji"), emoji},
                {QStringLiteral("sender"), sender},
                {QStringLiteral("sender_name"), senderName},
                {QStringLiteral("mine"), mine},
            });
        }
        return reactions;
    }

    void applyReactionToCache(QVariantList &cache, const QVariantMap &reaction, const QString &myId,
                              const QString &myUsername, const QMap<QString, QString> &peerIdToUsername)
    {
        const QString targetId = reaction.value(QStringLiteral("target_id")).toString();
        const QString emoji =
            reaction.value(QStringLiteral("emoji"), reaction.value(QStringLiteral("text"))).toString();
        const QString sender = reaction.value(QStringLiteral("sender")).toString();
        if (targetId.isEmpty() || emoji.isEmpty() || sender.isEmpty()) return;

        for (auto &messageValue : cache) {
            QVariantMap message = messageValue.toMap();
            if (message.value(QStringLiteral("id")).toString() != targetId) continue;

            QVariantList events = message.value(QStringLiteral("reaction_events")).toList();
            bool replaced       = false;
            for (auto &eventValue : events) {
                QVariantMap event = eventValue.toMap();
                if (event.value(QStringLiteral("sender")).toString() != sender) continue;
                event[QStringLiteral("emoji")] = emoji;
                eventValue                     = event;
                replaced                       = true;
                break;
            }
            if (!replaced) {
                events.append(QVariantMap{
                    {QStringLiteral("sender"), sender},
                    {QStringLiteral("emoji"), emoji},
                });
            }
            const QVariantList reactionsList           = reactionsForEvents(events, myId, myUsername, peerIdToUsername);
            message[QStringLiteral("reaction_events")] = events;
            message[QStringLiteral("reactions")]       = reactionsList;
            message[QStringLiteral("reactions_json")]  = QString::fromUtf8(
                QJsonDocument(QJsonArray::fromVariantList(reactionsList)).toJson(QJsonDocument::Compact));
            messageValue = message;
            return;
        }
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
            context.object<jobject>(), javaPath.object<jstring>(), javaUri.object<jstring>(),
            javaName.object<jstring>());
        clearPendingAndroidException();
        return ok;
    }
#else
    void requestAndroidFileAccessIfNeeded() {}
#endif

    bool applicationIsActive() { return QGuiApplication::applicationState() == Qt::ApplicationActive; }
}

ChatBackend::ChatBackend(QObject *parent) : QObject(parent)
{
    m_activePollTimer = new QTimer(this);
    m_activePollTimer->setSingleShot(true);
    connect(m_activePollTimer, &QTimer::timeout, this, &ChatBackend::onActivePollTimer);
    connect(qApp, &QGuiApplication::applicationStateChanged, this, &ChatBackend::onApplicationStateChanged);
}

ChatBackend::~ChatBackend() { m_activePollTimer->stop(); }

bool ChatBackend::messagesLoading() const { return m_messageLoadingJobs > 0; }

bool ChatBackend::readReceiptsEnabled() const
{
    auto session = SessionStore::instance()->activeSession();
    if (!session || m_activePeer.isEmpty()) return true;
    const auto *dialog = session->findDialog(m_activePeer);
    return dialog ? dialog->receiptsEnabled : true;
}

// ── Chat ──────────────────────────────────────────────────────────────────────

void ChatBackend::openChat(const QString &peer)
{
    m_activePeer = peer;
    emit activePeerChanged(peer);
    emit readReceiptsEnabledChanged();
    auto session = SessionStore::instance()->activeSession();
    if (session && session->isLoggedIn() && session->findDialog(peer)) {
        loadHistory(peer);
        fetchMessages();
        refreshArrivedStatus();
        scheduleActiveChatPoll(0);
    }
}

void ChatBackend::stopChat()
{
    m_activePeer.clear();
    m_activePollTimer->stop();
    emit activePeerChanged({});
    emit readReceiptsEnabledChanged();
}

void ChatBackend::sendText(const QString &text)
{
    if (m_activePeer.isEmpty()) {
        emit sendError("Нет активного диалога.");
        return;
    }
    auto session = SessionStore::instance()->activeSession();
    if (!session) {
        emit sendError("Нет активной сессии.");
        return;
    }
    auto *dlg = session->findDialog(m_activePeer);
    if (!dlg) {
        emit sendError("Диалог не найден.");
        return;
    }
    const QString peer         = m_activePeer;
    const QString serverId     = session->serverId;
    const QString peerServerId = dlg->peerServerId;
    const QString keyringJson  = dlg->keyringJson();
    const QString sendKey      = peer + QChar('\n') + text;
    const qint64 nowMs         = QDateTime::currentMSecsSinceEpoch();
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
    QThreadPool::globalInstance()->start([self, session, peer, serverId, peerServerId, text, keyringJson, sendKey]() {
        if (!self) return;
        QString json;
        QString err;
        {
            QMutexLocker locker(&session->ffiMutex);
            if (!session->ffi) {
                err = "client_not_ready";
            } else {
                const QString peerId = peerServerId.isEmpty() ? peer : peerServerId;
                json                 = session->ffi->send_text_json_keyring(serverId, peerId, keyringJson, text);
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
            if (peer == self->m_activePeer) {
                self->fetchMessages();
                self->refreshArrivedStatus();
                self->scheduleActiveChatPoll(0);
            }
        });
    });
}

void ChatBackend::sendReaction(const QString &targetId, const QString &emoji)
{
    const QString trimmedTarget = targetId.trimmed();
    const QString trimmedEmoji  = emoji.trimmed();
    if (m_activePeer.isEmpty() || trimmedTarget.isEmpty() || trimmedEmoji.isEmpty() || trimmedEmoji.size() > 16) return;

    auto session = SessionStore::instance()->activeSession();
    if (!session) {
        emit sendError("Нет активной сессии.");
        return;
    }
    auto *dlg = session->findDialog(m_activePeer);
    if (!dlg) {
        emit sendError("Диалог не найден.");
        return;
    }

    const QString peer         = m_activePeer;
    const QString serverId     = session->serverId;
    const QString peerServerId = dlg->peerServerId;
    const QString keyringJson  = dlg->keyringJson();
    const QString sendKey =
        peer + QChar('\n') + QStringLiteral("reaction") + QChar('\n') + trimmedTarget + QChar('\n') + trimmedEmoji;
    if (m_sendInFlightKeys.contains(sendKey)) return;
    m_sendInFlightKeys.insert(sendKey);

    QPointer self(this);
    QThreadPool::globalInstance()->start(
        [self, session, peer, serverId, peerServerId, keyringJson, trimmedTarget, trimmedEmoji, sendKey]() {
            if (!self) return;
            QString json;
            QString err;
            {
                QMutexLocker locker(&session->ffiMutex);
                if (!session->ffi) {
                    err = "client_not_ready";
                } else {
                    const QString peerId = peerServerId.isEmpty() ? peer : peerServerId;
                    json = session->ffi->send_reaction_json_keyring(serverId, peerId, keyringJson, trimmedTarget,
                                                                    trimmedEmoji);
                    if (json.isEmpty()) err = ParanoiaFFI::last_error();
                }
            }
            if (json.isEmpty()) {
                QMetaObject::invokeMethod(self, [self, err, sendKey]() {
                    if (!self) return;
                    self->m_sendInFlightKeys.remove(sendKey);
                    if (err == "server_unavailable")
                        emit self->sendError("Сервер недоступен. Проверьте соединение.");
                    else
                        emit self->sendError("Ошибка отправки реакции.");
                });
                return;
            }
            QMetaObject::invokeMethod(self, [self, peer, json, sendKey]() {
                if (!self) return;
                self->m_sendInFlightKeys.remove(sendKey);
                self->appendMessages(peer, self->parseMessages(json));
                if (peer == self->m_activePeer) {
                    self->fetchMessages();
                    self->scheduleActiveChatPoll(0);
                }
            });
        });
}

void ChatBackend::sendFile(const QString &fileUrlOrPath)
{
    if (m_activePeer.isEmpty()) {
        emit sendError("Нет активного диалога.");
        return;
    }
    auto session = SessionStore::instance()->activeSession();
    if (!session) {
        emit sendError("Нет активной сессии.");
        return;
    }
    auto *dlg = session->findDialog(m_activePeer);
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

    const QString peer         = m_activePeer;
    const QString serverId     = session->serverId;
    const QString peerServerId = dlg->peerServerId;
    const QString keyringJson  = dlg->keyringJson();
    const QString sendKey =
        peer + QChar('\n') + (sourceIsContent ? source : originalPath) + QChar('\n') + QString::number(originalSize);
    if (m_sendInFlightKeys.contains(sendKey)) return;
    m_sendInFlightKeys.insert(sendKey);

    QPointer self(this);
    QThreadPool::globalInstance()->start([self, session, peer, serverId, peerServerId, keyringJson, source,
                                          sourceIsContent, originalPath, originalMimeType, sendKey]() {
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
            QMutexLocker locker(&session->ffiMutex);
            if (!err.isEmpty()) {
                // keep classified file error from Android/content resolver path
            } else if (!session->ffi) {
                err = "client_not_ready";
            } else {
                const QString peerId = peerServerId.isEmpty() ? peer : peerServerId;
                json = session->ffi->send_file_json_keyring(serverId, peerId, keyringJson, path, mimeType);
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
            if (peer == self->m_activePeer) {
                self->fetchMessages();
                self->refreshArrivedStatus();
                self->scheduleActiveChatPoll(0);
            }
        });
    });
}

void ChatBackend::saveAttachment(const QString &messageId, const QString &targetUrlOrPath)
{
    if (m_activePeer.isEmpty() || messageId.isEmpty()) return;
    auto session = SessionStore::instance()->activeSession();
    if (!session) return;
    const auto *dlg = session->findDialog(m_activePeer);
    if (!dlg) return;
    requestAndroidFileAccessIfNeeded();
    const QString target       = targetUrlOrPath.trimmed();
    const bool targetIsContent = isContentUri(target);

    QString filename = QStringLiteral("attachment.bin");
    for (const auto &cached : m_messageCache.value(m_activePeer)) {
        const QVariantMap msg = cached.toMap();
        if (msg.value("id").toString() == messageId) {
            const QString fn  = msg.value("filename").toString();
            const QString txt = msg.value("text").toString();
            filename          = !fn.isEmpty() ? fn : (!txt.isEmpty() ? txt : filename);
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
        path = targetInfo.exists() && targetInfo.isDir() ? uniqueFilePath(localTarget, filename) : localTarget;
    }
    if (path.isEmpty()) return;
    const QString peer         = m_activePeer;
    const QString serverId     = session->serverId;
    const QString peerServerId = dlg->peerServerId;
    const QString keyringJson  = dlg->keyringJson();
    QPointer self(this);
    QThreadPool::globalInstance()->start([self, session, peer, serverId, peerServerId, keyringJson, messageId, path,
                                          target, targetIsContent, filename]() {
        if (!self) return;
        int rc = -1;
        QString err;
        {
            QMutexLocker locker(&session->ffiMutex);
            if (!session->ffi) {
                err = "client_not_ready";
            } else {
                const QString peerId = peerServerId.isEmpty() ? peer : peerServerId;
                rc = session->ffi->save_attachment_keyring(serverId, peerId, keyringJson, messageId, path);
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

void ChatBackend::ensureImagePreview(const QString &messageId)
{
    if (m_activePeer.isEmpty() || messageId.isEmpty()) return;
    auto session = SessionStore::instance()->activeSession();
    if (!session) return;
    const auto *dlg = session->findDialog(m_activePeer);
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

    const QString peer         = m_activePeer;
    const QString serverId     = session->serverId;
    const QString peerServerId = dlg->peerServerId;
    const QString keyringJson  = dlg->keyringJson();
    QPointer self(this);
    QThreadPool::globalInstance()->start(
        [self, session, peer, serverId, peerServerId, keyringJson, messageId, requestKey]() {
            if (!self) return;
            QString path;
            QString err;
            {
                QMutexLocker locker(&session->ffiMutex);
                if (!session->ffi) {
                    err = QStringLiteral("client_not_ready");
                } else {
                    const QString peerId = peerServerId.isEmpty() ? peer : peerServerId;
                    path = session->ffi->cache_attachment_keyring(serverId, peerId, keyringJson, messageId);
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

void ChatBackend::deleteMessagesUntil(quint64 cutSeq)
{
    if (m_activePeer.isEmpty() || cutSeq == 0) return;
    auto session = SessionStore::instance()->activeSession();
    if (!session) return;
    const auto *dlg = session->findDialog(m_activePeer);
    if (!dlg) return;

    const QString peer         = m_activePeer;
    const QString serverId     = session->serverId;
    const QString peerServerId = dlg->peerServerId;
    const QString keyringJson  = dlg->keyringJson();
    QPointer self(this);
    QThreadPool::globalInstance()->start([self, session, peer, serverId, peerServerId, keyringJson, cutSeq]() {
        if (!self) return;
        int localRc  = -1;
        int serverRc = -1;
        QString err;
        {
            QMutexLocker locker(&session->ffiMutex);
            if (!session->ffi) {
                err = "client_not_ready";
            } else {
                const QString peerId = peerServerId.isEmpty() ? peer : peerServerId;
                localRc              = session->ffi->delete_local_until_keyring(serverId, peerId, keyringJson, cutSeq);
                if (localRc != 0) {
                    err = ParanoiaFFI::last_error();
                } else {
                    serverRc = session->ffi->determinate_keyring(serverId, peerId, keyringJson, cutSeq);
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
                    const quint64 seq     = map.value("seq").toULongLong(&ok);
                    if (ok && seq <= cutSeq) continue;
                    kept.append(msg);
                    const QString id = map.value("id").toString();
                    if (!id.isEmpty()) keptIds.insert(id);
                }
                cache                 = kept;
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

void ChatBackend::setReadReceiptsEnabled(bool enabled)
{
    if (m_activePeer.isEmpty()) return;
    auto session = SessionStore::instance()->activeSession();
    if (!session) return;
    auto *dlg = session->findDialog(m_activePeer);
    if (!dlg) return;
    if (dlg->receiptsEnabled == enabled) return;

    const QString peer         = m_activePeer;
    const QString serverId     = session->serverId;
    const QString peerServerId = dlg->peerServerId;
    const QString keyringJson  = dlg->keyringJson();
    const bool previous        = dlg->receiptsEnabled;
    dlg->receiptsEnabled       = enabled;
    session->saveDialogs();
    emit readReceiptsEnabledChanged();
    emit dialogsChanged();

    QPointer self(this);
    QThreadPool::globalInstance()->start(
        [self, session, peer, serverId, peerServerId, keyringJson, enabled, previous]() {
            if (!self) return;
            int rc = -1;
            QString err;
            {
                QMutexLocker locker(&session->ffiMutex);
                if (!session->ffi) {
                    err = "client_not_ready";
                } else {
                    const QString myId   = serverId.isEmpty() ? session->username : serverId;
                    const QString peerId = peerServerId.isEmpty() ? peer : peerServerId;
                    rc                   = session->ffi->arrived_put_keyring(myId, peerId, keyringJson, enabled);
                    if (rc != 0) err = ParanoiaFFI::last_error();
                }
            }
            if (rc == 0 || !self) return;
            QMetaObject::invokeMethod(self, [self, session, peer, previous, err]() {
                if (!self) return;
                if (auto *dialog = session->findDialog(peer)) {
                    dialog->receiptsEnabled = previous;
                    session->saveDialogs();
                }
                if (peer == self->m_activePeer) emit self->readReceiptsEnabledChanged();
                emit self->dialogsChanged();
                emit self->receiveError("Не удалось изменить уведомления о прочтении: " + err);
            });
        });
}

void ChatBackend::fetchMessages()
{
    if (m_activePeer.isEmpty()) return;
    if (!applicationIsActive()) return;
    if (m_receiveInFlight) {
        m_receiveAgainAfterCurrent = true;
        return;
    }
    auto session = SessionStore::instance()->activeSession();
    if (!session) return;
    const auto *dlg = session->findDialog(m_activePeer);
    if (!dlg) return;
    const QString peer         = m_activePeer;
    const QString serverId     = session->serverId;
    const QString peerServerId = dlg->peerServerId;
    const QString keyringJson  = dlg->keyringJson();
    const QString profileId    = session->profileId;
    QPointer self(this);
    m_receiveInFlight = true;
    beginMessagesLoading();
    QThreadPool::globalInstance()->start([self, session, peer, serverId, peerServerId, keyringJson, profileId]() {
        if (!self) return;
        QString json;
        QString lastErr;
        {
            QMutexLocker locker(&session->ffiMutex);
            if (!session->ffi) {
                lastErr = "client_not_ready";
            } else {
                const QString peerId = peerServerId.isEmpty() ? peer : peerServerId;
                json                 = session->ffi->receive_keyring(serverId, peerId, keyringJson);
                lastErr              = ParanoiaFFI::last_error();
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
        QMetaObject::invokeMethod(self, [self, json, peer, profileId, lastErr]() {
            if (!self) return;
            self->m_receiveInFlight = false;
            self->endMessagesLoading();
            if (lastErr.startsWith("decryption_failed:"))
                emit self->receiveError("Ошибка расшифровки: неверный ключ диалога или повреждённые данные.");
            const QVariantList messages = self->parseMessages(json);
            const bool appActive        = applicationIsActive();
            if (peer == self->m_activePeer) {
                self->appendMessages(peer, messages);
                if (appActive) emit self->peerMessagesRead(peer);
            }
            if (!appActive && !messages.isEmpty()) {
                emit self->backgroundMessagesReceived(profileId, peer, static_cast<quint64>(messages.size()));
            }
            if (self->m_receiveAgainAfterCurrent) {
                self->m_receiveAgainAfterCurrent = false;
                self->fetchMessages();
            }
        });
    });
}

void ChatBackend::requestFileAccessPermissions() { requestAndroidFileAccessIfNeeded(); }

void ChatBackend::commitInputMethod()
{
    if (auto *inputMethod = QGuiApplication::inputMethod()) inputMethod->commit();
}

// ── Cross-backend slots ───────────────────────────────────────────────────────

void ChatBackend::onDialogRemoved(const QString &peer)
{
    m_messageCache.remove(peer);
    m_seenIds.remove(peer);
    if (m_activePeer == peer) {
        m_activePeer.clear();
        m_activePollTimer->stop();
        emit readReceiptsEnabledChanged();
    }
}

void ChatBackend::onSessionReset()
{
    m_messageCache.clear();
    m_seenIds.clear();
    m_activePeer.clear();
    m_activePollTimer->stop();
    m_receiveInFlight          = false;
    m_receiveAgainAfterCurrent = false;
    m_arrivedInFlight          = false;
    emit readReceiptsEnabledChanged();
}

void ChatBackend::onNetworkRestored()
{
    m_activePollRetryCount = 0;
    scheduleActiveChatPoll(0);
}

void ChatBackend::onApplicationStateChanged(Qt::ApplicationState state)
{
    if (state == Qt::ApplicationActive) {
        m_activePollRetryCount = 0;
        scheduleActiveChatPoll(0);
    } else {
        m_activePollTimer->stop();
    }
}

// ── Active chat poll ──────────────────────────────────────────────────────────

void ChatBackend::onActivePollTimer() { pollActiveChat(); }

void ChatBackend::pollActiveChat()
{
    if (m_activePollInFlight) {
        scheduleActiveChatPoll();
        return;
    }
    if (!applicationIsActive()) {
        m_activePollTimer->stop();
        return;
    }
    auto session = SessionStore::instance()->activeSession();
    if (!session || !session->isLoggedIn() || m_activePeer.isEmpty()) {
        m_activePollTimer->stop();
        return;
    }
    const auto *dialog = session->findDialog(m_activePeer);
    if (!dialog) {
        m_activePollTimer->stop();
        return;
    }
    const QString keyringJson = dialog->keyringJson();
    if (keyringJson.isEmpty()) {
        m_activePollTimer->stop();
        return;
    }
    const QString peer         = m_activePeer;
    const QString serverId     = session->serverId;
    const QString peerServerId = dialog->peerServerId;
    QPointer self(this);
    m_activePollInFlight = true;
    QThreadPool::globalInstance()->start([self, session, peer, serverId, peerServerId, keyringJson]() {
        if (!self) return;
        uint64_t count = 0;
        bool failed    = false;
        QString error;
        {
            QMutexLocker locker(&session->ffiMutex);
            if (!session->ffi) {
                failed = true;
                error  = "client_not_ready";
            } else {
                const QString peerId = peerServerId.isEmpty() ? peer : peerServerId;
                const int rc         = session->ffi->notify_count_keyring(serverId, peerId, keyringJson, count);
                if (rc != 0) {
                    failed = true;
                    error  = ParanoiaFFI::last_error();
                }
            }
        }
        if (!self) return;
        QMetaObject::invokeMethod(self, [self, count, failed, error]() {
            if (!self) return;
            self->m_activePollInFlight = false;
            if (failed) {
                qWarning().noquote() << "Active chat poll failed:" << error;
                ++self->m_activePollRetryCount;
                self->scheduleActiveChatPoll(self->retryActiveNotifyDelayMs());
                return;
            }
            self->m_activePollRetryCount = 0;
            if (count > 0) self->fetchMessages();
            self->refreshArrivedStatus();
            self->scheduleActiveChatPoll();
        });
    });
}

void ChatBackend::refreshArrivedStatus()
{
    if (m_arrivedInFlight) return;
    if (!applicationIsActive()) return;
    auto session = SessionStore::instance()->activeSession();
    if (!session || !session->isLoggedIn() || m_activePeer.isEmpty()) return;
    const auto *dialog = session->findDialog(m_activePeer);
    if (!dialog) return;
    const QString keyringJson = dialog->keyringJson();
    if (keyringJson.isEmpty()) return;

    const QString peer         = m_activePeer;
    const QString serverId     = session->serverId;
    const QString peerServerId = dialog->peerServerId;
    QPointer self(this);
    m_arrivedInFlight = true;
    QThreadPool::globalInstance()->start([self, session, peer, serverId, peerServerId, keyringJson]() {
        if (!self) return;
        uint64_t changed = 0;
        bool failed      = false;
        QString error;
        {
            QMutexLocker locker(&session->ffiMutex);
            if (!session->ffi) {
                failed = true;
                error  = "client_not_ready";
            } else {
                const QString myId   = serverId.isEmpty() ? session->username : serverId;
                const QString peerId = peerServerId.isEmpty() ? peer : peerServerId;
                const int rc         = session->ffi->arrived_get_keyring(myId, peerId, keyringJson, changed);
                if (rc != 0) {
                    failed = true;
                    error  = ParanoiaFFI::last_error();
                }
            }
        }
        QMetaObject::invokeMethod(self, [self, peer, changed, failed, error]() {
            if (!self) return;
            self->m_arrivedInFlight = false;
            if (failed) {
                qWarning().noquote() << "Arrived status refresh failed:" << error;
                return;
            }
            if (changed > 0 && peer == self->m_activePeer) self->loadHistory(peer);
        });
    });
}

void ChatBackend::scheduleActiveChatPoll(int delayMs)
{
    auto session = SessionStore::instance()->activeSession();
    if (!applicationIsActive() || !session || !session->isLoggedIn() || m_activePeer.isEmpty() ||
        !session->findDialog(m_activePeer)) {
        m_activePollTimer->stop();
        return;
    }
    if (delayMs < 0) delayMs = randomActiveNotifyDelayMs();
    m_activePollTimer->start(delayMs);
}

int ChatBackend::randomActiveNotifyDelayMs() { return QRandomGenerator::global()->bounded(500, 1'001); }

int ChatBackend::retryActiveNotifyDelayMs() const
{
    const int shift  = std::min(m_activePollRetryCount, 6);
    const int base   = std::min(1000 * (1 << shift), 60'000);
    const int jitter = QRandomGenerator::global()->bounded((base / 5) + 1);
    return base + jitter;
}

// ── Message helpers ───────────────────────────────────────────────────────────

void ChatBackend::loadHistory(const QString &peer)
{
    auto session = SessionStore::instance()->activeSession();
    if (!session) return;
    const auto *dlg = session->findDialog(peer);
    if (!dlg) return;
    const QString serverId     = session->serverId;
    const QString peerServerId = dlg->peerServerId;
    const QString keyringJson  = dlg->keyringJson();
    QPointer self(this);
    beginMessagesLoading();
    QThreadPool::globalInstance()->start([self, session, peer, serverId, peerServerId, keyringJson]() {
        if (!self) return;
        QString json;
        {
            QMutexLocker locker(&session->ffiMutex);
            if (session->ffi) {
                const QString peerId = peerServerId.isEmpty() ? peer : peerServerId;
                json                 = session->ffi->history_keyring(serverId, peerId, keyringJson, 500);
            }
        }
        QMetaObject::invokeMethod(self, [self, peer, json]() {
            if (!self) return;
            self->endMessagesLoading();
            if (peer != self->m_activePeer) return;
            if (json.isEmpty()) return;
            const QVariantList messages = self->parseMessages(json);
            self->m_messageCache[peer].clear();
            self->m_seenIds[peer].clear();
            self->m_appliedReactionIds[peer].clear();
            if (messages.isEmpty()) {
                emit self->messagesReceived(peer, QVariantList{});
                emit self->dialogsChanged();
                return;
            }
            self->appendMessages(peer, messages);
        });
    });
}

void ChatBackend::appendMessages(const QString &peer, const QVariantList &messages)
{
    if (messages.isEmpty()) return;
    auto &cache            = m_messageCache[peer];
    auto &seen             = m_seenIds[peer];
    auto &appliedReactions = m_appliedReactionIds[peer];
    QVariantList reactions;
    const auto session = SessionStore::instance()->activeSession();
    const QString myId = session ? (session->serverId.isEmpty() ? session->username : session->serverId) : QString();
    const QString myUsername = session ? session->username : QString();
    QMap<QString, QString> peerIdToUsername;
    if (session) {
        for (const auto &d : session->dialogs) {
            if (!d.peerServerId.isEmpty()) peerIdToUsername.insert(d.peerServerId, d.peer);
            if (!d.peer.isEmpty()) peerIdToUsername.insert(d.peer, d.peer);
        }
    }
    for (const auto &msg : messages) {
        const QVariantMap map = msg.toMap();
        const QString id      = map["id"].toString();
        if (map.value(QStringLiteral("kind")).toString() == QStringLiteral("reaction")) {
            if (!id.isEmpty() && appliedReactions.contains(id)) continue;
            if (!id.isEmpty()) appliedReactions.insert(id);
            reactions.append(map);
            continue;
        }
        bool hasSeq       = false;
        const quint64 seq = map["seq"].toULongLong(&hasSeq);
        auto found        = cache.end();
        if (!id.isEmpty()) {
            found = std::ranges::find_if(
                cache, [&id](const QVariant &cached) { return cached.toMap().value("id").toString() == id; });
        }
        if (found == cache.end() && hasSeq) {
            found = std::ranges::find_if(cache, [seq](const QVariant &cached) {
                bool cachedHasSeq       = false;
                const quint64 cachedSeq = cached.toMap().value("seq").toULongLong(&cachedHasSeq);
                return cachedHasSeq && cachedSeq == seq;
            });
        }
        if (found != cache.end()) {
            QVariantMap updated        = map;
            const QVariantMap existing = found->toMap();
            if (existing.contains(QStringLiteral("reaction_events")))
                updated[QStringLiteral("reaction_events")] = existing.value(QStringLiteral("reaction_events"));
            if (existing.contains(QStringLiteral("reactions")))
                updated[QStringLiteral("reactions")] = existing.value(QStringLiteral("reactions"));
            if (existing.contains(QStringLiteral("reactions_json")))
                updated[QStringLiteral("reactions_json")] = existing.value(QStringLiteral("reactions_json"));
            *found = updated;
        } else {
            if (!id.isEmpty()) seen.insert(id);
            cache.append(msg);
        }
    }
    std::sort(cache.begin(), cache.end(), [](const QVariant &lhs, const QVariant &rhs) {
        return lhs.toMap()["ts"].toLongLong() < rhs.toMap()["ts"].toLongLong();
    });
    for (const auto &reaction : reactions)
        applyReactionToCache(cache, reaction.toMap(), myId, myUsername, peerIdToUsername);
    if (session && !cache.isEmpty()) {
        auto &dialogs = session->dialogs;
        if (const auto found = std::ranges::find_if(dialogs, [&](const Dialog &d) { return d.peer == peer; });
            found != dialogs.end())
            found->lastMsg = cache.last().toMap()["text"].toString();
        session->saveDialogs();
    }
    seen.clear();
    for (const auto &msg : cache) {
        const QString id = msg.toMap().value("id").toString();
        if (!id.isEmpty()) seen.insert(id);
    }
    emit messagesReceived(peer, cache);
    emit dialogsChanged();
}

void ChatBackend::beginMessagesLoading()
{
    const bool wasLoading = messagesLoading();
    ++m_messageLoadingJobs;
    if (!wasLoading) emit messagesLoadingChanged();
}

void ChatBackend::endMessagesLoading()
{
    const bool wasLoading = messagesLoading();
    m_messageLoadingJobs  = std::max(0, m_messageLoadingJobs - 1);
    if (wasLoading && !messagesLoading()) emit messagesLoadingChanged();
}

QVariantList ChatBackend::parseMessages(const QString &json)
{
    const auto session = SessionStore::instance()->activeSession();
    const QString myId = session ? (session->serverId.isEmpty() ? session->username : session->serverId) : QString();
    auto doc           = QJsonDocument::fromJson(json.toUtf8());
    if (!doc.isArray()) return {};
    QVariantList result;
    for (const auto &val : doc.array()) {
        auto obj = val.toObject();
        QVariantMap msg;
        const QString kind          = obj["kind"].toString(QStringLiteral("text"));
        const QString mimeType      = obj["mime_type"].toString();
        const QString cachePath     = obj["cache_path"].toString();
        const QString previewSource = isImageAttachment(kind, mimeType) ? localFileUrlIfReadable(cachePath) : QString();
        msg["id"]                   = obj["id"].toString();
        msg["sender"]               = obj["sender"].toString();
        msg["status"]               = obj["status"].toString(QStringLiteral("pending"));
        msg["kind"]                 = kind;
        msg["filename"]             = obj["filename"].toString();
        msg["mime_type"]            = mimeType;
        msg["size"]                 = obj.value("size").toVariant().toLongLong();
        msg["downloadable"]         = obj["downloadable"].toBool(false);
        msg["downloaded"]           = obj["downloaded"].toBool(false) || !previewSource.isEmpty();
        msg["transfer_id"]          = obj.value("transfer_id").toString();
        msg["body_from_seq"]        = obj.value("body_from_seq").toVariant().toULongLong();
        msg["body_to_seq"]          = obj.value("body_to_seq").toVariant().toULongLong();
        msg["cache_path"]           = cachePath;
        msg["preview_source"]       = previewSource;
        if (kind == "text")
            msg["text"] = obj.contains("text") ? obj["text"].toString() : extractText(obj["content"].toString());
        else if (kind == "file" || kind == "image" || kind == "voice")
            msg["text"] = obj["filename"].toString(obj["text"].toString("Файл"));
        else if (kind == "reaction") {
            msg["text"]      = obj["text"].toString();
            msg["emoji"]     = obj["emoji"].toString(obj["text"].toString());
            msg["target_id"] = obj["target_id"].toString();
        } else
            msg["text"] = obj["text"].toString();
        msg["ts"]                = obj.value("ts").toVariant().toLongLong();
        msg["seq"]               = obj.value("seq").toVariant().toULongLong();
        msg["isMe"]              = (obj["sender"].toString() == myId);
        msg["reactions_json"]    = QStringLiteral("[]");
        const bool nonVisualKind = kind == QStringLiteral("read_receipt") || kind == QStringLiteral("delete") ||
                                   kind == QStringLiteral("file_header") || kind == QStringLiteral("file_chunk");
        if (!nonVisualKind) result.append(msg);
    }
    return result;
}

QString ChatBackend::extractText(const QString &raw)
{
    // Parse Rust Debug format: Text("hello") → hello
    if (raw.startsWith("Text(\"") && raw.endsWith("\")")) return raw.mid(6, raw.length() - 8);
    if (raw.startsWith("Image(")) return "[Изображение]";
    if (raw.startsWith("File(")) return "[Файл]";
    if (raw.startsWith("Voice(")) return "[Голосовое]";
    if (raw.startsWith("ReadReceipt(") || raw.startsWith("Delete(")) return QString();
    return raw;
}
