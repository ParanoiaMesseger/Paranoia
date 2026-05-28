#pragma once
#include <QList>
#include <QString>

struct DialogKeyEntry {
    quint64 startSeq;
    QByteArray key;
};

class Dialog
{
public:
    static QByteArray deriveKey(const QString &sharedSecret);
    static QList<Dialog> loadFromPath(const QString &path);
    static void saveToPath(const QString &path, const QList<Dialog> &dialogs);

    QString keyringJson() const;

    QString peer;
    QString peerServerId;
    QList<DialogKeyEntry> keyring;
    QString lastMsg;
    // Локальный черновик ввода (не синхронизируется с сервером). Хранится
    // здесь же, чтобы не плодить лишних файлов и чтобы профиль самосогласован.
    QString draft;
    bool receiptsEnabled = true;
};
