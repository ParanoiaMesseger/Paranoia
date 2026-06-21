#pragma once
#include <QQmlEngine>
#include <QVariantList>
#include <QSet>
#include <QTimer>
#include <QMap>
#include <Qt>

class EncryptedImageProvider;
class ActiveChatNotifier;
class QMediaCaptureSession;
class QMediaRecorder;
class QAudioInput;

class ChatBackend : public QObject
{
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(bool messagesLoading READ messagesLoading NOTIFY messagesLoadingChanged)
    Q_PROPERTY(bool readReceiptsEnabled READ readReceiptsEnabled NOTIFY readReceiptsEnabledChanged)
    Q_PROPERTY(int filesInFlight READ filesInFlight NOTIFY filesInFlightChanged)
    // Запись голосового сообщения (через QMediaRecorder).
    Q_PROPERTY(bool voiceRecording READ voiceRecording NOTIFY voiceRecordingChanged)

public:
    explicit ChatBackend(QObject *parent = nullptr);
    ~ChatBackend() override;

    bool messagesLoading() const;
    bool readReceiptsEnabled() const;
    int filesInFlight() const { return m_filesInFlight; }
    bool voiceRecording() const { return m_voiceRecording; }

    /// Передать собственный ImageProvider — в него ChatBackend кладёт
    /// расшифрованные байты превью. Plaintext НЕ пишется на диск.
    void setImageProvider(EncryptedImageProvider *provider) { m_imageProvider = provider; }

    Q_INVOKABLE void openChat(const QString &peer);
    Q_INVOKABLE void stopChat();
    Q_INVOKABLE void sendText(const QString &text);
    /// Повторная отправка ранее упавшего (status=failed) исходящего сообщения по его
    /// client_token (тап по крестику в пузыре). Возвращает статус в "sending" и
    /// перезапускает сетевую отправку из сохранённой записи аутбокса.
    Q_INVOKABLE void retrySend(const QString &clientToken);
    Q_INVOKABLE void sendTextReply(const QString &text, const QString &replyToId, const QString &replySender,
                                   const QString &replyText);
    Q_INVOKABLE void sendReaction(const QString &targetId, const QString &emoji);
    Q_INVOKABLE void sendFile(const QString &fileUrlOrPath);
    // Отправить несколько фото как группу (мозаику) с общей подписью `caption`
    // (может быть пустой). Каждое фото — отдельное image-сообщение с общим
    // group_id; UI рендерит их мозаикой. Файлы крупнее лимита истории сюда
    // передавать нельзя (вызывающая сторона должна отфильтровать).
    Q_INVOKABLE void sendPhotoGroup(const QStringList &fileUrlsOrPaths, const QString &caption);
    Q_INVOKABLE void fetchMessages();
    Q_INVOKABLE void saveAttachment(const QString &messageId, const QString &targetUrlOrPath);
    /// Сохранить вложение ОДНИМ ТАПОМ в папку по умолчанию (фото → Изображения/Paranoia,
    /// файлы → Загрузки/Paranoia), без диалога выбора. QML вызывает это с 0.2.14; C++-
    /// реализация была потеряна (незакоммичена) → скачивание молча падало. Восстановлено.
    Q_INVOKABLE void saveAttachmentToDefault(const QString &messageId);
    Q_INVOKABLE void ensureImagePreview(const QString &messageId);
    /// Материализовать видео-вложение в расшифрованный временный mp4 для
    /// проигрывания нативным плеером. Асинхронно: по готовности — сигнал
    /// videoReadyForPlayback(messageId, fileUrl); при ошибке — videoPlaybackError.
    Q_INVOKABLE void cacheVideoForPlayback(const QString &messageId);
    /// Удалить конкретный материализованный playback-файл (расшифрованное
    /// видео/голос) — вызывается при закрытии плеера, чтобы plaintext не залёживался.
    Q_INVOKABLE void releasePlaybackFile(const QString &fileUrl);
    /// Очистить ВЕСЬ playback-кэш (paranoia_play) — при выходе из диалога.
    Q_INVOKABLE void clearPlaybackCache();

