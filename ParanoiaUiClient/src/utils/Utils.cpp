#include "Utils.hpp"

#include "Paths.hpp"

#include <QCryptographicHash>
#include <QJsonArray>
#include <QJsonDocument>

namespace Utils
{
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
        return QString::fromUtf8(QJsonDocument(stringListToJsonArray(reserveServerUrls)).toJson(QJsonDocument::Compact));
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
        auto manifest = readJsonObjectFile(Paths::profilesManifest);
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
        writeJsonObjectFile(Paths::profilesManifest, manifest);
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
        bool parsed       = {};
        const quint64 seq = (value.isString() ? value.toString() : value.toVariant()).toULongLong(&parsed);
        if (ok) *ok = parsed && seq > 0;
        return seq;
    }

    bool writeFile(const QString &path, const QByteArray &data)
    {
        QFile file(path);
        if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)) return false;
        return file.write(data) == data.size();
    }

    QByteArray readAll(const QString &path)
    {
        QFile file(path);
        if (!file.open(QIODevice::ReadOnly)) return {};
        return file.readAll();
    }

}
