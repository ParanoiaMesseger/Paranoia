#pragma once
#include <QString>
#include <vector>
#include <QFuture>
#include <QFile>

namespace admin
{

    struct Admin {
        QString domain;
        QString private_key;
        Q_INVOKABLE QFuture<bool> regUser(const QString &username, const QString &pubkey);

        static void initAdmins();
        static std::vector<Admin> admins;
        static void saveAdmins();
    };

}
