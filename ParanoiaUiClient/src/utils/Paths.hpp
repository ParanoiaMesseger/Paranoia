#pragma once
#include <QDir>
#include <QString>

namespace Paths
{
    const QDir profilesRoot        = QStringLiteral("profiles");
    const QString profilesManifest = QStringLiteral("profiles.json");
    const QString client           = QStringLiteral("client.json");
    const QString dialogs          = QStringLiteral("dialogs.json");
    const QString db               = QStringLiteral("paranoia.db");

    QDir profileDir(const QString &profileId);
    QString profileClient(const QString &profileId);
    QString profileDialogs(const QString &profileId);
    QString profileDb(const QString &profileId);

    bool ensureProfileDir(const QString &profileId);
}