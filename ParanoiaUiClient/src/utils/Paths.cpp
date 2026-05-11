#include "Paths.hpp"
#include <QDir>
namespace Paths
{
    QDir profileDir(const QString &profileId) { return profilesRoot.filePath(profileId); }
    QString profileClient(const QString &profileId) { return profileDir(profileId).filePath(client); }
    QString profileDialogs(const QString &profileId) { return profileDir(profileId).filePath(dialogs); }
    QString profileDb(const QString &profileId) { return profileDir(profileId).filePath(db); }
    bool ensureProfileDir(const QString &profileId) { return profileDir(profileId).mkpath("./"); }
}