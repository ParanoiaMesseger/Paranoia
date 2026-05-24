#pragma once

#include <QtGlobal>
#include <QString>
#include <functional>

namespace PlatformNotifications
{
    struct NotificationTarget {
        QString profileId;
        QString peer;
    };

    void registerBackgroundTasks();
    void setBackgroundPollCallback(std::function<void()> callback);
    void setApplicationForeground(bool foreground);
    void startBackgroundPollingService();
    void stopBackgroundPollingService();
    void showMessageCount(quint64 count, const QString &profileId, const QString &peer = {});
    NotificationTarget takeOpenTargetFromNotification();
    QString takeOpenPeerFromNotification();
    void triggerBackgroundPoll();
}
