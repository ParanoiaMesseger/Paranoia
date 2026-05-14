#pragma once
#include <vector>
#include <QFuture>
#include <QString>
#include <QStringList>

namespace admin
{

    struct Admin {
        QString domain;
        QString private_key;
        QStringList reserveServerUrls;
        Q_INVOKABLE QFuture<bool> regUser(const QString &username, const QString &pubkey) const;

        static void initAdmins();

        static std::vector<Admin> admins;

        static void saveAdmins();
    };

}
