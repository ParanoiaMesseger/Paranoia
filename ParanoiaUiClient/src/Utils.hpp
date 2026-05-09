#pragma once
#include <QJsonObject>
#include <QString>

namespace Utils
{
    constexpr qint64 MaxExportFileBytes = 16 * 1024 * 1024;
    constexpr int MaxImportServers      = 16;
    constexpr int MaxImportAdminServers = 16;
    constexpr int MaxImportDialogues    = 1024;
    constexpr int MaxImportKeyEntries   = 8192;

    bool writeFile(const QString &path, const QByteArray &data);

    QByteArray readAll(const QString &path);

    QString compactJson(const QJsonValue &value);

    bool isSupportedExportProfile(const QString &profileType);

    QString normalizedServerUrl(const QString &server);

    QString profileIdFor(const QString &server, const QString &username);

    QString profilesRootPath();

    QString profilesManifestPath();

    QString profileDirPath(const QString &profileId);

    QString profileClientPath(const QString &profileId);

    QString profileDialogsPath(const QString &profileId);

    QString profileDbPath(const QString &profileId);

    bool ensureProfileDir(const QString &profileId);

    QJsonObject readJsonObjectFile(const QString &path);

    QJsonArray readJsonArrayFile(const QString &path);

    void writeJsonObjectFile(const QString &path, const QJsonObject &obj);

    QJsonObject loadProfilesManifest();

    void upsertProfileManifest(const QString &profileId, const QString &server, const QString &username,
                               const bool makeLast);

    bool decodeFixedBase64(const QString &value, int expectedSize, QByteArray *out = nullptr);

    quint64 readSeq(const QJsonValue &value, bool *ok);

    void setOwnerOnlyPermissions(const QString &path);
}
