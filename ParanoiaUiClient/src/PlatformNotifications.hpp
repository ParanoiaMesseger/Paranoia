#pragma once

#include <QtGlobal>
#include <QString>
#include <functional>

namespace PlatformNotifications
{
    void registerBackgroundTasks();
    void setBackgroundPollCallback(std::function<void()> callback);
    void startBackgroundPollingService();
    void stopBackgroundPollingService();
    void showMessageCount(quint64 count, const QString &peer = {});
    QString takeOpenPeerFromNotification();
    void triggerBackgroundPoll();
}
