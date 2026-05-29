#include "Utils.hpp"

#include "Paths.hpp"

#include <QCryptographicHash>
#include <QJsonArray>
#include <QJsonDocument>
#include <QMutex>
#include <QUrl>

#include <ParanoiaFFI>

#if defined(Q_OS_ANDROID)
#include <QJniEnvironment>
#include <QJniObject>
#include <QCoreApplication>
#include <QStandardPaths>
#include <QDir>
#include <QDateTime>
#endif

namespace Utils
{
    namespace {
        QMutex g_vaultIoMutex;
        bool g_vaultIoFailed = false;
        QString g_vaultIoReason;

        void markVaultIoFailure(const QString &reason)
        {
            QMutexLocker lock(&g_vaultIoMutex);
            if (!g_vaultIoFailed) {
                g_vaultIoFailed = true;
                g_vaultIoReason = reason;
                qCritical().noquote()
                    << "vault IO failure detected — entering read-only mode for"
                       " vault-protected paths until restart:"
                    << reason;
            }
        }
    }

    bool vaultIoFailureDetected()
    {
        QMutexLocker lock(&g_vaultIoMutex);
        return g_vaultIoFailed;
    }

    QString vaultIoFailureReason()
    {
        QMutexLocker lock(&g_vaultIoMutex);
        return g_vaultIoReason;
    }

    void resetVaultIoFailure()
    {
        QMutexLocker lock(&g_vaultIoMutex);
        g_vaultIoFailed = false;
        g_vaultIoReason.clear();
    }

    void setOwnerOnlyPermissions(const QString &path)
    { QFile::setPermissions(path, QFileDevice::ReadOwner | QFileDevice::WriteOwner); }

    QString compactJson(const QJsonValue &value)
    {
        if (value.isObject()) return QString::fromUtf8(QJsonDocument(value.toObject()).toJson(QJsonDocument::Compact));
        if (value.isArray()) return QString::fromUtf8(QJsonDocument(value.toArray()).toJson(QJsonDocument::Compact));
        return {};
    }

    bool isSupportedExportProfile(const QString &profileType)
    { return profileType == "client" || profileType == "admin" || profileType == "full"; }

    QString normalizedServerUrl(const QString &server)
    {
        QString url = server.trimmed();
        if (url.isEmpty()) return {};
        if (!url.startsWith("http://") && !url.startsWith("https://")) url = "https://" + url;
        while (url.endsWith('/') && !url.endsWith("://")) url.chop(1);
        return url;
    }

    QStringList normalizedServerUrls(const QStringList &servers, const QString &primaryServer)
    {
        const QString primary = normalizedServerUrl(primaryServer);
        QStringList result;
        for (const auto &server : servers) {
            const QString url = normalizedServerUrl(server);
            if (url.isEmpty() || url == primary || result.contains(url)) continue;
            result.append(url);
        }
        return result;
    }

    QJsonArray stringListToJsonArray(const QStringList &values)
    {
        QJsonArray arr;
        for (const auto &value : values)
            if (!value.isEmpty()) arr.append(value);
        return arr;
    }

    QStringList stringListFromJsonArray(const QJsonArray &values)
    {
        QStringList result;
        for (const auto &value : values) {
            const QString text = value.toString().trimmed();
            if (!text.isEmpty()) result.append(text);
        }
        return result;
    }

    QString reserveServerUrlsJson(const QStringList &reserveServerUrls)
    {
        return QString::fromUtf8(
            QJsonDocument(stringListToJsonArray(reserveServerUrls)).toJson(QJsonDocument::Compact));
    }

    QString profileIdFor(const QString &server, const QString &username)
    {
        const QByteArray input = normalizedServerUrl(server).toUtf8() + "\n" + username.trimmed().toUtf8();
        return QString::fromLatin1(QCryptographicHash::hash(input, QCryptographicHash::Sha256).toHex());
    }

    QJsonObject readJsonObjectFile(const QString &path)
    {
        const auto doc = QJsonDocument::fromJson(readAll(path));
        return doc.isObject() ? doc.object() : QJsonObject{};
    }

