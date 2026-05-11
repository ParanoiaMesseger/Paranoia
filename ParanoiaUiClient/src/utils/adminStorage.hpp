#pragma once
#include <vector>
#include <QFuture>

namespace admin
{

    struct Admin {
        QString domain;
        QString private_key;
        Q_INVOKABLE QFuture<bool> regUser(const QString &username, const QString &pubkey) const;

        static void initAdmins();

        static std::vector<Admin> admins;

        static void saveAdmins();
    };

}
