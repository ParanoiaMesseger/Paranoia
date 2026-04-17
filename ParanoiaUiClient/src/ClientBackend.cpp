#include "ClientBackend.h"
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <QJsonParseError>
#include <QCryptographicHash>
#include <QThreadPool>
#include <QPointer>
#include <QDebug>
#include <QFile>
#include <QDir>
#include <QFileInfo>
#include <QDateTime>
#include <QBuffer>
#include <QImage>
#include <QPainter>
#include <QUrl>
#include <ReadBarcode.h>
#include <Barcode.h>
#include <ImageView.h>
#include <ReaderOptions.h>
#include <qrcodegen.hpp>
#include <algorithm>
#include <exception>

namespace {
constexpr qint64 MaxExportFileBytes = 16 * 1024 * 1024;
constexpr int MaxImportServers = 16;
constexpr int MaxImportAdminServers = 16;
constexpr int MaxImportDialogues = 1024;
constexpr int MaxImportKeyEntries = 8192;

void setOwnerOnlyPermissions(const QString &path);

QString takeRustString(char *ptr)
{
    if (!ptr) return QString();
    QString value = QString::fromUtf8(ptr);
    paranoia_free_string(ptr);
    return value;
}

QString lastRustError()
{
    const char *err = paranoia_last_error();
    return err ? QString::fromUtf8(err) : QString();
}

QVariantMap errorResult(const QString &message)
{
    return QVariantMap{{"ok", false}, {"error", message}};
}

QString compactJson(const QJsonValue &value)
{
    if (value.isObject()) {
        return QString::fromUtf8(QJsonDocument(value.toObject()).toJson(QJsonDocument::Compact));
    }
    if (value.isArray()) {
        return QString::fromUtf8(QJsonDocument(value.toArray()).toJson(QJsonDocument::Compact));
    }
    return QString();
}

bool isSupportedExportProfile(const QString &profileType)
{
    return profileType == "client" || profileType == "admin" || profileType == "full";
}

QString normalizedServerUrl(const QString &server)
{
    QString url = server.trimmed();
    if (url.isEmpty()) return QString();
    if (!url.startsWith("http://") && !url.startsWith("https://"))
        url = "https://" + url;
    while (url.endsWith('/') && !url.endsWith("://"))
        url.chop(1);
    return url;
}

QString profileIdFor(const QString &server, const QString &username)
{
    const QByteArray input = normalizedServerUrl(server).toUtf8() + "\n" + username.trimmed().toUtf8();
    return QString::fromLatin1(QCryptographicHash::hash(input, QCryptographicHash::Sha256).toHex());
}

QString profilesRootPath()
{
    return QStringLiteral("profiles");
}

QString profilesManifestPath()
{
    return QStringLiteral("profiles.json");
}

QString profileDirPath(const QString &profileId)
{
    return QDir(profilesRootPath()).filePath(profileId);
}

QString profileClientPath(const QString &profileId)
{
    return QDir(profileDirPath(profileId)).filePath(QStringLiteral("client.json"));
}

QString profileDialogsPath(const QString &profileId)
{
    return QDir(profileDirPath(profileId)).filePath(QStringLiteral("dialogs.json"));
}

QString profileDbPath(const QString &profileId)
{
    return QDir(profileDirPath(profileId)).filePath(QStringLiteral("paranoia.db"));
}

bool ensureProfileDir(const QString &profileId)
{
    QDir root;
    if (!root.exists(profilesRootPath()) && !root.mkpath(profilesRootPath()))
        return false;
    return root.mkpath(profileDirPath(profileId));
}

QJsonObject readJsonObjectFile(const QString &path)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) return {};
    const auto doc = QJsonDocument::fromJson(file.readAll());
    return doc.isObject() ? doc.object() : QJsonObject{};
}

QJsonArray readJsonArrayFile(const QString &path)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) return {};
    const auto doc = QJsonDocument::fromJson(file.readAll());
    return doc.isArray() ? doc.array() : QJsonArray{};
}

void writeJsonObjectFile(const QString &path, const QJsonObject &obj)
{
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)) return;
    file.write(QJsonDocument(obj).toJson());
    file.close();
    setOwnerOnlyPermissions(path);
}

QJsonObject loadProfilesManifest()
{
    QJsonObject manifest = readJsonObjectFile(profilesManifestPath());
    if (!manifest.value("profiles").isArray())
        manifest["profiles"] = QJsonArray{};
    return manifest;
}

void saveProfilesManifest(const QJsonObject &manifest)
{
    writeJsonObjectFile(profilesManifestPath(), manifest);
}

