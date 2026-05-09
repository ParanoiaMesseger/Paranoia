#include "adminStorage.hpp"

#include "Utils.hpp"

#include <QtConcurrent>

#include "paranoia_lib.h"

std::vector<admin::Admin> admin::Admin::admins = {};

QFuture<bool> admin::Admin::regUser(const QString &username, const QString &pubkey) const
{
    return QtConcurrent::run([this, username, pubkey]() -> bool {
        return ParanoiaFFI::register_user(domain, username, pubkey, private_key) == 0;
    });
}

void admin::Admin::initAdmins()
{
    for (const auto &i : QString::fromUtf8(Utils::readAll("admins.crypt")).split("\n"))
        if (auto tmp = i.split(";"); tmp.size() == 2) admins.push_back({tmp[0], tmp[1]});
}

void admin::Admin::saveAdmins()
{
    QFile file("admins.crypt");
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)) return;
    for (const auto &[domain, private_key] : admins) file.write((domain + ";" + private_key + "\n").toUtf8());
}
