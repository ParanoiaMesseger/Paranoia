#pragma once
#include <QDir>
#include <QString>

namespace Paths
{
    const QString client  = QStringLiteral("client.json");
    const QString dialogs = QStringLiteral("dialogs.json");
    const QString db      = QStringLiteral("paranoia.db");

    QDir appDataRoot();
    QDir profilesRoot();
    QString profilesManifest();
    QString deviceKey();
    QString pendingRegistrationKey();

    QDir profileDir(const QString &profileId);
    QString profileClient(const QString &profileId);
    QString profileDialogs(const QString &profileId);
    QString profileDb(const QString &profileId);

    bool ensureProfileDir(const QString &profileId);
}
