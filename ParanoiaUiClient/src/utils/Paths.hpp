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
    QString admins();
    QString vaultState();

    /// Является ли путь "защищаемым" — должен ли проходить через encrypted IO vault'а.
    /// Защищаем: vault.json НЕ защищаем (это его собственное хранилище);
    /// profiles.json, device_key.json, pending_registration_key.json, admins.crypt,
    /// и любые файлы внутри profiles/<id>/ (client.json, dialogs.json).
    bool isVaultProtected(const QString &path);

    QDir profileDir(const QString &profileId);
    QString profileClient(const QString &profileId);
    QString profileDialogs(const QString &profileId);
    QString profileDb(const QString &profileId);

    bool ensureProfileDir(const QString &profileId);
}