    // ── Голосовые сообщения (запись с микрофона) ──
    /// Начать запись голосового во временный файл. Эмитит voiceRecordingChanged.
    Q_INVOKABLE void startVoiceRecording();
    /// Остановить запись и ОТПРАВИТЬ как голосовое (audio/* → AttachmentKind::Voice).
    Q_INVOKABLE void sendVoiceRecording();
    /// Остановить запись и ВЫБРОСИТЬ (отмена).
    Q_INVOKABLE void cancelVoiceRecording();
    /// Синхронно перерисовать модель из ТЕКУЩЕГО кэша (без FFI-раунда). Нужно
    /// для мгновенного показа оптимистичной мозаики при старте отправки.
    Q_INVOKABLE void emitCachedMessages();
    Q_INVOKABLE void deleteMessagesUntil(quint64 cutSeq);
    /// Удалить выделенные сообщения сразу на сервере и в локальной БД.
    /// `messageIds` — id'шники сообщений из модели чата. Для прикреплённых
    /// файлов автоматически включает диапазон чанков `[body_from_seq, body_to_seq]`.
    Q_INVOKABLE void deleteMessages(const QStringList &messageIds);
    /// Удалить только тела чанков выбранного вложения с сервера (используется
    /// после успешного скачивания файла, когда пользователь согласился убрать
    /// файл с сервера).
    Q_INVOKABLE void removeAttachmentChunksFromServer(const QString &messageId);
    /// Полная история диалога для экрана «Вложения» (без лимита окна чата).
    /// Грузится в отдельном потоке (FFI с большим лимитом), НЕ трогает кэш/окно
    /// чата; результат — сигналом attachmentsHistoryLoaded(peer, messages).
    Q_INVOKABLE void loadAllForAttachments(const QString &peer);
    /// Лениво расшифровать превью ЛЮБОГО изображения диалога (для экрана «Вложения»,
    /// в т.ч. старых, не загруженных в кэш чата). По готовности — galleryPreviewReady.
    Q_INVOKABLE void ensureGalleryPreview(const QString &peer, const QString &messageId);
    Q_INVOKABLE void setReadReceiptsEnabled(bool enabled);
    Q_INVOKABLE void requestFileAccessPermissions();
    Q_INVOKABLE void commitInputMethod();

    // Запускает системную галерею (фото/видео) на Android. URI результата
    // забирается на следующем переходе app→foreground и сразу отправляется
    // через sendFile (см. consumePickedAttachment).
    Q_INVOKABLE void pickPhotoFromGallery();
    Q_INVOKABLE void pickVideoFromGallery();
    // Выбор аватара диалога через системный photo picker (Android). Результат
    // (первое фото) уходит сигналом avatarPhotoPicked(peer, uri), а НЕ в отправку
    // — QML зовёт Backend.setDialogAvatar. peer запоминается до consumePickedAttachment.
    Q_INVOKABLE void pickAvatarFromGallery(const QString &peer);

