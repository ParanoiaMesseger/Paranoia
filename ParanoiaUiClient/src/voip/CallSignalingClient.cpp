#include "CallSignalingClient.hpp"

#include <QCoreApplication>
#include <QDebug>
#include <QJsonDocument>
#include <QJsonParseError>
#include <QJsonArray>
#include <QJsonValue>
#include <QMutexLocker>
#include <QVariant>

#include <ParanoiaFFI>

namespace paranoia::voip
{

    namespace
    {

        constexpr uint32_t kLongPollMs = 25000;
        constexpr int kBackoffMs       = 1500;

        // Ключи payload'ов — соответствуют структурам из voip::signaling в Rust.
        QStringList readCandidates(const QJsonValue &v)
        {
            QStringList out;
            if (!v.isArray()) return out;
            for (const auto &it : v.toArray()) {
                if (it.isString()) out.push_back(it.toString());
            }
            return out;
        }

        bool streamsContainVideo(const QJsonValue &v)
        {
            if (!v.isArray()) return false;
            for (const auto &it : v.toArray()) {
                // Видео = stream id 1 (см. voip::crypto::StreamId).
                if (it.toInt(-1) == 1) return true;
            }
            return false;
        }

        QString logId(const QString &value)
        {
            if (value.isEmpty()) return QStringLiteral("<empty>");
            return value.size() <= 12 ? value : value.left(8) + QStringLiteral("...");
        }

    } // namespace

    CallSignalingClient::CallSignalingClient(QObject *parent) : QObject(parent) { moveToThread(&thread_); }

    CallSignalingClient::~CallSignalingClient() { stop(); }

    void CallSignalingClient::setHandle(std::shared_ptr<ParanoiaFFI> handle)
    {
        QMutexLocker lock(&state_mutex_);
        if (handle_ == handle) return;
        handle_ = handle;
        ++config_generation_;
    }

    QString CallSignalingClient::user() const
    {
        QMutexLocker lock(&state_mutex_);
        return user_;
    }

    void CallSignalingClient::setUser(const QString &u)
    {
        {
            QMutexLocker lock(&state_mutex_);
            if (user_ == u) return;
            user_ = u;
            ++config_generation_;
        }
        emit userChanged();
    }

    void CallSignalingClient::setPeerKeyring(const QVariantMap &peerToMasterKeyB64)
    {
        QMutexLocker lock(&keys_mutex_);
        peer_keys_.clear();
        for (auto it = peerToMasterKeyB64.constBegin(); it != peerToMasterKeyB64.constEnd(); ++it) {
            peer_keys_.insert(it.key(), it.value().toString());
        }
    }

    QString CallSignalingClient::masterKeyFor(const QString &peer) const
    {
        QMutexLocker lock(&keys_mutex_);
        return peer_keys_.value(peer);
    }

    QByteArray CallSignalingClient::buildPeersKeysJson() const
    {
        QMutexLocker lock(&keys_mutex_);
        QJsonArray arr;
        for (auto it = peer_keys_.constBegin(); it != peer_keys_.constEnd(); ++it) {
            QJsonObject obj;
            obj.insert(QStringLiteral("peer"), it.key());
            obj.insert(QStringLiteral("master_key_b64"), it.value());
            arr.push_back(obj);
        }
        return QJsonDocument(arr).toJson(QJsonDocument::Compact);
    }

    CallSignalingClient::PollSnapshot CallSignalingClient::pollSnapshot() const
    {
        QMutexLocker lock(&state_mutex_);
        return {handle_, user_, config_generation_};
    }

    bool CallSignalingClient::isCurrentGeneration(quint64 generation) const
    {
        QMutexLocker lock(&state_mutex_);
        return config_generation_ == generation;
    }

    bool CallSignalingClient::start()
    {
        if (running_.load()) return true;
        const auto snapshot = pollSnapshot();
        if (!snapshot.handle || snapshot.user.isEmpty()) {
            emit pollFailed(QStringLiteral("CallSignalingClient: handle or user not set"));
            return false;
        }
        int peerKeyCount = 0;
        {
            QMutexLocker lock(&keys_mutex_);
            peerKeyCount = peer_keys_.size();
        }
        qInfo().noquote() << "CallSignalingClient: start polling user" << logId(snapshot.user) << "peer keys"
                          << peerKeyCount;
        stop_.store(false);
        running_.store(true);
        emit runningChanged();
        if (!thread_.isRunning()) { thread_.start(); }
        QMetaObject::invokeMethod(this, [this] { workerLoop(); }, Qt::QueuedConnection);
        return true;
    }

