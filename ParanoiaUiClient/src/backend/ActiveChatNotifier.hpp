#pragma once

#include <QMutex>
#include <QObject>
#include <QString>
#include <QThread>
#include <atomic>
#include <memory>

class ParanoiaFFI;

/// Near-real-time приём активного диалога через long-poll notify
/// (`notify_count_wait_keyring`) на ОТДЕЛЬНОМ потоке.
///
/// Зачем отдельный поток: long-poll держит ответ сервера до ~25 c. Делать его на
/// общем `session->ffiMutex` НЕЛЬЗЯ — он заблокировал бы все прочие FFI (история/
/// отправка/превью) → фриз UI. Поэтому, как и `CallSignalingClient` для
/// сигнализации звонков, крутим long-poll на своём `QThread` БЕЗ общего мьютекса
/// (handle расшарен; конкурентные вызовы переживает — тот же паттерн, что у звонков).
///
/// При появлении новых сообщений эмитит `messagesWaiting` (очередь в main-поток),
/// по которому ChatBackend забирает их `fetchMessages()`. Короткий поллер остаётся
/// редким — как fallback и для обновления read-receipt'ов.
class ActiveChatNotifier : public QObject
{
    Q_OBJECT
public:
    explicit ActiveChatNotifier(QObject *parent = nullptr);
    ~ActiveChatNotifier() override;

    /// Настроить цель long-poll'а (handle + идентификаторы диалога). Инкремент
    /// поколения → текущий висящий long-poll по возврату будет отброшен. Пустой
    /// `peerId`/`keyringJson` = нет цели (воркер просто спит-бэкофит).
    void configure(std::shared_ptr<ParanoiaFFI> handle, const QString &serverId, const QString &peerId,
                   const QString &keyringJson);
    void start();
    void stop();
    bool running() const { return running_.load(); }

signals:
    /// Появились новые/непрочитанные — забрать (ChatBackend → fetchMessages).
    void messagesWaiting();

private:
    struct Snapshot {
        std::shared_ptr<ParanoiaFFI> handle;
        QString serverId;
        QString peerId;
        QString keyringJson;
        quint64 generation = 0;
    };
    Snapshot snapshot() const;
    bool isCurrentGeneration(quint64 generation) const;
    void workerLoop();

    QThread thread_;
    mutable QMutex mutex_;
    std::shared_ptr<ParanoiaFFI> handle_;
    QString serverId_;
    QString peerId_;
    QString keyringJson_;
    quint64 generation_ = 0;
    std::atomic<bool> running_{false};
    std::atomic<bool> stop_{false};
};
