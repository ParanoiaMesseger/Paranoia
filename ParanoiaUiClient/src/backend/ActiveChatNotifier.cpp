#include "ActiveChatNotifier.hpp"

#include <QDebug>
#include <QMutexLocker>
#include <QVariant>

#include <ParanoiaFFI>

namespace
{
    // Потолок long-poll'а (сервер капает своим лимитом, ~25 c).
    constexpr uint32_t kLongPollMs = 25000;
    // Пауза после ошибки — не долбим сервер.
    constexpr int kBackoffMs = 2000;
    // Дебаунс после положительного результата: notify_count вернёт >0, пока
    // fetchMessages не вычерпал очередь → без паузы это был бы хот-луп.
    constexpr int kHitDebounceMs = 500;
} // namespace

ActiveChatNotifier::ActiveChatNotifier(QObject *parent) : QObject(parent) { moveToThread(&thread_); }

ActiveChatNotifier::~ActiveChatNotifier() { stop(); }

void ActiveChatNotifier::configure(std::shared_ptr<ParanoiaFFI> handle, const QString &serverId,
                                   const QString &peerId, const QString &keyringJson)
{
    QMutexLocker lock(&mutex_);
    handle_      = std::move(handle);
    serverId_    = serverId;
    peerId_      = peerId;
    keyringJson_ = keyringJson;
    ++generation_;
}

ActiveChatNotifier::Snapshot ActiveChatNotifier::snapshot() const
{
    QMutexLocker lock(&mutex_);
    return {handle_, serverId_, peerId_, keyringJson_, generation_};
}

bool ActiveChatNotifier::isCurrentGeneration(quint64 generation) const
{
    QMutexLocker lock(&mutex_);
    return generation_ == generation;
}

void ActiveChatNotifier::start()
{
    if (running_.exchange(true)) return; // уже крутится
    stop_.store(false);
    if (!thread_.isRunning()) thread_.start();
    QMetaObject::invokeMethod(this, [this] { workerLoop(); }, Qt::QueuedConnection);
}

void ActiveChatNotifier::stop()
{
    if (!running_.load()) return;
    stop_.store(true);
    thread_.quit();
    thread_.wait(3000); // висящий long-poll может не прерваться сразу — как в CallSignalingClient.
    running_.store(false);
}

void ActiveChatNotifier::workerLoop()
{
    while (!stop_.load()) {
        const auto s = snapshot();
        if (!s.handle || s.peerId.isEmpty() || s.keyringJson.isEmpty()) {
            QThread::msleep(kBackoffMs);
            continue;
        }
        uint64_t count = 0;
        // БЕЗ ffiMutex — long-poll держит ответ до ~25 c; общий мьютекс заморозил бы UI.
        const int rc = s.handle->notify_count_wait_keyring(s.serverId, s.peerId, s.keyringJson, kLongPollMs, count);
        if (stop_.load()) break;
        if (!isCurrentGeneration(s.generation)) continue; // цель сменилась — результат не наш
        if (rc != 0) {
            QThread::msleep(kBackoffMs);
            continue;
        }
        if (count > 0) {
            emit messagesWaiting();
            QThread::msleep(kHitDebounceMs);
        }
    }
}
