#include "Paths.hpp"
#include <QDir>
#include <QStandardPaths>
namespace Paths
{
    QDir appDataRoot()
    {
        // Путь статичен на всю жизнь процесса (02#26): QStandardPaths-лукап + mkpath
        // корня делаем ОДИН раз (thread-safe static init), дальше лишь оборачиваем строку.
        static const QString root = []() {
            QString r = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
            if (r.isEmpty()) r = QDir::currentPath();
            QDir(r).mkpath(QStringLiteral("."));
            return r;
        }();
        return QDir(root);
    }

    QDir profilesRoot()
    {
        static const QString path = []() {
            QDir root = appDataRoot();
            root.mkpath(QStringLiteral("profiles"));
            return root.filePath(QStringLiteral("profiles"));
        }();
        return QDir(path);
    }

    QString profilesManifest() { return appDataRoot().filePath(QStringLiteral("profiles.json")); }
    QString deviceKey() { return appDataRoot().filePath(QStringLiteral("device_key.json")); }
    QString pendingRegistrationKey() { return appDataRoot().filePath(QStringLiteral("pending_registration_key.json")); }
    QString admins() { return appDataRoot().filePath(QStringLiteral("admins.crypt")); }
    QString vaultState() { return appDataRoot().filePath(QStringLiteral("vault.json")); }

    bool isVaultProtected(const QString &path)
    {
        // Эталонные пути статичны → чистим их ОДИН раз (02#26); зовётся в начале
        // каждого readAll/writeFile, включая каждый saveDialogs.
        static const QString vaultC        = QDir::cleanPath(vaultState());
        static const QString manifestC     = QDir::cleanPath(profilesManifest());
        static const QString deviceC       = QDir::cleanPath(deviceKey());
        static const QString pendingC      = QDir::cleanPath(pendingRegistrationKey());
        static const QString adminsC       = QDir::cleanPath(admins());
        static const QString profilesRootC = QDir::cleanPath(profilesRoot().path());
        const QString canonical            = QDir::cleanPath(path);
        if (canonical == vaultC) return false; // сам vault.json — plaintext
        if (canonical == manifestC || canonical == deviceC || canonical == pendingC || canonical == adminsC)
            return true;
        if (canonical.startsWith(profilesRootC + QLatin1Char('/'))) return true;
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
