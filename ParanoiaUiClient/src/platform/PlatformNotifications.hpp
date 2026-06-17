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
    // Локальный баннер входящего вызова (#6, iOS-путь; на Android ведёт фон-сервис сам).
    void showIncomingCall(const QString &callId);
    // Очистка всех ранее показанных уведомлений о новых сообщениях. Вызывается,
    // когда приложение выходит в foreground — даже если открыто не по тапу
    // уведомления, накопленные карточки в шторке должны исчезнуть.
    void clearAccumulatedNotifications();
    NotificationTarget takeOpenTargetFromNotification();
    QString takeOpenPeerFromNotification();
    // Handoff входящего звонка из фона (#6): сохранить расшифрованный конверт оффера
    // (iOS — in-process, в NSUserDefaults; Android сохраняет сам сервис) и забрать
    // его при открытии приложения, чтобы скормить в CallSignaling.injectEnvelope.
    void storePendingCallOffer(const QString &envelopeJson);
    QString takePendingCallOffer();
    // true, если приложение открыто нажатием «Ответить» в баннере вызова (а не
    // тапом по телу/иконке) — тогда после загрузки сессии звонок принимается
    // автоматически, без второго тапа на экране вызова. Зовётся один раз вместе
    // с takePendingCallOffer. На платформах без баннера-действия — false.
    bool takePendingCallAnswerIntent();
    // Координация опроса звонков между in-app сигналингом и фон-сервисом: пока
    // UI сам опрашивает звонки (foreground/активный звонок), он шлёт heartbeat —
    // фон-сервис в это время НЕ трогает call_poll (drain-эндпоинт, один читатель).
    // clear — отдать опрос фон-сервису немедленно (уход в фон без звонка).
    void heartbeatUiCallPolling();
    void clearUiCallPolling();
    // Гонка перехода в фон: in-app сигналинг сдрейнил оффер из long-poll'а уже
    // после ухода в фон. Отдаём конверт фон-сервису — он покажет баннер тем же
    // путём (тап → handoff). Без этого оффер показался бы невидимым экраном.
    void handoffIncomingCallToService(const QString &envelopeJson);
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
