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

    QDir profileDir(const QString &profileId) { return QDir(profilesRoot().filePath(profileId)); }
    QString profileClient(const QString &profileId) { return profileDir(profileId).filePath(client); }
    QString profileDialogs(const QString &profileId) { return profileDir(profileId).filePath(dialogs); }
    QString profileDb(const QString &profileId) { return profileDir(profileId).filePath(db); }
    bool ensureProfileDir(const QString &profileId) { return profileDir(profileId).mkpath("./"); }
}
