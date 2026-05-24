#pragma once

#include "CallController.hpp"
#include "CallEngine.hpp"
#include "CallSignalingClient.hpp"

#include <QObject>
#include <QString>

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
        QString deriveStunForServer(const QString &serverUrl) const;
        QString deriveTurnForServer(const QString &serverUrl) const;

        MainBackend &backend_;
        CallEngine callEngine_;
        CallSignalingClient callSignaling_;
        CallController callController_;
        QString stunExplicit_;
        QString turnExplicit_;
        bool stunDisabled_ = false;
        bool turnDisabled_ = false;
    };

} // namespace paranoia::voip