    void CallSignalingClient::stop()
    {
        if (!running_.load()) return;
        stop_.store(true);
        thread_.quit();
        thread_.wait(3000);
        running_.store(false);
        emit runningChanged();
    }

    void CallSignalingClient::workerLoop()
    {
        while (!stop_.load()) {
            const auto snapshot = pollSnapshot();
            if (!snapshot.handle || snapshot.user.isEmpty()) {
                emit pollFailed(QStringLiteral("CallSignalingClient: handle or user not set"));
                QThread::msleep(kBackoffMs);
                continue;
            }

            auto json = snapshot.handle->callPoll(snapshot.user, buildPeersKeysJson(), kLongPollMs);
            if (stop_.load()) break;
            if (!isCurrentGeneration(snapshot.generation)) continue;

            if (json.isEmpty()) {
                const QString msg = ParanoiaFFI::last_error();
                qWarning().noquote() << "CallSignalingClient: poll failed:" << msg;
                emit pollFailed(msg);
                QThread::msleep(kBackoffMs); // Backoff, чтобы не долбить сервер при ошибках.
                continue;
            }
            QJsonParseError perr{};
            const auto doc = QJsonDocument::fromJson(json.toUtf8(), &perr);
            if (perr.error != QJsonParseError::NoError || !doc.isArray()) {
                const QString msg = QStringLiteral("poll parse: %1").arg(perr.errorString());
                qWarning().noquote() << "CallSignalingClient:" << msg;
                emit pollFailed(msg);
                QThread::msleep(kBackoffMs);
                continue;
            }
            if (!isCurrentGeneration(snapshot.generation)) continue;
            if (!doc.array().isEmpty())
                qInfo().noquote() << "CallSignalingClient: polled" << doc.array().size() << "signal(s) for"
                                  << logId(snapshot.user);
            for (const auto &v : doc.array())
                if (v.isObject() && isCurrentGeneration(snapshot.generation)) dispatch(v.toObject());
        }
    }

    void CallSignalingClient::dispatch(const QJsonObject &env)
    {
        const QString sender     = env.value(QStringLiteral("sender")).toString();
        const int kind           = env.value(QStringLiteral("kind")).toInt(-1);
        const qint64 ts          = env.value(QStringLiteral("ts_ms")).toVariant().toLongLong();
        const QString payloadStr = env.value(QStringLiteral("payload_json")).toString();
        if (sender.isEmpty() || kind < 0 || payloadStr.isEmpty()) return;

        QJsonParseError perr{};
        const auto doc = QJsonDocument::fromJson(payloadStr.toUtf8(), &perr);
        if (perr.error != QJsonParseError::NoError || !doc.isObject()) return;
        const auto payload   = doc.object();
        const QString callId = payload.value(QStringLiteral("call_id")).toString();
        const QString reason = payload.value(QStringLiteral("reason")).toString();
        qInfo().noquote() << "CallSignalingClient: dispatch kind" << kind << "from" << logId(sender) << "call"
                          << logId(callId) << "reason" << (reason.isEmpty() ? QStringLiteral("<empty>") : reason);

        switch (kind) {
            case 0: // Offer
                // session_id приходит base64-строкой (см. base64_session_id в Rust).
                emit offerReceived(sender, callId, payload.value(QStringLiteral("session_id")).toString(),
                                   readCandidates(payload.value(QStringLiteral("candidates"))),
                                   streamsContainVideo(payload.value(QStringLiteral("streams"))),
                                   payload.value(QStringLiteral("created_ts_ms")).toVariant().toLongLong());
                break;
            case 1: // Answer
                emit answerReceived(sender, callId, payload.value(QStringLiteral("accept")).toBool(false),
                                    readCandidates(payload.value(QStringLiteral("candidates"))),
                                    streamsContainVideo(payload.value(QStringLiteral("streams"))), reason);
                break;
            case 2: // Hangup
                emit hangupReceived(sender, callId, reason);
                break;
            case 3: // Ice
                emit iceReceived(sender, callId, payload.value(QStringLiteral("candidate")).toString());
                break;
            default: break;
        }
        Q_UNUSED(ts);
    }

} // namespace paranoia::voip
