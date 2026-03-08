#include "adminStorage.hpp"
#include "paranoia_lib.h"
#include <QtConcurrent>
#include <qobject.h>

std::vector<admin::Admin> admin::Admin::admins = {};

QFuture<bool> admin::Admin::regUser(const QString &username, const QString &pubkey)
{
    return QtConcurrent::run([this, username, pubkey]() -> bool {
        return paranoia_register_user(domain.toUtf8().constData(), username.toUtf8().constData(),
                                      pubkey.toUtf8().constData(), private_key.toUtf8().constData()) == 0;
    });
}

void admin::Admin::initAdmins()
{
    for (const auto &i : QString::fromUtf8(QFile("admins.crypt").readAll()).split("\n"))
        if (auto tmp = i.split(":"); tmp.size() == 2) admins.push_back({tmp[0], tmp[1]});
}

void admin::Admin::saveAdmins()
{
    QFile file("admins.crypt");
    QDataStream out(&file);
    for (auto i : admins) out << i.domain.toUtf8() << ":" << i.private_key.toUtf8() << "\n";
    file.close();
}
