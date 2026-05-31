#include "Paths.hpp"
#include <QDir>
#include <QStandardPaths>
namespace Paths
{
    QDir appDataRoot()
    {
        QString root = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
        if (root.isEmpty()) root = QDir::currentPath();
        QDir dir(root);
        dir.mkpath(QStringLiteral("."));
        return dir;
    }

    QDir profilesRoot()
    {
        QDir root = appDataRoot();
        root.mkpath(QStringLiteral("profiles"));
        return QDir(root.filePath(QStringLiteral("profiles")));
    }

    QString profilesManifest() { return appDataRoot().filePath(QStringLiteral("profiles.json")); }
    QString deviceKey() { return appDataRoot().filePath(QStringLiteral("device_key.json")); }
    QString pendingRegistrationKey() { return appDataRoot().filePath(QStringLiteral("pending_registration_key.json")); }
    QString admins() { return appDataRoot().filePath(QStringLiteral("admins.crypt")); }
    QString vaultState() { return appDataRoot().filePath(QStringLiteral("vault.json")); }

    bool isVaultProtected(const QString &path)
    {
        const QString canonical = QDir::cleanPath(path);
        if (canonical == QDir::cleanPath(vaultState())) return false; // сам vault.json — plaintext
        if (canonical == QDir::cleanPath(profilesManifest())) return true;
        if (canonical == QDir::cleanPath(deviceKey())) return true;
        if (canonical == QDir::cleanPath(pendingRegistrationKey())) return true;
        if (canonical == QDir::cleanPath(admins())) return true;
        const QString profilesRootPath = QDir::cleanPath(profilesRoot().path());
        if (canonical.startsWith(profilesRootPath + QLatin1Char('/'))) return true;
        return false;
    }

    QDir profileDir(const QString &profileId) { return QDir(profilesRoot().filePath(profileId)); }
    QString profileClient(const QString &profileId) { return profileDir(profileId).filePath(client); }
    QString profileCorp(const QString &profileId) { return profileDir(profileId).filePath(QStringLiteral("corp.json")); }
    QString profileMaskingState(const QString &profileId) { return profileDir(profileId).filePath(QStringLiteral("masking_state.json")); }
    QString profileDialogs(const QString &profileId) { return profileDir(profileId).filePath(dialogs); }
    QString profileDb(const QString &profileId) { return profileDir(profileId).filePath(db); }
    bool ensureProfileDir(const QString &profileId) { return profileDir(profileId).mkpath("./"); }
}