void upsertProfileManifest(const QString &profileId,
                           const QString &server,
                           const QString &username,
                           bool makeLast)
{
    QJsonObject manifest = loadProfilesManifest();
    QJsonArray profiles = manifest.value("profiles").toArray();
    bool found = false;
    for (int i = 0; i < profiles.size(); ++i) {
        QJsonObject obj = profiles.at(i).toObject();
        if (obj.value("id").toString() != profileId) continue;
        obj["server"] = normalizedServerUrl(server);
        obj["username"] = username;
        obj["updated_at"] = QDateTime::currentDateTimeUtc().toString(Qt::ISODate);
        profiles[i] = obj;
        found = true;
        break;
    }
    if (!found) {
        QJsonObject obj;
        obj["id"] = profileId;
        obj["server"] = normalizedServerUrl(server);
        obj["username"] = username;
        obj["updated_at"] = QDateTime::currentDateTimeUtc().toString(Qt::ISODate);
        profiles.append(obj);
    }
    manifest["profiles"] = profiles;
    if (makeLast)
        manifest["last_profile_id"] = profileId;
    saveProfilesManifest(manifest);
}

bool decodeFixedBase64(const QString &value, int expectedSize, QByteArray *out = nullptr)
{
    const QByteArray decoded = QByteArray::fromBase64(
        value.trimmed().toLatin1(),
        QByteArray::Base64Encoding | QByteArray::AbortOnBase64DecodingErrors
    );
    if (decoded.size() != expectedSize) return false;
    if (out) *out = decoded;
    return true;
}

quint64 readSeq(const QJsonValue &value, bool *ok)
{
    bool parsed = false;
    quint64 seq = 0;
    if (value.isString()) {
        seq = value.toString().toULongLong(&parsed);
    } else {
        seq = value.toVariant().toULongLong(&parsed);
    }
    if (ok) *ok = parsed && seq > 0;
    return seq;
}

void setOwnerOnlyPermissions(const QString &path)
{
    QFile::setPermissions(path, QFileDevice::ReadOwner | QFileDevice::WriteOwner);
}
}

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

bool ClientBackend::hasAdminAccess() const
{
    return !admin::Admin::admins.empty();
}

QString ClientBackend::activePeer() const { return m_activePeer; }

QString ClientBackend::devicePubkey() const
{
    if (m_devicePrivkey.isEmpty()) return QString();
    char *pub = paranoia_ecies_pubkey(m_devicePrivkey.toUtf8().constData());
    if (!pub) return QString();
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
        QMetaObject::invokeMethod(this, [this, pubkeyStr, secretStr]() {
            emit keyPairGenerated(pubkeyStr, secretStr);
        });
    });
}

QString ClientBackend::qrCodePngDataUrl(const QString &payload, int size) const
{
    const QByteArray data = payload.toUtf8();
    if (data.isEmpty()) return QString();

    const int requestedSize = std::clamp(size, 128, 2048);
    try {
        const std::vector<std::uint8_t> bytes(data.cbegin(), data.cend());
        const qrcodegen::QrCode qr = qrcodegen::QrCode::encodeBinary(
            bytes,
            qrcodegen::QrCode::Ecc::LOW
        );
        constexpr int border = 4;
        const int modules = qr.getSize() + border * 2;
        const int scale = std::max(1, requestedSize / modules);
        const int imageSize = modules * scale;

        QImage image(imageSize, imageSize, QImage::Format_RGB32);
        image.fill(Qt::white);

        QPainter painter(&image);
        painter.setPen(Qt::NoPen);
        painter.setBrush(Qt::black);
        for (int y = 0; y < qr.getSize(); ++y) {
            for (int x = 0; x < qr.getSize(); ++x) {
                if (qr.getModule(x, y)) {
                    painter.drawRect((x + border) * scale,
                                     (y + border) * scale,
                                     scale,
                                     scale);
                }
            }
        }
        painter.end();

        QByteArray png;
        QBuffer buffer(&png);
        buffer.open(QIODevice::WriteOnly);
        if (!image.save(&buffer, "PNG")) return QString();
        return QStringLiteral("data:image/png;base64,") + QString::fromLatin1(png.toBase64());
    } catch (const std::exception &e) {
        qWarning() << "QR generation failed:" << e.what();
        return QString();
    }
}

QVariantMap ClientBackend::decodeQrCodeFromImage(const QString &filePath) const
{
    QString path = filePath.trimmed();
    if (path.startsWith(QStringLiteral("file://")))
        path = QUrl(path).toLocalFile();
    if (path.isEmpty())
        return errorResult("Не указан файл изображения с QR-кодом.");

    QImage image(path);
    if (image.isNull())
        return errorResult("Не удалось открыть изображение с QR-кодом.");

    QImage gray = image.convertToFormat(QImage::Format_Grayscale8);
    try {
        ZXing::ImageView view(gray.constBits(),
                              gray.width(),
                              gray.height(),
                              ZXing::ImageFormat::Lum,
                              gray.bytesPerLine());
        ZXing::ReaderOptions options;
        options.setFormats(ZXing::BarcodeFormat::QRCode)
               .setTryHarder(true)
               .setTryRotate(true)
               .setTryInvert(true);
        const auto barcodes = ZXing::ReadBarcodes(view, options);
        for (const auto &barcode : barcodes) {
            if (barcode.isValid()) {
                return QVariantMap{{"ok", true}, {"text", QString::fromStdString(barcode.text())}};
            }
        }
        return errorResult("QR-код на изображении не найден.");
    } catch (const std::exception &e) {
        return errorResult(QStringLiteral("Ошибка чтения QR-кода: ") + QString::fromUtf8(e.what()));
    }
}

