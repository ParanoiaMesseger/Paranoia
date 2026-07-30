#pragma once
#include "Dialog.hpp"
#include <QVariantMap>
#include <ParanoiaFFI>
#include <QList>
#include <QMutex>
#include <QString>
#include <QStringList>
#include <memory>

// Асинхронная коалесирующая запись dialogs.json (см. ServerSession.cpp). Держим
// по указателю, чтобы тип оставался неполным в заголовке — поэтому деструктор
// ServerSession объявлен здесь и определён в .cpp, где DialogSaveQueue полный.
class DialogSaveQueue;

class ServerSession
{
public:
    ServerSession(std::shared_ptr<ParanoiaFFI> ffi, const QString &server, const QString &username,
                  const QString &serverId, const QString &privateKey, const QString &profileId,
                  const QStringList &reserveServerUrls, const QStringList &turnServerUrls = {});
    ~ServerSession();

    ServerSession(const ServerSession &)            = delete;
    ServerSession &operator=(const ServerSession &) = delete;
    bool isLoggedIn() const;
    Dialog *findDialog(const QString &peer);
    const Dialog *findDialog(const QString &peer) const;
    // Поиск по СТАБИЛЬНОМУ идентификатору собеседника на сервере. В отличие от
    // метки `peer` (её пользователь меняет и она может совпасть у разных
    // собеседников) peerServerId уникален — на нём держится корректная
    // привязка ключей/имени/аватара. Пустой serverId не матчит ничего.
    Dialog *findDialogByServerId(const QString &serverId);
    // Ставит текущий снимок диалогов в очередь на асинхронную запись (коалесинг,
    // last-write-wins). Возвращается сразу — сериализация+vault-шифр+диск уходят
    // на QThreadPool. Снимок снимается на вызывающем потоке (владельце dialogs).
    void saveDialogs() const;
    // Блокирует вызывающий поток, пока фоновая запись dialogs.json не завершится.
    // Звать перед разрушающими каталог профиля операциями (rekey/rename/remove) и
    // на выходе приложения — иначе async-снимок мог бы лечь на диск уже во время них.
    void flushDialogs() const;
    void saveClientConfig() const;
    static void saveClientConfigForProfile(const QString &profileId, const QString &server, const QString &username,
                                           const QString &serverId, const QString &privateKey,
                                           const QStringList &reserveServerUrls = {},
                                           const QStringList &turnServerUrls    = {});

    /// Нет смысла делать приавтными поля, которые делаешь доступными через get/set.
    const QString server;
    // Не const: для корпоративных профилей отображаемое имя (ФИО) приходит с
    // корп-сервера в связке и может обновляться (см. applyCorporateKeyring).
    QString username;
    const QString serverId;
    const QString private_key;
    const QString profileId;
    const QStringList reserveServerUrls;
    /// Резервные TURN-серверы для VoIP-fallback'а. Первичный TURN всегда
    /// выводится из активной session-URL'а; этот список — дополнительные,
    /// используемые когда первичный недоступен (см. CallController::ICE
    /// connectivity checks). Формат каждого: "host:port" или "host" (тогда
    /// порт 3478 по умолчанию).
    QStringList turnServerUrls;
    QList<Dialog> dialogs;
    mutable QMutex ffiMutex;
    // Сериализует ИСХОДЯЩИЕ отправки одной сессии (атомарность set_active_topic→send_*
    // + порядок seq). Отдельный от ffiMutex: read/inbound-операции копируют `ffi` под
    // ffiMutex и работают уже БЕЗ него, поэтому НЕ встают за многоминутным аплоадом
    // (send держит sendMutex, а не ffiMutex) — корень конвоя 01#32.
    mutable QMutex sendMutex;
    std::shared_ptr<ParanoiaFFI> ffi;

private:
    // Очередь фоновой записи dialogs.json (создаётся, только если profileId задан).
    // shared_ptr: воркер держит свою копию, поэтому запись доживает до конца даже
    // если сессия уже разрушена (снимок снят по значению, путь хранится в очереди).
    std::shared_ptr<DialogSaveQueue> m_saveQueue;
};
