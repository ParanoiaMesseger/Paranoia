#include "adminStorage.hpp"

#include "Utils.hpp"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QtConcurrent>

#include <ParanoiaFFI>

std::vector<admin::Admin> admin::Admin::admins = {};

QFuture<bool> admin::Admin::regUser(const QString &username, const QString &pubkey) const
{
    const QString serverUrl = domain;
    const QString reserveUrlsJson =
        Utils::reserveServerUrlsJson(Utils::normalizedServerUrls(reserveServerUrls, domain));
    const QString adminKey = private_key;
    return QtConcurrent::run([serverUrl, reserveUrlsJson, username, pubkey, adminKey]() -> bool {
        return ParanoiaFFI::register_user(serverUrl, reserveUrlsJson, username, pubkey, adminKey) == 0;
    });
}

void admin::Admin::initAdmins()
{
    admins.clear();
    const QByteArray raw = Utils::readAll("admins.crypt");
    const auto doc       = QJsonDocument::fromJson(raw);
    if (doc.isArray()) {
        for (const auto &value : doc.array()) {
            const auto obj = value.toObject();
            const QString domain =
                Utils::normalizedServerUrl(obj.value("url").toString(obj.value("domain").toString()));
            const QString privateKey = obj.value("admin_private_key_b64").toString(obj.value("private_key").toString());
            const QStringList reserveUrls = Utils::normalizedServerUrls(
                Utils::stringListFromJsonArray(obj.value("reserve_server_urls").toArray()), domain);
            if (!domain.isEmpty() && !privateKey.isEmpty()) admins.push_back({domain, privateKey, reserveUrls});
        }
        return;
    }

    for (const auto &line : QString::fromUtf8(raw).split("\n")) {
        const auto tmp = line.split(";");
        if (tmp.size() == 2) admins.push_back({Utils::normalizedServerUrl(tmp[0]), tmp[1]});
    }
}

void admin::Admin::saveAdmins()
{
    QJsonArray arr;
    for (const auto &admin : admins) {
        QJsonObject obj;
        obj["url"]                   = Utils::normalizedServerUrl(admin.domain);
        obj["admin_private_key_b64"] = admin.private_key;
        obj["reserve_server_urls"] =
            Utils::stringListToJsonArray(Utils::normalizedServerUrls(admin.reserveServerUrls, admin.domain));
        arr.append(obj);
    }
    if (Utils::writeFile("admins.crypt", QJsonDocument(arr).toJson(QJsonDocument::Compact)))
        Utils::setOwnerOnlyPermissions("admins.crypt");
}