QVariantMap ClientBackend::registrationPublicKeyFromQr(const QString &payload) const
{
    QString text = payload.trimmed();
    if (text.isEmpty())
        return errorResult("QR-код не содержит данные регистрации.");

    QJsonParseError parseError;
    const QJsonDocument doc = QJsonDocument::fromJson(text.toUtf8(), &parseError);
    if (parseError.error == QJsonParseError::NoError && doc.isObject()) {
        const QJsonObject obj = doc.object();
        text = obj.value(QStringLiteral("pubkey")).toString().trimmed();
    }

    if (!decodeFixedBase64(text, 32))
        return errorResult("QR-код не содержит корректный публичный ключ base64.");
    return QVariantMap{{"ok", true}, {"pubkey", text}};
}

// ── Client Login ──────────────────────────────────────────────────────────────

void ClientBackend::loginClient(const QString &server, const QString &username, const QString &privkey)
{
    const QString url = normalizedServerUrl(server);
    const QString trimmedUsername = username.trimmed();
    const QString profileId = profileIdFor(url, trimmedUsername);
    if (!ensureProfileDir(profileId)) {
        emit loginError("Не удалось подготовить каталог профиля.");
        return;
    }
    const QString dbPath = profileDbPath(profileId);

    QPointer<ClientBackend> self(this);
    QThreadPool::globalInstance()->start([self, url, trimmedUsername, privkey, dbPath, profileId]() {
        auto *handle = paranoia_client_new(
            url.toUtf8().constData(),
            trimmedUsername.toUtf8().constData(),
            privkey.toUtf8().constData(),
            dbPath.toUtf8().constData()
        );
        QMetaObject::invokeMethod(self, [self, handle, url, trimmedUsername, privkey, profileId]() {
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
                self->m_username = trimmedUsername;
                self->m_privkey  = privkey;
                self->m_profileId = profileId;
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
    upsertDialogKeyringEntry(peer.trimmed(), deriveKey(sharedSecret), 1, true, false);
}

void ClientBackend::updateDialogKey(const QString &peer, const QString &newSharedSecret)
{
    const QString trimmedPeer = peer.trimmed();
    upsertDialogKeyringEntry(trimmedPeer, deriveKey(newSharedSecret), nextKeyStartSeq(trimmedPeer), false, false);
}

QVariantMap ClientBackend::createDialogKeyInvitation(const QString &peer)
{
    const QString trimmedPeer = peer.trimmed();
    if (m_username.isEmpty() || trimmedPeer.isEmpty()) {
        return errorResult("Не указан пользователь или собеседник.");
    }

    const QString bundleJson = takeRustString(paranoia_qr_create_invitation(
        m_username.toUtf8().constData(),
        trimmedPeer.toUtf8().constData()
    ));
    if (bundleJson.isEmpty()) {
        return errorResult(lastRustError());
    }

    const auto doc = QJsonDocument::fromJson(bundleJson.toUtf8());
    if (!doc.isObject()) {
        return errorResult("Некорректный JSON invitation.");
    }
    const auto obj = doc.object();
    const QString stateJson = compactJson(obj.value("state"));
    const QString payloadJson = compactJson(obj.value("payload"));
    if (stateJson.isEmpty() || payloadJson.isEmpty()) {
        return errorResult("Некорректный JSON invitation.");
    }

    return QVariantMap{
        {"ok", true},
        {"peer", trimmedPeer},
        {"stateJson", stateJson},
        {"payloadJson", payloadJson},
    };
}

QVariantMap ClientBackend::createDialogKeyResponse(const QString &invitationPayloadJson)
{
    if (m_username.isEmpty() || invitationPayloadJson.trimmed().isEmpty()) {
        return errorResult("Нет invitation payload или имени пользователя.");
    }

    const QString bundleJson = takeRustString(paranoia_qr_create_response(
        invitationPayloadJson.toUtf8().constData(),
        m_username.toUtf8().constData()
    ));
    if (bundleJson.isEmpty()) {
        return errorResult(lastRustError());
    }

    const auto doc = QJsonDocument::fromJson(bundleJson.toUtf8());
    if (!doc.isObject()) {
        return errorResult("Некорректный JSON response.");
    }
    const auto obj = doc.object();
    const QString stateJson = compactJson(obj.value("state"));
    const QString payloadJson = compactJson(obj.value("payload"));
    if (stateJson.isEmpty() || payloadJson.isEmpty()) {
        return errorResult("Некорректный JSON response.");
    }

    QVariantMap fingerprint = dialogKeyFingerprint(stateJson, invitationPayloadJson);
    if (!fingerprint.value("ok").toBool()) {
        return fingerprint;
    }

    return QVariantMap{
        {"ok", true},
        {"stateJson", stateJson},
        {"payloadJson", payloadJson},
        {"fingerprint", fingerprint.value("fingerprint").toString()},
    };
}

QVariantMap ClientBackend::dialogKeyFingerprint(const QString &localStateJson, const QString &peerPayloadJson)
{
    if (localStateJson.trimmed().isEmpty() || peerPayloadJson.trimmed().isEmpty()) {
        return errorResult("Нет state или payload для расчёта SAS.");
    }

    const QString fingerprint = takeRustString(paranoia_qr_fingerprint(
        localStateJson.toUtf8().constData(),
        peerPayloadJson.toUtf8().constData()
    ));
    if (fingerprint.isEmpty()) {
        return errorResult(lastRustError());
    }

    return QVariantMap{{"ok", true}, {"fingerprint", fingerprint}};
}

QVariantMap ClientBackend::confirmDialogKeyExchange(const QString &peer,
                                                    const QString &localStateJson,
                                                    const QString &peerPayloadJson,
                                                    const QString &fingerprint,
                                                    bool updateExisting)
{
    const QString trimmedPeer = peer.trimmed();
    if (trimmedPeer.isEmpty()) {
        return errorResult("Не указан собеседник.");
    }

    const QString completedJson = takeRustString(paranoia_qr_confirm_exchange(
        localStateJson.toUtf8().constData(),
        peerPayloadJson.toUtf8().constData(),
        fingerprint.toUtf8().constData()
    ));
    if (completedJson.isEmpty()) {
        return errorResult(lastRustError());
    }

    const auto doc = QJsonDocument::fromJson(completedJson.toUtf8());
    if (!doc.isObject()) {
        return errorResult("Некорректный JSON завершения обмена.");
    }
    const QByteArray sessionKey = QByteArray::fromBase64(
        doc.object().value("session_key_b64").toString().toLatin1()
    );
    if (sessionKey.size() != 32) {
        return errorResult("Некорректный ключ диалога.");
    }

    upsertDialogKeyringEntry(
        trimmedPeer,
        sessionKey,
        updateExisting ? nextKeyStartSeq(trimmedPeer) : 1,
        !updateExisting,
        false
    );
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

bool ClientBackend::hasDialogKey(const QString &peer) const
{
    const Dialog *dlg = findDialog(peer);
    return dlg != nullptr && !dlg->keyring.isEmpty();
}

QVariantList ClientBackend::getDialogs() const
{
    QVariantList result;
    for (const auto &d : m_dialogs) {
        QVariantMap m;
        m["peer"]    = d.peer;
        m["lastMsg"] = d.lastMsg;
        m["hasKey"]  = !d.keyring.isEmpty();
        result.append(m);
    }
    return result;
}

QVariantList ClientBackend::getClientProfiles() const
{
    QVariantList result;
    const QJsonArray profiles = loadProfilesManifest().value("profiles").toArray();
    for (const auto &value : profiles) {
        const QJsonObject obj = value.toObject();
        QVariantMap item;
        item["id"] = obj.value("id").toString();
        item["server"] = obj.value("server").toString();
        item["username"] = obj.value("username").toString();
        item["active"] = (item["id"].toString() == m_profileId);
        result.append(item);
    }
    return result;
}

void ClientBackend::switchClientProfile(const QString &profileId)
{
    const QJsonObject obj = readJsonObjectFile(profileClientPath(profileId.trimmed()));
    const QString server = obj.value("server").toString();
    const QString username = obj.value("username").toString();
    const QString privkey = obj.value("privkey").toString();
    if (server.isEmpty() || username.isEmpty() || privkey.isEmpty()) {
        emit loginError("Профиль клиента не найден или повреждён.");
        return;
    }
    loginClient(server, username, privkey);
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
    QString keyringJson = dialogKeyringJson(*dlg);

    QPointer<ClientBackend> self(this);
    QThreadPool::globalInstance()->start([self, peerCopy, username, keyringJson, cutSeq]() {
        if (!self) return;
        QMutexLocker locker(&self->m_handleMutex);
        if (!self->m_handle) return;
        int rc = paranoia_determinate_keyring(
            self->m_handle,
            username.toUtf8().constData(),
            peerCopy.toUtf8().constData(),
            keyringJson.toUtf8().constData(),
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
    QString keyringJson = dialogKeyringJson(*dlg);

    QPointer<ClientBackend> self(this);
    QThreadPool::globalInstance()->start([self, peer, username, text, keyringJson]() {
        if (!self) return;
        QMutexLocker locker(&self->m_handleMutex);
        if (!self->m_handle) return;
        char *json = paranoia_send_text_json_keyring(
            self->m_handle,
            username.toUtf8().constData(),
            peer.toUtf8().constData(),
            keyringJson.toUtf8().constData(),
            text.toUtf8().constData()
        );
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
    auto *dlg = findDialog(m_activePeer);
    if (!dlg) return;

    QString peer     = m_activePeer;
    QString username = m_username;
    QString keyringJson = dialogKeyringJson(*dlg);

    QPointer<ClientBackend> self(this);
    QThreadPool::globalInstance()->start([self, peer, username, keyringJson]() {
        if (!self) return;
        QMutexLocker locker(&self->m_handleMutex);
        if (!self->m_handle) return;
        char *json = paranoia_receive_keyring(
            self->m_handle,
            username.toUtf8().constData(),
            peer.toUtf8().constData(),
            keyringJson.toUtf8().constData()
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
    QString keyringJson = dialogKeyringJson(*dlg);
    QPointer<ClientBackend> self(this);
    QThreadPool::globalInstance()->start([self, peer, username, keyringJson]() {
        if (!self) return;
        QMutexLocker locker(&self->m_handleMutex);
        if (!self->m_handle) return;
        char *json = paranoia_history_keyring(
            self->m_handle,
            username.toUtf8().constData(),
            peer.toUtf8().constData(),
            keyringJson.toUtf8().constData(),
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

void ClientBackend::upsertDialogKeyringEntry(const QString &peer,
                                             const QByteArray &sessionKey,
                                             quint64 startSeq,
                                             bool resetKeyring,
                                             bool clearCache)
{
    if (peer.isEmpty() || sessionKey.size() != 32 || startSeq == 0) return;

    for (auto &d : m_dialogs) {
        if (d.peer == peer) {
            if (resetKeyring) {
                d.keyring.clear();
            }
            bool replaced = false;
            for (auto &entry : d.keyring) {
                if (entry.startSeq == startSeq) {
                    entry.key = sessionKey;
                    replaced = true;
                    break;
                }
            }
            if (!replaced) {
                d.keyring.append({startSeq, sessionKey});
            }
            std::sort(d.keyring.begin(), d.keyring.end(), [](const DialogKeyEntry &lhs, const DialogKeyEntry &rhs) {
                return lhs.startSeq < rhs.startSeq;
            });
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

void ClientBackend::onPollTimer()
{
    fetchMessages();
}

// ── Helpers ───────────────────────────────────────────────────────────────────

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
        obj["key"] = QString::fromLatin1(entry.key.toBase64());
        arr.append(obj);
    }
    return QString::fromUtf8(QJsonDocument(arr).toJson(QJsonDocument::Compact));
}

quint64 ClientBackend::nextKeyStartSeq(const QString &peer) const
{
    quint64 maxSeq = 0;
    for (const auto &msg : m_messageCache.value(peer)) {
        bool ok = false;
        quint64 seq = msg.toMap().value("seq").toULongLong(&ok);
        if (ok && seq > maxSeq) maxSeq = seq;
    }

    QMutexLocker locker(&m_handleMutex);
    if (m_handle) {
        uint64_t lastPulled = 0;
        int rc = paranoia_last_pulled_seq(
            m_handle,
            m_username.toUtf8().constData(),
            peer.toUtf8().constData(),
            &lastPulled
        );
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

// ── Export / Import ───────────────────────────────────────────────────────────

QVariantMap ClientBackend::exportProfile(const QString &profileType,
                                         const QStringList &peers,
                                         const QString &receiverPubkeyB64,
                                         const QString &filePath)
{
    const QString normalizedProfile = profileType.trimmed();
    if (!isSupportedExportProfile(normalizedProfile))
        return errorResult("Неподдерживаемый тип профиля экспорта.");
    if (receiverPubkeyB64.trimmed().isEmpty())
        return errorResult("Не указан публичный ключ принимающего устройства.");
    if (filePath.trimmed().isEmpty())
        return errorResult("Не указан путь к файлу.");

    // Собрать payload
    QJsonObject payload;
    payload["format_version"] = 1;
    payload["profile_type"] = normalizedProfile;

    const bool includeClient = (normalizedProfile == "client" || normalizedProfile == "full");
    const bool includeAdmin  = (normalizedProfile == "admin"  || normalizedProfile == "full");
    int exportedDialogues = 0;
    int exportedKeyEntries = 0;

    if (includeClient) {
        if (m_server.isEmpty() || m_username.isEmpty() || m_privkey.isEmpty())
            return errorResult("Нет активной клиентской сессии для экспорта.");

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
                keyObj["key"] = QString::fromLatin1(entry.key.toBase64());
                keyringArr.append(keyObj);
            }
            if (keyringArr.isEmpty()) continue;
            dlgObj["keyring"] = keyringArr;
            dialoguesArr.append(dlgObj);
            ++exportedDialogues;
            exportedKeyEntries += keyringArr.size();
        }

        if (!peers.isEmpty() && exportedDialogues == 0)
            return errorResult("Нет выбранных диалогов с keyring для экспорта.");

        QJsonObject serverObj;
        serverObj["url"] = m_server;
        serverObj["username"] = m_username;
        serverObj["signing_key_b64"] = m_privkey;
        serverObj["dialogues"] = dialoguesArr;

        payload["servers"] = QJsonArray{serverObj};
    }

    if (includeAdmin) {
        QJsonArray adminArr;
        for (const auto &a : admin::Admin::admins) {
            QJsonObject adminObj;
            adminObj["url"] = a.domain;
            adminObj["admin_privkey_b64"] = a.private_key;
            adminArr.append(adminObj);
        }
        payload["admin_servers"] = adminArr;
    }

    if (!includeClient) payload["servers"] = QJsonArray{};
    if (!includeAdmin)  payload["admin_servers"] = QJsonArray{};

    const QString payloadJson = QString::fromUtf8(
        QJsonDocument(payload).toJson(QJsonDocument::Compact));

    // Зашифровать
    char *envelopePtr = paranoia_ecies_encrypt(
        receiverPubkeyB64.trimmed().toUtf8().constData(),
        payloadJson.toUtf8().constData()
    );
    if (!envelopePtr) {
        const QString err = lastRustError();
        if (err == "invalid_device_key")
            return errorResult("Некорректный публичный ключ принимающего устройства.");
        return errorResult("Ошибка шифрования экспорта.");
    }
    const QString envelopeJson = takeRustString(envelopePtr);

    // Сохранить в файл
    QFile file(filePath);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate))
        return errorResult("Не удалось открыть файл для записи: " + filePath);
    const QByteArray envelopeBytes = envelopeJson.toUtf8();
    if (file.write(envelopeBytes) != envelopeBytes.size()) {
        file.close();
        return errorResult("Не удалось полностью записать файл экспорта.");
    }
    file.close();
    setOwnerOnlyPermissions(filePath);

    return QVariantMap{
        {"ok", true},
        {"path", filePath},
        {"dialogues", exportedDialogues},
        {"keyEntries", exportedKeyEntries},
    };
}

QVariantMap ClientBackend::importProfile(const QString &filePath)
{
    if (m_devicePrivkey.isEmpty())
        return errorResult("Device keypair не инициализирован.");
    if (filePath.trimmed().isEmpty())
        return errorResult("Не указан путь к файлу.");

    QFile file(filePath);
    if (!file.open(QIODevice::ReadOnly))
        return errorResult("Не удалось открыть файл: " + filePath);
    if (file.size() > MaxExportFileBytes) {
        file.close();
        return errorResult("Файл экспорта слишком большой.");
    }
    const QString envelopeJson = QString::fromUtf8(file.readAll());
    file.close();

    if (envelopeJson.trimmed().isEmpty())
        return errorResult("Файл пуст.");

    // Расшифровать
    char *plaintextPtr = paranoia_ecies_decrypt(
        m_devicePrivkey.toUtf8().constData(),
        envelopeJson.toUtf8().constData()
    );
    if (!plaintextPtr) {
        const QString err = lastRustError();
        if (err == "ecies_decrypt_error")
            return errorResult("Не удалось расшифровать файл. Файл зашифрован на другой ключ или повреждён.");
        if (err == "ecies_unsupported_version")
            return errorResult("Неподдерживаемая версия формата экспорта.");
        return errorResult("Ошибка расшифровки.");
    }
    const QString payloadJson = takeRustString(plaintextPtr);

    QJsonParseError parseError;
    const auto doc = QJsonDocument::fromJson(payloadJson.toUtf8(), &parseError);
    if (parseError.error != QJsonParseError::NoError || !doc.isObject())
        return errorResult("Некорректный формат payload после расшифровки.");

    const auto payload = doc.object();
    if (payload["format_version"].toInt() != 1)
        return errorResult("Неподдерживаемая версия формата payload.");
    const QString profileType = payload["profile_type"].toString();
    if (!isSupportedExportProfile(profileType))
        return errorResult("Неподдерживаемый тип профиля в payload.");
    const bool allowClientImport = (profileType == "client" || profileType == "full");
    const bool allowAdminImport = (profileType == "admin" || profileType == "full");

    int importedDialogues = 0;
    int importedKeyEntries = 0;
    int importedAdminServers = 0;
    int skippedEntries = 0;
    int conflicts = 0;
    int importedProfiles = 0;
    QString activateServer;
    QString activateUsername;
    QString activatePrivkey;

    const auto mergeKeyringEntry = [](QList<Dialog> &dialogs,
                                      const QString &peer,
                                      const QByteArray &key,
                                      quint64 startSeq) -> int {
        for (auto &dlg : dialogs) {
            if (dlg.peer != peer) continue;
            for (const auto &entry : dlg.keyring) {
                if (entry.startSeq != startSeq) continue;
                return entry.key == key ? 0 : -1;
            }
            dlg.keyring.append({startSeq, key});
            std::sort(dlg.keyring.begin(), dlg.keyring.end(), [](const DialogKeyEntry &lhs, const DialogKeyEntry &rhs) {
                return lhs.startSeq < rhs.startSeq;
            });
            return 1;
        }
        dialogs.append({peer, QList<DialogKeyEntry>{{startSeq, key}}, QString()});
        return 1;
    };

    // Импорт client-данных: merge по server+username+peer+start_seq (Z2a)
    if (allowClientImport) {
        const QJsonArray servers = payload["servers"].toArray();
        if (servers.size() > MaxImportServers)
            return errorResult("Слишком много client-профилей в export payload.");
        int totalDialogues = 0;
        int totalKeyEntries = 0;
        for (const auto &serverVal : servers) {
            const auto serverObj = serverVal.toObject();
            const QString url = normalizedServerUrl(serverObj["url"].toString());
            const QString username = serverObj["username"].toString().trimmed();
            const QString signingKey = serverObj["signing_key_b64"].toString().trimmed();
            if (url.isEmpty() || username.isEmpty()) continue;
            if (!decodeFixedBase64(signingKey, 32))
                return errorResult("Некорректный private signing key в client-профиле export payload.");

            const QString profileId = profileIdFor(url, username);
            const bool isCurrentClient = (profileId == m_profileId);
            const bool profileExists = QFile::exists(profileClientPath(profileId));
            if (profileExists) {
                const QJsonObject existing = readJsonObjectFile(profileClientPath(profileId));
                const QString existingKey = existing.value("privkey").toString().trimmed();
                if (!existingKey.isEmpty() && existingKey != signingKey) {
                    ++conflicts;
                    continue;
                }
            }

            QList<Dialog> targetDialogs = isCurrentClient ? m_dialogs : loadDialogsFromPath(profileDialogsPath(profileId));
            QSet<QString> touchedDialogues;

            const QJsonArray dialogues = serverObj["dialogues"].toArray();
            if (totalDialogues + dialogues.size() > MaxImportDialogues)
                return errorResult("Слишком много диалогов в export payload.");
            totalDialogues += dialogues.size();

            for (const auto &dlgVal : dialogues) {
                const auto dlgObj = dlgVal.toObject();
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
                if (totalKeyEntries + keyringArr.size() > MaxImportKeyEntries)
                    return errorResult("Слишком много keyring entries в export payload.");
                totalKeyEntries += keyringArr.size();

                for (const auto &keyVal : keyringArr) {
                    const auto keyObj = keyVal.toObject();
                    bool seqOk = false;
                    const quint64 startSeq = readSeq(keyObj["start_seq"], &seqOk);
                    QByteArray key;
                    if (!seqOk || !decodeFixedBase64(keyObj["key"].toString(), 32, &key)) {
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
            saveDialogsToPath(profileDialogsPath(profileId), targetDialogs);
            upsertProfileManifest(profileId, url, username, isCurrentClient || m_profileId.isEmpty());
            if (!profileExists)
                ++importedProfiles;
            if (m_profileId.isEmpty() && activatePrivkey.isEmpty()) {
                activateServer = url;
                activateUsername = username;
                activatePrivkey = signingKey;
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
        if (adminServers.size() > MaxImportAdminServers)
            return errorResult("Слишком много admin-профилей в export payload.");
        for (const auto &adminVal : adminServers) {
            const auto adminObj = adminVal.toObject();
            const QString url     = normalizedServerUrl(adminObj["url"].toString());
            const QString privkey = adminObj["admin_privkey_b64"].toString().trimmed();
            if (url.isEmpty() || privkey.isEmpty()) continue;
            if (!decodeFixedBase64(privkey, 32))
                return errorResult("Некорректный private admin key в export payload.");

            bool found = false;
            for (auto &a : admin::Admin::admins) {
                if (a.domain == url) { found = true; break; }
            }
            if (!found) {
                admin::Admin::admins.push_back({url, privkey});
                ++importedAdminServers;
            }
        }
    }

    if (importedAdminServers > 0) {
        admin::Admin::saveAdmins();
        emit adminStateChanged();
    }

    if (!activatePrivkey.isEmpty())
        loginClient(activateServer, activateUsername, activatePrivkey);

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
    if (trimmedPath.isEmpty())
        return errorResult("Не указан путь к файлу.");
    if (!QFile::exists(trimmedPath))
        return QVariantMap{{"ok", true}, {"deleted", false}, {"message", "Файл уже удалён."}};
    if (!QFile::remove(trimmedPath))
        return errorResult("Не удалось удалить файл экспорта: " + trimmedPath);
    return QVariantMap{{"ok", true}, {"deleted", true}};
}

// ── Persistence ───────────────────────────────────────────────────────────────

void ClientBackend::saveClientConfig() const
{
    if (m_server.isEmpty() || m_username.isEmpty() || m_privkey.isEmpty()) return;
    const QString profileId = m_profileId.isEmpty() ? profileIdFor(m_server, m_username) : m_profileId;
    saveClientConfigForProfile(profileId, m_server, m_username, m_privkey);
    upsertProfileManifest(profileId, m_server, m_username, true);
}

void ClientBackend::saveClientConfigForProfile(const QString &profileId,
                                               const QString &server,
                                               const QString &username,
                                               const QString &privkey) const
{
    if (profileId.isEmpty() || server.isEmpty() || username.isEmpty() || privkey.isEmpty()) return;
    if (!ensureProfileDir(profileId)) return;
    QJsonObject obj;
    obj["server"] = normalizedServerUrl(server);
    obj["username"] = username;
    obj["privkey"] = privkey;
    writeJsonObjectFile(profileClientPath(profileId), obj);
}

void ClientBackend::loadClientConfig()
{
    const QJsonObject manifest = loadProfilesManifest();
    QString profileId = manifest.value("last_profile_id").toString();
    QJsonObject obj;
    if (!profileId.isEmpty())
        obj = readJsonObjectFile(profileClientPath(profileId));
    if (obj.isEmpty()) {
        const QJsonArray profiles = manifest.value("profiles").toArray();
        for (const auto &value : profiles) {
            const QString candidate = value.toObject().value("id").toString();
            obj = readJsonObjectFile(profileClientPath(candidate));
            if (!obj.isEmpty()) {
                profileId = candidate;
                break;
            }
        }
    }
    if (obj.isEmpty()) {
        QFile legacy("client.json");
        if (!legacy.open(QIODevice::ReadOnly)) return;
        const auto doc = QJsonDocument::fromJson(legacy.readAll());
        if (!doc.isObject()) return;
        obj = doc.object();
        profileId = profileIdFor(obj.value("server").toString(), obj.value("username").toString());
    }

    QString server   = obj.value("server").toString();
    QString username = obj.value("username").toString();
    QString privkey  = obj.value("privkey").toString();
    if (server.isEmpty() || username.isEmpty() || privkey.isEmpty()) return;
    loginClient(server, username, privkey);
}

void ClientBackend::saveDialogs() const
{
    if (m_profileId.isEmpty()) return;
    saveDialogsToPath(profileDialogsPath(m_profileId), m_dialogs);
}

void ClientBackend::saveDialogsToPath(const QString &path, const QList<Dialog> &dialogs) const
{
    const QString profileId = QDir(profilesRootPath()).relativeFilePath(QFileInfo(path).dir().path());
    if (!profileId.isEmpty() && !profileId.startsWith(".."))
        ensureProfileDir(profileId);

    QJsonArray arr;
    for (const auto &d : dialogs) {
        QJsonObject o;
        o["peer"] = d.peer;
        QJsonArray keyring;
        for (const auto &entry : d.keyring) {
            if (entry.key.size() != 32 || entry.startSeq == 0) continue;
            QJsonObject keyObj;
            keyObj["start_seq"] = static_cast<double>(entry.startSeq);
            keyObj["key"] = QString::fromLatin1(entry.key.toBase64());
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
    setOwnerOnlyPermissions(path);
}

void ClientBackend::loadDialogs()
{
    m_dialogs.clear();
    if (m_profileId.isEmpty()) return;
    const QString path = profileDialogsPath(m_profileId);
    if (QFile::exists(path)) {
        m_dialogs = loadDialogsFromPath(path);
        return;
    }
    if (QFile::exists("dialogs.json")) {
        m_dialogs = loadDialogsFromPath("dialogs.json");
        saveDialogs();
    }
}

QList<ClientBackend::Dialog> ClientBackend::loadDialogsFromPath(const QString &path) const
{
    QList<Dialog> dialogs;
    const QJsonArray jsonArr = readJsonArrayFile(path);
    for (const auto &val : jsonArr) {
        auto obj = val.toObject();
        QString peer   = obj["peer"].toString();
        QString lastMsg = obj["lastMsg"].toString();
        QList<DialogKeyEntry> keyring;

        const QJsonArray keyringJson = obj["keyring"].toArray();
        for (const auto &keyVal : keyringJson) {
            const auto keyObj = keyVal.toObject();
            bool ok = false;
            const quint64 startSeq = readSeq(keyObj["start_seq"], &ok);
            const QByteArray key = QByteArray::fromBase64(keyObj["key"].toString().toLatin1());
            if (ok && key.size() == 32) {
                keyring.append({startSeq, key});
            }
        }

        if (keyring.isEmpty()) {
            const QByteArray legacyKey = QByteArray::fromBase64(obj["key"].toString().toLatin1());
            if (legacyKey.size() == 32) {
                keyring.append({1, legacyKey});
            }
        }

        std::sort(keyring.begin(), keyring.end(), [](const DialogKeyEntry &lhs, const DialogKeyEntry &rhs) {
            return lhs.startSeq < rhs.startSeq;
        });
        if (!peer.isEmpty() && !keyring.isEmpty())
            dialogs.append({peer, keyring, lastMsg});
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
    obj["privkey_b64"] = m_devicePrivkey;
    f.write(QJsonDocument(obj).toJson());
    f.close();
    setOwnerOnlyPermissions("device_key.json");
}

void ClientBackend::loadDeviceKey()
{
    QFile f("device_key.json");
    if (f.open(QIODevice::ReadOnly)) {
        auto doc = QJsonDocument::fromJson(f.readAll());
        if (doc.isObject()) {
            const QString priv = doc.object()["privkey_b64"].toString();
            if (!priv.isEmpty() && QByteArray::fromBase64(priv.toLatin1()).size() == 32) {
                m_devicePrivkey = priv;
                return;
            }
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