    QJsonArray readJsonArrayFile(const QString &path)
    {
        const auto doc = QJsonDocument::fromJson(readAll(path));
        return doc.isArray() ? doc.array() : QJsonArray{};
    }

    void writeJsonObjectFile(const QString &path, const QJsonObject &obj)
    {
        writeFile(path, QJsonDocument(obj).toJson());
        setOwnerOnlyPermissions(path);
    }

    QJsonObject loadProfilesManifest()
    {
        auto manifest = readJsonObjectFile(Paths::profilesManifest());
        if (!manifest.value("profiles").isArray()) manifest["profiles"] = QJsonArray{};
        return manifest;
    }

    void upsertProfileManifest(const QString &profileId, const QString &server, const QString &username,
                               const bool makeLast)
    {
        QJsonObject manifest = loadProfilesManifest(), obj;
        QJsonArray profiles  = manifest.value("profiles").toArray();
        auto it              = std::ranges::find_if(
            profiles, [&](const QJsonValue &v) { return v.toObject().value("id").toString() == profileId; });
        if (it != profiles.end()) obj = it->toObject();
        obj["id"]         = profileId;
        obj["server"]     = normalizedServerUrl(server);
        obj["username"]   = username;
        obj["updated_at"] = QDateTime::currentDateTimeUtc().toString(Qt::ISODate);
        if (it != profiles.end())
            *it = obj;
        else
            profiles.append(obj);
        manifest["profiles"] = profiles;
        if (makeLast) manifest["last_profile_id"] = profileId;
        writeJsonObjectFile(Paths::profilesManifest(), manifest);
    }

    bool decodeFixedBase64(const QString &value, int expectedSize, QByteArray *out)
    {
        const auto decoded = QByteArray::fromBase64(
            value.trimmed().toLatin1(), QByteArray::Base64Encoding | QByteArray::AbortOnBase64DecodingErrors);
        if (decoded.size() != expectedSize) return false;
        if (out) *out = decoded;
        return true;
    }

    quint64 readSeq(const QJsonValue &value, bool *ok)
    {
        bool parsed       = false;
        const quint64 seq = value.toVariant().toULongLong(&parsed);
        if (ok) *ok = parsed && seq > 0;
        return seq;
    }

