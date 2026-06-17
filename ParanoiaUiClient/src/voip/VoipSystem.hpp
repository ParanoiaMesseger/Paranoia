#pragma once

#include "CallController.hpp"
#include "CallEngine.hpp"
#include "CallSignalingClient.hpp"

#include <QObject>
#include <QString>
#include <QTimer>

class MainBackend;
class QQmlApplicationEngine;

namespace paranoia::voip
{

    class VoipSystem : public QObject
    {
        Q_OBJECT
    public:
        VoipSystem(QQmlApplicationEngine &engine, MainBackend &backend, QObject *parent = nullptr);

    private slots:
        void refreshBindings();

    private:
        // Handoff входящего звонка из фона (#6): забрать отложенный конверт оффера
        // и скормить в callSignaling_ (no-op, если ничего не отложено).
        void maybeInjectPendingCallOffer();
        // Пересчитать, должен ли in-app сигналинг опрашивать офферы (active||call),
        // и синхронизировать heartbeat-флаг для фон-сервиса.
        void updateOfferPolling();
        QString deriveStunForServer(const QString &serverUrl) const;
        QString deriveTurnForServer(const QString &serverUrl) const;

        MainBackend &backend_;
        CallEngine callEngine_;
        CallSignalingClient callSignaling_;
        CallController callController_;
        // Отложенный оффер из фона: держим, пока keyring активной сессии не
        // подгрузит master key отправителя (cold start из баннера — dialogs
        // грузятся асинхронно). Иначе инжектили с пустым ключом = звонок без
        // шифрования + экран с hex'ом вместо имени.
        QString pendingCallOffer_;
        // Координация опроса звонков с фон-сервисом (см. updateOfferPolling).
        bool appActive_  = false;
        bool callActive_ = false;
        QTimer uiCallHeartbeat_;
        // «Ответить» нажато в баннере → принять авто-приёмом, как только оффер
        // инжектнётся и придёт incomingCall (без второго тапа на экране вызова).
        bool pendingCallAnswer_ = false;
        QString stunExplicit_;
        QString turnExplicit_;
        bool stunDisabled_ = false;
        bool turnDisabled_ = false;
    };

} // namespace paranoia::voip
