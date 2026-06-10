#include "Dialog.hpp"

#include "Paths.hpp"
#include "utils/Utils.hpp"

#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <algorithm>

QString Dialog::keyringJson() const
{
    QJsonArray arr;
    for (const auto &entry : keyring) {
        if (entry.key.size() != 32 || entry.startSeq == 0) continue;
        QJsonObject obj;
        obj["start_seq"] = static_cast<double>(entry.startSeq);
        obj["key"]       = QString::fromLatin1(entry.key.toBase64());
        arr.append(obj);
    }
    return QString::fromUtf8(QJsonDocument(arr).toJson(QJsonDocument::Compact));
}

QByteArray Dialog::deriveKey(const QString &sharedSecret)
{ return QCryptographicHash::hash(sharedSecret.toUtf8(), QCryptographicHash::Sha256); }

QList<Dialog> Dialog::loadFromPath(const QString &path)
{
    QList<Dialog> dialogs;
    const QJsonArray jsonArr = Utils::readJsonArrayFile(path);
    for (const auto &val : jsonArr) {
        auto obj             = val.toObject();
        QString peer         = obj["peer"].toString();
        QString peerServerId = obj["peerServerId"].toString();
        QString lastMsg      = obj["lastMsg"].toString();
        QString draft         = obj["draft"].toString();
        bool receiptsEnabled  = obj["receiptsEnabled"].toBool(true);
        QString localName     = obj["localName"].toString();
        QString avatar        = obj["avatar"].toString();
        qint64 lastActivityMs = static_cast<qint64>(obj["lastActivityMs"].toDouble(0));
        QList<DialogKeyEntry> keyring;

        const QJsonArray keyringJson = obj["keyring"].toArray();
        for (const auto &keyVal : keyringJson) {
            const auto keyObj      = keyVal.toObject();
            bool ok                = false;
            const quint64 startSeq = Utils::readSeq(keyObj["start_seq"], &ok);
            const QByteArray key   = QByteArray::fromBase64(keyObj["key"].toString().toLatin1());
            if (ok && key.size() == 32) keyring.append({startSeq, key});
        }

        std::sort(keyring.begin(), keyring.end(),
                  [](const DialogKeyEntry &lhs, const DialogKeyEntry &rhs) { return lhs.startSeq < rhs.startSeq; });
        if (!peer.isEmpty())
            dialogs.append({peer, peerServerId, keyring, lastMsg, draft, receiptsEnabled, localName, avatar,
                            lastActivityMs});
    }
    return dialogs;
}

void Dialog::saveToPath(const QString &path, const QList<Dialog> &dialogs)
{
    const QString profileId = Paths::profilesRoot().relativeFilePath(QFileInfo(path).dir().path());
    if (!profileId.isEmpty() && !profileId.startsWith("..")) Paths::ensureProfileDir(profileId);
    QJsonArray arr;
    for (const auto &d : dialogs) {
        QJsonObject o;
        o["peer"]         = d.peer;
        o["peerServerId"] = d.peerServerId;
        QJsonArray keyring;
        for (const auto &entry : d.keyring) {
            if (entry.key.size() != 32 || entry.startSeq == 0) continue;
            QJsonObject keyObj;
            keyObj["start_seq"] = static_cast<double>(entry.startSeq);
            keyObj["key"]       = QString::fromLatin1(entry.key.toBase64());
            keyring.append(keyObj);
        }
        o["keyring"]         = keyring;
        o["lastMsg"]         = d.lastMsg;
        if (!d.draft.isEmpty()) o["draft"] = d.draft;
        o["receiptsEnabled"] = d.receiptsEnabled;
        if (!d.localName.isEmpty()) o["localName"] = d.localName;
        if (!d.avatar.isEmpty()) o["avatar"] = d.avatar;
        if (d.lastActivityMs > 0) o["lastActivityMs"] = static_cast<double>(d.lastActivityMs);
        arr.append(QJsonValue(o));
    }
    // Через Utils::writeFile — для путей внутри profiles/ это уйдёт в
    // paranoia_vault_encrypt_json и ляжет на диск зашифрованным.
    // Прямая запись через QFile сломает следующее чтение (нет magic PVL1).
    if (Utils::writeFile(path, QJsonDocument(arr).toJson()))
        Utils::setOwnerOnlyPermissions(path);
}