    bool writeFile(const QString &path, const QByteArray &data)
    {
        if (Paths::isVaultProtected(path)) {
            // Read-only mode после детекции corruption: писать в защищённые
            // пути нельзя — иначе перезапишем недешифруемые данные новыми
            // зашифрованными байтами и навсегда потеряем содержимое.
            if (vaultIoFailureDetected()) {
                qCritical().noquote()
                    << "writeFile refused (vault read-only mode):" << path
                    << "reason:" << vaultIoFailureReason();
                return false;
            }
            return ParanoiaFFI::vault_encrypt_json(path, data) == 0;
        }
        QFile file(path);
        if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)) return false;
        return file.write(data) == data.size();
    }

    QByteArray readAll(const QString &path)
    {
        if (Paths::isVaultProtected(path)) {
            if (!QFile::exists(path)) return {};
            QByteArray decrypted = ParanoiaFFI::vault_decrypt_json(path);
            if (decrypted.isEmpty()) {
                const QString err = ParanoiaFFI::last_error();
                // "vault_locked" — нормальный случай до ввода PIN'а. Это не
                // corruption: тот же файл успешно прочитается после unlock'а.
                // Не помечаем как failure, чтобы не блокировать запись потом.
                if (!err.contains(QStringLiteral("vault_locked"))) {
                    markVaultIoFailure(
                        QStringLiteral("decrypt failed for %1: %2").arg(path, err));
                }
            }
            return decrypted;
        }
        QFile file(path);
        if (!file.open(QIODevice::ReadOnly)) return {};
        return file.readAll();
    }

    QString normalizeLocalFilePath(const QString &raw)
    {
        const QString trimmed = raw.trimmed();
        if (trimmed.startsWith(QStringLiteral("file:"))) {
            const QString local = QUrl(trimmed).toLocalFile();
            if (!local.isEmpty()) return local;
        }
        return trimmed;
    }

    QString resolveImportPath(const QString &urlOrUri)
    {
        const QString trimmed = urlOrUri.trimmed();
        if (trimmed.isEmpty()) return {};

        // content:// — Android Storage Access Framework. QFile его не откроет
        // напрямую; копируем в CacheLocation через ContentResolver (Java helper
        // ParanoiaAndroidUtils.copyUriToCache, тот же что использует ChatBackend
        // для sendFile). Полученный путь — обычный локальный файл, который
        // caller обязан удалить после чтения.
        if (trimmed.startsWith(QStringLiteral("content://"), Qt::CaseInsensitive)) {
#if defined(Q_OS_ANDROID)
            QJniObject context = QNativeInterface::QAndroidApplication::context();
            if (!context.isValid()) return {};
            const QJniObject javaUri = QJniObject::fromString(trimmed);
            const QJniObject result  = QJniObject::callStaticObjectMethod(
                "app/paranoia/client/ParanoiaAndroidUtils", "copyUriToCache",
                "(Landroid/content/Context;Ljava/lang/String;)Ljava/lang/String;",
                context.object<jobject>(), javaUri.object<jstring>());
            QJniEnvironment env;
            if (env->ExceptionCheck()) {
                env->ExceptionDescribe();
                env->ExceptionClear();
            }
            return result.isValid() ? result.toString() : QString();
#else
            return {};
#endif
        }

        return normalizeLocalFilePath(trimmed);
    }

    bool writeBytesToTarget(const QString &target, const QByteArray &data)
    {
        const QString trimmed = target.trimmed();
        if (trimmed.isEmpty()) return false;

        // content:// — Android SAF. QFile его не откроет на запись напрямую:
        // пишем во временный файл в CacheLocation и копируем в URI через
        // ContentResolver (тот же Java-хелпер, что и ChatBackend::saveAttachment).
        if (trimmed.startsWith(QStringLiteral("content://"), Qt::CaseInsensitive)) {
#if defined(Q_OS_ANDROID)
            const QString cacheDir = QStandardPaths::writableLocation(QStandardPaths::CacheLocation);
            if (cacheDir.isEmpty() || !QDir().mkpath(cacheDir)) return false;
            const QString tmpPath =
                cacheDir + QStringLiteral("/export-")
                + QString::number(QDateTime::currentMSecsSinceEpoch()) + QStringLiteral(".tmp");
            {
                QFile tmp(tmpPath);
                if (!tmp.open(QIODevice::WriteOnly | QIODevice::Truncate)) return false;
                if (tmp.write(data) != data.size()) {
                    tmp.close();
                    QFile::remove(tmpPath);
                    return false;
                }
            }
            QJniObject context = QNativeInterface::QAndroidApplication::context();
            bool ok = false;
            if (context.isValid()) {
                const QJniObject javaPath = QJniObject::fromString(tmpPath);
                const QJniObject javaUri  = QJniObject::fromString(trimmed);
                ok = QJniObject::callStaticMethod<jboolean>(
                    "app/paranoia/client/ParanoiaAndroidUtils", "copyFileToUri",
                    "(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)Z",
                    context.object<jobject>(), javaPath.object<jstring>(), javaUri.object<jstring>());
                QJniEnvironment env;
                if (env->ExceptionCheck()) {
                    env->ExceptionDescribe();
                    env->ExceptionClear();
                    ok = false;
                }
            }
            QFile::remove(tmpPath);
            return ok;
#else
            return false;
#endif
        }

        const QString local = normalizeLocalFilePath(trimmed);
        if (local.isEmpty()) return false;
        QFile file(local);
        if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)) return false;
        if (file.write(data) != data.size()) {
            file.close();
            return false;
        }
        file.close();
        setOwnerOnlyPermissions(local);
        return true;
    }

}
