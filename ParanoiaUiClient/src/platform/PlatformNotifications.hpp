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
    // Очистка всех ранее показанных уведомлений о новых сообщениях. Вызывается,
    // когда приложение выходит в foreground — даже если открыто не по тапу
    // уведомления, накопленные карточки в шторке должны исчезнуть.
    void clearAccumulatedNotifications();
    NotificationTarget takeOpenTargetFromNotification();
    QString takeOpenPeerFromNotification();
    void triggerBackgroundPoll();

    /// Передать notification-сервису свежий polling snapshot. JSON см.
    /// ParanoiaForegroundService.publishSnapshot. Сервис держит snapshot
    /// строго в RAM (никакой persistence) — на каждый запуск процесса
    /// snapshot нужно пушить заново. На non-Android платформах no-op.
    void publishServiceSnapshot(const QString &snapshotJson);
    /// Очистить snapshot в сервисе (logout). Следующий poll увидит «нет целей»
    /// и сервис остановится. На non-Android no-op.
    void clearServiceSnapshot();
}
