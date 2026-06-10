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
    // Локальное имя диалога (alias) — отображается вместо server_id/username.
    // Локальное, не синхронизируется. Пусто → показываем peer.
    QString localName;
    // Локальный аватар: base64 PNG (квадрат ~64×64), кружок клипит UI. Хранится
    // в зашифрованном dialogs (в vault), не файлом на диске. Пусто → буква.
    QString avatar;
    // Время последней активности диалога (ms epoch) — ключ сортировки списка
    // диалогов по свежести (как в Telegram). Обновляется при отправке/получении
    // сообщения, НЕ при прочтении — чтобы открытие диалога не переставляло
    // строку под пальцем. Аддитивное поле (default 0 → в конец списка).
    qint64 lastActivityMs = 0;
};
