#pragma once

#include <QJsonObject>
#include <QMap>
#include <QMutex>
#include <QObject>
#include <QSet>
#include <QString>
#include <QThread>
#include <atomic>

class ParanoiaFFI;

namespace paranoia::voip
{

    /// Long-poll цикл забора входящих сигнальных конвертов (`paranoia_call_poll`).
    ///
    /// Живёт в отдельном `QThread`, периодически вызывает FFI с long-poll'ом до
    /// 25 c. На каждое сообщение эмитит соответствующий сигнал. Конверты с
    /// нераспознанным `kind` или нерасшифрованным payload'ом FFI сама дропает —
    /// сюда они не доходят.
    ///
    /// Использование:
    ///   client.setHandle(handle);
    ///   client.setUser("alice");
    ///   client.setPeerKeyring({{"bob", "base64-master-key"}});
    ///   client.start();
    ///   // ... connect signals
    ///   client.stop();
    class CallSignalingClient : public QObject
    {
        Q_OBJECT
        Q_PROPERTY(QString user READ user WRITE setUser NOTIFY userChanged)
        Q_PROPERTY(bool running READ running NOTIFY runningChanged)
    public:
        explicit CallSignalingClient(QObject *parent = nullptr);
        ~CallSignalingClient() override;

        /// `handle` — указатель на `ParanoiaHandle` (как у MainBackend/ChatBackend).
        /// Должен оставаться валидным на всё время жизни сигнал-клиента.
        void setHandle(std::shared_ptr<ParanoiaFFI> handle);

        QString user() const;
        void setUser(const QString &u);

        bool running() const { return running_.load(); }

        /// Кольцо ключей `peer → master_key_b64` для расшифровки входящих
        /// конвертов. Безопасно дёргать в любой момент — клиент перечитает на
        /// следующей итерации.
        Q_INVOKABLE void setPeerKeyring(const QVariantMap &peerToMasterKeyB64);

        /// Вернуть master_key (base64) для конкретного peer'а, если он есть в
        /// keyring'е, иначе пустую строку. Безопасно из любого потока.
        Q_INVOKABLE QString masterKeyFor(const QString &peer) const;

        Q_INVOKABLE bool start();
        Q_INVOKABLE void stop();

        /// Был ли по этому call_id недавно Hangup. Нужно, чтобы НЕ инжектить
        /// отложенный оффер уже отменённого звонка (гонка: на входе в приложение
        /// hangup мог прийти раньше, чем мы инжектим сохранённый оффер).
        bool wasRecentlyHungUp(const QString &callId) const;

        /// Включить/выключить ОПРОС новых офферов. Выключаем, когда приложение в
        /// фоне и нет активного звонка — тогда входящие ловит фон-сервис (иначе
        /// два поллера дерутся за drain-эндпоинт, и foreground-клиент «съедал»
        /// оффер, показывая невидимый экран вместо баннера). Поток НЕ
        /// останавливаем — просто пропускаем call_poll до повторного включения.
        /// Безопасно из любого потока.
        void setOfferPollingEnabled(bool enabled) { offerPollingEnabled_.store(enabled); }

        /// Скормить УЖЕ расшифрованный конверт `{sender,kind,payload_json,ts_ms}`
        /// в штатный путь (как будто пришёл из poll'а) — для handoff входящего
        /// звонка из фонового сервиса: сервер `drain`-ит оффер, поэтому foreground
        /// повторным poll'ом его не получит, и его передаём напрямую. (#6)
        Q_INVOKABLE void injectEnvelope(const QString &envelopeJson);

    signals:
        void userChanged();
        void runningChanged();
        void offerReceived(const QString &fromPeer, const QString &callId, const QString &sessionIdB64,
                           const QStringList &candidates, bool peerWantsVideo, qint64 createdTsMs);
        void answerReceived(const QString &fromPeer, const QString &callId, bool accept, const QStringList &candidates,
                            bool peerWantsVideo, const QString &reason);
        void hangupReceived(const QString &fromPeer, const QString &callId, const QString &reason);
        void iceReceived(const QString &fromPeer, const QString &callId, const QString &candidate);
        void pollFailed(const QString &message);

    private:
        struct PollSnapshot {
            std::shared_ptr<ParanoiaFFI> handle;
            QString user;
            quint64 generation = 0;
        };

        void workerLoop();
        void dispatch(const QJsonObject &envelope);
        void rememberHangup(const QString &callId);
        QByteArray buildPeersKeysJson() const;
        PollSnapshot pollSnapshot() const;
        bool isCurrentGeneration(quint64 generation) const;

        QThread thread_;
        mutable QMutex state_mutex_;
        QString user_;
        std::shared_ptr<ParanoiaFFI> handle_ = nullptr;
        quint64 config_generation_           = 0;
        QMap<QString, QString> peer_keys_; // защищён mutex'ом в реализации
        mutable QMutex keys_mutex_;
        std::atomic<bool> running_{false};
        std::atomic<bool> stop_{false};
        // true по умолчанию (foreground при старте); VoipSystem гасит в фоне без
        // активного звонка, чтобы не конкурировать с фон-сервисом за офферы.
        std::atomic<bool> offerPollingEnabled_{true};
        // call_id'ы, по которым видели Hangup — чтобы не инжектить отменённый оффер.
        QSet<QString> recent_hangups_;
        mutable QMutex hangups_mutex_;
    };

} // namespace paranoia::voip
