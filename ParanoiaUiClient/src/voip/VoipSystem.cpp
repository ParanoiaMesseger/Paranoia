#include "VoipSystem.hpp"

#include "backend/MainBackend.hpp"
#include "session/Dialog.hpp"
#include "session/ServerSession.hpp"
#include "session/SessionStore.hpp"

#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QDebug>
#include <QUrl>
#include <QVariantMap>

namespace paranoia::voip
{
    namespace
    {
        constexpr int kParanoiaStunPort = 3478;
    }

    VoipSystem::VoipSystem(QQmlApplicationEngine &engine, MainBackend &backend, QObject *parent)
        : QObject(parent), backend_(backend)
    {
        callController_.setEngine(&callEngine_);
        callController_.setSignaling(&callSignaling_);

        connect(&callEngine_, &CallEngine::errorOccurred, this,
                [](const QString &message) { qWarning().noquote() << "CallEngine:" << message; });
        connect(&callController_, &CallController::controllerError, this,
                [](const QString &message) { qWarning().noquote() << "CallControl:" << message; });
        connect(&callSignaling_, &CallSignalingClient::pollFailed, this,
                [](const QString &message) { qWarning().noquote() << "CallSignaling:" << message; });

        // STUN-server for reflexive candidates. Priority:
        // 1. env `PARANOIA_STUN_SERVER` (`disable|off|none` disables STUN);
        // 2. build define `PARANOIA_DEFAULT_STUN_SERVER`;
        // 3. active session host + default port 3478;
        // 4. public fallback `stun.l.google.com:19302`.
        stunExplicit_ = QString::fromUtf8(qgetenv("PARANOIA_STUN_SERVER"));
        if (stunExplicit_.isEmpty()) { stunExplicit_ = QString::fromUtf8(PARANOIA_DEFAULT_STUN_SERVER); }
        const QString lower = stunExplicit_.trimmed().toLower();
        if (lower == QStringLiteral("disable") || lower == QStringLiteral("off") ||
            lower == QStringLiteral("none")) {
            stunDisabled_ = true;
            stunExplicit_.clear();
        }

        // TURN relay fallback. Priority:
        // 1. env `PARANOIA_TURN_SERVER` (`disable|off|none` disables TURN);
        // 2. active session host + default port 3478.
        turnExplicit_ = QString::fromUtf8(qgetenv("PARANOIA_TURN_SERVER"));
        const QString turnLower = turnExplicit_.trimmed().toLower();
        if (turnLower == QStringLiteral("disable") || turnLower == QStringLiteral("off") ||
            turnLower == QStringLiteral("none")) {
            turnDisabled_ = true;
            turnExplicit_.clear();
        }

        const QString initial = deriveStunForServer(QString());
        callController_.setStunServer(initial);
        callController_.setTurnServer(deriveTurnForServer(QString()));
        if (initial.isEmpty()) {
            qInfo().noquote() << "VoIP: STUN disabled - calls work only in local network";
        } else {
            qInfo().noquote() << "VoIP: initial STUN server" << initial;
        }

        engine.rootContext()->setContextProperty("Call", &callEngine_);
        engine.rootContext()->setContextProperty("CallSignaling", &callSignaling_);
        engine.rootContext()->setContextProperty("CallControl", &callController_);

        connect(&backend_, &MainBackend::sessionsChanged, this, &VoipSystem::refreshBindings);
        connect(&backend_, &MainBackend::sessionSwitched, this, &VoipSystem::refreshBindings);
        connect(&backend_, &MainBackend::dialogsChanged, this, &VoipSystem::refreshBindings);
        refreshBindings();
    }

    QString VoipSystem::deriveStunForServer(const QString &serverUrl) const
    {
        if (stunDisabled_) return {};
        if (!stunExplicit_.isEmpty()) return stunExplicit_;
        if (!serverUrl.isEmpty()) {
            QUrl url(serverUrl);
            QString host = url.host();
            if (host.isEmpty()) {
                QString server = serverUrl;
                if (server.startsWith(QStringLiteral("//"))) server.remove(0, 2);
                const int slash = server.indexOf(QLatin1Char('/'));
                if (slash >= 0) server = server.left(slash);
                const int colon = server.indexOf(QLatin1Char(':'));
                if (colon >= 0) server = server.left(colon);
                host = server.trimmed();
            }
            if (!host.isEmpty()) { return QStringLiteral("%1:%2").arg(host).arg(kParanoiaStunPort); }
        }
        return QStringLiteral("stun.l.google.com:19302");
    }

    QString VoipSystem::deriveTurnForServer(const QString &serverUrl) const
    {
        if (turnDisabled_) return {};
        if (!turnExplicit_.isEmpty()) return turnExplicit_;
        if (!serverUrl.isEmpty()) {
            QUrl url(serverUrl);
            QString host = url.host();
            if (host.isEmpty()) {
                QString server = serverUrl;
                if (server.startsWith(QStringLiteral("//"))) server.remove(0, 2);
                const int slash = server.indexOf(QLatin1Char('/'));
                if (slash >= 0) server = server.left(slash);
                const int colon = server.indexOf(QLatin1Char(':'));
                if (colon >= 0) server = server.left(colon);
                host = server.trimmed();
            }
            if (!host.isEmpty()) { return QStringLiteral("%1:%2").arg(host).arg(kParanoiaStunPort); }
        }
        return {};
    }

    void VoipSystem::refreshBindings()
    {
        auto active = SessionStore::instance()->activeSession();
        if (!active || !active->ffi) {
            callSignaling_.stop();
            callController_.setHandle(nullptr);
            callController_.setPeerUserIds({});
            callSignaling_.setPeerKeyring({});
            callController_.setStunServer(deriveStunForServer(QString()));
            callController_.setTurnServer(deriveTurnForServer(QString()));
            return;
        }

        const QString selfUserId = active->serverId.isEmpty() ? active->username : active->serverId;
        callController_.setHandle(active->ffi);
        callController_.setSelfUsername(selfUserId);

        const QString stunForActive = deriveStunForServer(active->server);
        callController_.setStunServer(stunForActive);
        if (!stunForActive.isEmpty()) { qInfo().noquote() << "VoIP: STUN server for active session" << stunForActive; }
        const QString turnForActive = deriveTurnForServer(active->server);
        callController_.setTurnServer(turnForActive);
        if (!turnForActive.isEmpty()) { qInfo().noquote() << "VoIP: TURN server for active session" << turnForActive; }

        callSignaling_.setHandle(active->ffi);
        callSignaling_.setUser(selfUserId);

        QVariantMap keyring;
        QVariantMap peerUserIds;
        for (const auto &dialog : active->dialogs) {
            if (dialog.keyring.isEmpty()) continue;
            const auto &entry        = dialog.keyring.last();
            const QString keyB64     = QString::fromUtf8(entry.key.toBase64());
            const QString peerUserId = dialog.peerServerId.isEmpty() ? dialog.peer : dialog.peerServerId;
            keyring.insert(dialog.peer, keyB64);
            if (!peerUserId.isEmpty()) {
                keyring.insert(peerUserId, keyB64);
                peerUserIds.insert(dialog.peer, peerUserId);
            }
        }
        callController_.setPeerUserIds(peerUserIds);
        callSignaling_.setPeerKeyring(keyring);
        callSignaling_.start();
    }

} // namespace paranoia::voip