    // Локальные черновики (несинхронизированные с сервером). Хранятся как
    // поле Dialog::draft внутри dialogs.json — не плодим лишних файлов и
    // профиль остаётся самосогласован.
    Q_INVOKABLE QString getDraft(const QString &peer) const;
    Q_INVOKABLE void setDraft(const QString &peer, const QString &text);
    Q_INVOKABLE void clearDraft(const QString &peer);

signals:
    void messagesReceived(const QString &peer, const QVariantList &messages);
    /// Полная история диалога для экрана «Вложения» (см. loadAllForAttachments).
    void attachmentsHistoryLoaded(const QString &peer, const QVariantList &messages);
    /// Превью изображения для галереи готово (залито в провайдер) — id для рефреша.
    void galleryPreviewReady(const QString &messageId);
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
    // Видео транскодируется в H.264/mp4 ПЕРЕД отправкой. UI показывает
    // «Подготовка…» с прогрессом 0.0..1.0. По завершении транскода — обычный
    // upload-прогресс через fileProgress. finished(ok=false) → транскод не
    // удался, отправляем исходный файл как есть.
    void videoPrepareProgress(const QString &peer, double fraction);
    void videoPrepareFinished(const QString &peer, bool ok);
    // Видео расшифровано во временный файл и готово к проигрыванию: fileUrl —
    // file://-путь к локальному mp4. UI открывает плеер на этот URL.
    void videoReadyForPlayback(const QString &messageId, const QString &fileUrl);
    void videoPlaybackError(const QString &messageId, const QString &error);
    void voiceRecordingChanged();
    // Длительность текущей записи, мс — UI рисует таймер.
    void voiceRecordingDurationMs(qint64 ms);
    // Старт отправки фото-группы: UI сразу рисует оптимистичную мозаику. `photos`
    // — список QVariantMap{key, source(локальный file://), name}. Прогресс по
    // каждому фото приходит через fileProgress(key, ...); по завершении реальные
    // сообщения с тем же groupId заменяют оптимистичные плитки.
    void photoGroupStarted(const QString &groupId, const QString &caption, const QVariantList &photos);
    // Мобильный нативный пикер фото вернул выбор (1+ URI). QML берёт подпись из
    // поля ввода и роутит как мультивыбор десктопа (sendSelectedPhotos):
    // одно фото — обычной отправкой, несколько — мозаикой-группой.
    void attachmentsPicked(const QStringList &uris);
    // Photo picker вернул фото для АВАТАРА диалога peer (URI первого выбранного).
    // QML (MainPage) ловит и зовёт Backend.setDialogAvatar(peer, uri).
    void avatarPhotoPicked(const QString &peer, const QString &uri);
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
#if defined(Q_OS_IOS)
    // Трамплин для PHPicker-делегата (см. IosImagePicker.mm): C-callback → emit
    // avatarPhotoPicked в главном потоке Qt. ctx = this.
    static void iosAvatarPickedTrampoline(void *ctx, const char *path);
#endif
    QString m_activePeer;
    // Peer, для которого открыт photo picker под АВАТАР (Android). Выставляется
    // в pickAvatarFromGallery, потребляется one-shot в consumePickedAttachment.
    QString m_pendingAvatarPeer;
    QMap<QString, QVariantList> m_messageCache;
    QMap<QString, QSet<QString>> m_seenIds;
    QMap<QString, QSet<QString>> m_appliedReactionIds;
    void consumePickedAttachment();
    QTimer *m_activePollTimer;
    // Long-poll near-real-time приёма активного диалога (свой поток, без ffiMutex).
    // Короткий m_activePollTimer остаётся редким fallback'ом + для read-receipt'ов.
    ActiveChatNotifier *m_notifier = nullptr;
    // (Пере)настроить и запустить long-poll-нотифаер на текущий m_activePeer
    // (если залогинены, диалог есть и приложение активно); иначе — остановить.
    void updateNotifier();
    QSet<QString> m_sendInFlightKeys;
    QSet<QString> m_previewInFlightIds;
    // Превью, для которых extract провалился безвозвратно (attachment_not_found):
    // не запрашиваем повторно, иначе при каждом recompose снова дёргаем FFI.
    QSet<QString> m_failedPreviewIds;
    // Коалесинг обновления истории после готовности превью: десятки фото грузятся
    // лавиной, без дебаунса каждый setBytes → loadHistory → recompose (мерцание).
    bool m_previewRefreshPending = false;
    QMap<QString, qint64> m_recentSendAtMs;
    // Аутбокс оптимистичной отправки: исходящее сразу показывается в ленте со статусом
    // "sending" (client_token = синтетический id), а реальная сетевая отправка идёт в
    // фоне. На успехе оптимистичная запись заменяется на committed (по client_token,
    // без дублей/re-pop); на ошибке — помечается "failed" и остаётся в аутбоксе для
    // повторной отправки (retrySend). Это и есть «сообщение появляется сразу с …».
    struct OutboxItem {
        QString peer;
        QString text;
        QString replyToId;
        QString replySender;
        QString replyText;
        qint64  ts = 0;
        QString status = QStringLiteral("sending");   // sending | failed
    };
    QMap<QString, OutboxItem> m_outbox;   // client_token → запись
    void insertOptimisticText(const OutboxItem &item, const QString &clientToken);
    void dispatchOutbox(const QString &clientToken);
    void markOutboxFailed(const QString &peer, const QString &clientToken);
    // Возвращает в кэш не отправленные (оставшиеся в m_outbox) сообщения этого peer'а
    // после перестройки истории (loadHistory чистит кэш) — иначе недоставленные
    // «сбрасывались» при выходе/входе в диалог.
    void reinjectOutbox(const QString &peer);
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

    // ── Голосовая запись (QMediaRecorder) ──
    QMediaCaptureSession *m_captureSession = nullptr;
    QMediaRecorder *m_voiceRecorder        = nullptr;
    QAudioInput *m_audioInput              = nullptr;
    QString m_voiceTempPath;
    bool m_voiceRecording   = false;
    bool m_voicePendingSend = false;
    void ensureVoiceRecorder();
    void finishVoiceRecording(bool send);
    void setVoiceRecording(bool on);

    // clearCache=true (открытие диалога) — полная пересборка кэша из истории.
    // clearCache=false (апдейты: read-receipts/arrived, готовность превью,
    // сохранение вложения) — МЕРЖ свежей истории в существующий кэш через
    // appendMessages БЕЗ очистки: статусы обновляются на месте, реакции/ключи
    // строк сохраняются, лента не пересобирается на каждый апдейт.
    void loadHistory(const QString &peer, bool clearCache = true);
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
