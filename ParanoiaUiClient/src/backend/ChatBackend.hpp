#pragma once
#include <QQmlEngine>
#include <QVariantList>
#include <QSet>
#include <QTimer>
#include <QMap>
#include <Qt>

class EncryptedImageProvider;

class ChatBackend : public QObject
{
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(bool messagesLoading READ messagesLoading NOTIFY messagesLoadingChanged)
    Q_PROPERTY(bool readReceiptsEnabled READ readReceiptsEnabled NOTIFY readReceiptsEnabledChanged)
    Q_PROPERTY(int filesInFlight READ filesInFlight NOTIFY filesInFlightChanged)

public:
    explicit ChatBackend(QObject *parent = nullptr);
    ~ChatBackend() override;

    bool messagesLoading() const;
    bool readReceiptsEnabled() const;
    int filesInFlight() const { return m_filesInFlight; }

    /// Передать собственный ImageProvider — в него ChatBackend кладёт
    /// расшифрованные байты превью. Plaintext НЕ пишется на диск.
    void setImageProvider(EncryptedImageProvider *provider) { m_imageProvider = provider; }

    Q_INVOKABLE void openChat(const QString &peer);
    Q_INVOKABLE void stopChat();
    Q_INVOKABLE void sendText(const QString &text);
    Q_INVOKABLE void sendTextReply(const QString &text, const QString &replyToId, const QString &replySender,
                                   const QString &replyText);
    Q_INVOKABLE void sendReaction(const QString &targetId, const QString &emoji);
    Q_INVOKABLE void sendFile(const QString &fileUrlOrPath);
    Q_INVOKABLE void fetchMessages();
    Q_INVOKABLE void saveAttachment(const QString &messageId, const QString &targetUrlOrPath);
    Q_INVOKABLE void ensureImagePreview(const QString &messageId);
    Q_INVOKABLE void deleteMessagesUntil(quint64 cutSeq);
    /// Удалить выделенные сообщения сразу на сервере и в локальной БД.
    /// `messageIds` — id'шники сообщений из модели чата. Для прикреплённых
    /// файлов автоматически включает диапазон чанков `[body_from_seq, body_to_seq]`.
    Q_INVOKABLE void deleteMessages(const QStringList &messageIds);
    /// Удалить только тела чанков выбранного вложения с сервера (используется
    /// после успешного скачивания файла, когда пользователь согласился убрать
    /// файл с сервера).
    Q_INVOKABLE void removeAttachmentChunksFromServer(const QString &messageId);
    Q_INVOKABLE void setReadReceiptsEnabled(bool enabled);
    Q_INVOKABLE void requestFileAccessPermissions();
    Q_INVOKABLE void commitInputMethod();

    // Запускает системную галерею (фото/видео) на Android. URI результата
    // забирается на следующем переходе app→foreground и сразу отправляется
    // через sendFile (см. consumePickedAttachment).
    Q_INVOKABLE void pickPhotoFromGallery();
    Q_INVOKABLE void pickVideoFromGallery();

    // Локальные черновики (несинхронизированные с сервером). Хранятся как
    // поле Dialog::draft внутри dialogs.json — не плодим лишних файлов и
    // профиль остаётся самосогласован.
    Q_INVOKABLE QString getDraft(const QString &peer) const;
    Q_INVOKABLE void setDraft(const QString &peer, const QString &text);
    Q_INVOKABLE void clearDraft(const QString &peer);

signals:
    void messagesReceived(const QString &peer, const QVariantList &messages);
    void sendError(const QString &msg);
    void receiveError(const QString &msg);
    void attachmentSaved(const QString &path);
    /// Файл успешно скачан (или закеширован) с сервера и доступен локально.
    /// QML по этому сигналу предлагает удалить чанки с сервера.
    void attachmentDownloaded(const QString &messageId, const QString &filename);
    /// Сообщения удалены (применили ranged-delete) — UI чистит кэш и
    /// перетягивает messages.
    void messagesDeleted(const QString &peer);
    void messagesLoadingChanged();
    void readReceiptsEnabledChanged();
    void filesInFlightChanged();
    // Прогресс отправки отдельного файла: transferKey уникальный за один
    // отдельный sendFile-вызов (см. m_sendInFlightKeys), chunkIndex 1-based.
    // Если total <= chunkIndex — отправка завершена.
    void fileProgress(const QString &transferKey, quint32 chunkIndex, quint32 total);
    void dialogsChanged();
    void serverHistoryCleared(const QString &peer);
    void serverHistoryError(const QString &msg);
    // Cross-backend coordination
    void activePeerChanged(const QString &peer);
    void peerMessagesRead(const QString &peer);
    void backgroundMessagesReceived(const QString &profileId, const QString &peer, quint64 count);
    /// Эмитится после успешного receive_keyring, который реально подтянул
    /// новые сообщения (последний known seq в SQLCipher сдвинулся).
    /// MainBackend подхватывает и пушит свежий snapshot в notifications-сервис.
    void pulledNewMessages();

public slots:
    void onDialogRemoved(const QString &peer);
    void onSessionReset();
    void onNetworkRestored();
    void onApplicationStateChanged(Qt::ApplicationState state);
    /// «Прогреть» SQLCipher: пройтись по всем диалогам активной сессии и
    /// дёрнуть receive_keyring. Используется при unlock'е — пользователь
    /// получает свежие сообщения в UI сразу, без ожидания alarm'а сервиса.
    /// Если активного peer'а нет, ничего не emit'ится в QML.
    void prefetchAllDialogs();

private slots:
    void onActivePollTimer();

private:
    QString m_activePeer;
    QMap<QString, QVariantList> m_messageCache;
    QMap<QString, QSet<QString>> m_seenIds;
    QMap<QString, QSet<QString>> m_appliedReactionIds;
    void consumePickedAttachment();
    QTimer *m_activePollTimer;
    QSet<QString> m_sendInFlightKeys;
    QSet<QString> m_previewInFlightIds;
    QMap<QString, qint64> m_recentSendAtMs;
    bool m_receiveInFlight          = false;
    bool m_receiveAgainAfterCurrent = false;
    int m_messageLoadingJobs        = 0;
    int m_filesInFlight             = 0;
    void incrementFilesInFlight();
    void decrementFilesInFlight();
    bool m_activePollInFlight       = false;
    bool m_arrivedInFlight          = false;
    int m_activePollRetryCount      = 0;
    EncryptedImageProvider *m_imageProvider = nullptr;

    void loadHistory(const QString &peer);
    void appendMessages(const QString &peer, const QVariantList &messages);
    void beginMessagesLoading();
    void endMessagesLoading();
    void pollActiveChat();
    void refreshArrivedStatus();
    void scheduleActiveChatPoll(int delayMs = -1);
    static int randomActiveNotifyDelayMs();
    int retryActiveNotifyDelayMs() const;
    void sendTextMessage(const QString &text, const QString &replyToId = {}, const QString &replySender = {},
                         const QString &replyText = {});
    QVariantList parseMessages(const QString &json) const;
};
