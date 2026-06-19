#pragma once
#include <QJsonArray>
#include <QJsonObject>
#include <QString>
#include <QStringList>

namespace Utils
{
    constexpr qint64 MaxExportFileBytes = 16 * 1024 * 1024;
    constexpr int MaxImportServers      = 16;
    constexpr int MaxImportAdminServers = 16;
    constexpr int MaxImportDialogues    = 1024;
    constexpr int MaxImportKeyEntries   = 8192;

    bool writeFile(const QString &path, const QByteArray &data);

    QByteArray readAll(const QString &path);

    /// Если декрипт vault-protected файла когда-либо упал, выставляется
    /// read-only флаг на всю сессию: writeFile в защищённые пути откажет.
    /// Это предотвращает «silent overwrite» повреждённого файла свежей
    /// зашифрованной пустотой. Сбрасывается только перезапуском процесса
    /// или вручную через resetVaultIoFailure().
    bool vaultIoFailureDetected();
    QString vaultIoFailureReason();
    void resetVaultIoFailure();

    QString compactJson(const QJsonValue &value);

    bool isSupportedExportProfile(const QString &profileType);

    QString normalizedServerUrl(const QString &server);

    QStringList normalizedServerUrls(const QStringList &servers, const QString &primaryServer = {});

    QJsonArray stringListToJsonArray(const QStringList &values);

    QStringList stringListFromJsonArray(const QJsonArray &values);

    QString reserveServerUrlsJson(const QStringList &reserveServerUrls);

    QString profileIdFor(const QString &server, const QString &username);

    QJsonObject readJsonObjectFile(const QString &path);

    QJsonArray readJsonArrayFile(const QString &path);

    void writeJsonObjectFile(const QString &path, const QJsonObject &obj);

    QJsonObject loadProfilesManifest();

    void upsertProfileManifest(const QString &profileId, const QString &server, const QString &username,
                               const bool makeLast);

    // Запись профиля из манифеста (или пустой объект, если профиля нет).
    QJsonObject profileManifestEntry(const QString &profileId);

    // Слить произвольные поля (например localName / avatar) в запись профиля
    // манифеста. Не создаёт запись, если профиля нет (возвращает false).
    bool updateProfileManifestEntry(const QString &profileId, const QJsonObject &fields);

    bool decodeFixedBase64(const QString &value, int expectedSize, QByteArray *out = nullptr);

    quint64 readSeq(const QJsonValue &value, bool *ok);

    void setOwnerOnlyPermissions(const QString &path);

    /// Если raw — это file://-URL (как FileDialog.selectedFile в QML), вернёт
    /// нормальный путь файловой системы через QUrl::toLocalFile(). На Windows
    /// "file:///C:/x" → "C:/x", на POSIX "file:///x" → "/x". Уже-локальный
    /// путь возвращается как есть (trimmed). Использовать на C++-границах,
    /// принимающих путь от QML, чтобы не зависеть от того, нормализован ли
    /// он на стороне QML.
    QString normalizeLocalFilePath(const QString &raw);

    /// То же, что normalizeLocalFilePath, плюс на Android поддерживает SAF
    /// `content://` URI: копирует контент во временный файл в CacheLocation
    /// и возвращает локальный путь. На non-Android платформах для content://
    /// вернёт пустую строку — caller должен показать понятную ошибку.
    /// Использовать там, где входной путь приходит из QML FileDialog
    /// (QtQuick.Dialogs возвращает content:// на Android Q+).
    QString resolveImportPath(const QString &urlOrUri);

    /// Записывает данные в локальный файл ИЛИ в Android content:// URI (SAF).
    /// Для content:// пишет во временный файл и копирует его через
    /// ContentResolver (ParanoiaAndroidUtils.copyFileToUri). Симметрично
    /// resolveImportPath на стороне импорта. Возвращает true при успехе.
    bool writeBytesToTarget(const QString &target, const QByteArray &data);
}
