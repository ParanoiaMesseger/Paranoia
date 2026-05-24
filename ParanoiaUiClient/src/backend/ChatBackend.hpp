#pragma once
#include <QQmlEngine>
#include <QVariantList>
#include <QSet>
#include <QTimer>
#include <QMap>
#include <Qt>

class ChatBackend : public QObject
{
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(bool messagesLoading READ messagesLoading NOTIFY messagesLoadingChanged)
    Q_PROPERTY(bool readReceiptsEnabled READ readReceiptsEnabled NOTIFY readReceiptsEnabledChanged)

public:
    explicit ChatBackend(QObject *parent = nullptr);
    ~ChatBackend() override;

    bool messagesLoading() const;
    bool readReceiptsEnabled() const;

    Q_INVOKABLE void openChat(const QString &peer);
    Q_INVOKABLE void stopChat();
    Q_INVOKABLE void sendText(const QString &text);
    Q_INVOKABLE void sendReaction(const QString &targetId, const QString &emoji);
    Q_INVOKABLE void sendFile(const QString &fileUrlOrPath);
    Q_INVOKABLE void fetchMessages();
    Q_INVOKABLE void saveAttachment(const QString &messageId, const QString &targetUrlOrPath);
    Q_INVOKABLE void ensureImagePreview(const QString &messageId);
    Q_INVOKABLE void deleteMessagesUntil(quint64 cutSeq);
    Q_INVOKABLE void setReadReceiptsEnabled(bool enabled);
    Q_INVOKABLE void requestFileAccessPermissions();
    Q_INVOKABLE void commitInputMethod();

signals:
    void messagesReceived(const QString &peer, const QVariantList &messages);
    void sendError(const QString &msg);
    void receiveError(const QString &msg);
    void attachmentSaved(const QString &path);
    void messagesLoadingChanged();
    void readReceiptsEnabledChanged();
    void dialogsChanged();
    void serverHistoryCleared(const QString &peer);
    void serverHistoryError(const QString &msg);
    // Cross-backend coordination
    void activePeerChanged(const QString &peer);
    void peerMessagesRead(const QString &peer);
    void backgroundMessagesReceived(const QString &profileId, const QString &peer, quint64 count);

public slots:
    void onDialogRemoved(const QString &peer);
    void onSessionReset();
    void onNetworkRestored();
    void onApplicationStateChanged(Qt::ApplicationState state);

private slots:
    void onActivePollTimer();

private:
    QString m_activePeer;
    QMap<QString, QVariantList> m_messageCache;
    QMap<QString, QSet<QString>> m_seenIds;
    QMap<QString, QSet<QString>> m_appliedReactionIds;
    QTimer *m_activePollTimer;
    QSet<QString> m_sendInFlightKeys;
    QSet<QString> m_previewInFlightIds;
    QMap<QString, qint64> m_recentSendAtMs;
    bool m_receiveInFlight          = false;
    bool m_receiveAgainAfterCurrent = false;
    int m_messageLoadingJobs        = 0;
    bool m_activePollInFlight       = false;
    bool m_arrivedInFlight          = false;
    int m_activePollRetryCount      = 0;

    void loadHistory(const QString &peer);
    void appendMessages(const QString &peer, const QVariantList &messages);
    void beginMessagesLoading();
    void endMessagesLoading();
    void pollActiveChat();
    void refreshArrivedStatus();
    void scheduleActiveChatPoll(int delayMs = -1);
    static int randomActiveNotifyDelayMs();
    int retryActiveNotifyDelayMs() const;
    static QVariantList parseMessages(const QString &json);
    static QString extractText(const QString &debugContent);
};
