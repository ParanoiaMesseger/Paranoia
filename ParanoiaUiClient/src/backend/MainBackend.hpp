#pragma once
#include <QObject>
#include <QVariantList>
#include <QStringList>
#include <QUrl>

class NotificationCoordinator;
class ServerSession;

class MainBackend : public QObject
{
    Q_OBJECT

    Q_PROPERTY(bool loggedIn READ isLoggedIn NOTIFY loginStateChanged)
    Q_PROPERTY(QString username READ username NOTIFY loginStateChanged)
    Q_PROPERTY(QString server READ server NOTIFY loginStateChanged)
    Q_PROPERTY(bool hasAdminAccess READ hasAdminAccess NOTIFY adminStateChanged)
    Q_PROPERTY(QString devicePubkey READ devicePubkey NOTIFY deviceKeyChanged)
    Q_PROPERTY(QString activeProfileId READ activeProfileId NOTIFY loginStateChanged)
    Q_PROPERTY(bool hasStoredClientProfiles READ hasStoredClientProfiles NOTIFY storedClientProfilesChanged)
    /// 0=not_initialized (нужен SetPin), 1=locked (нужен UnlockPin), 2=unlocked (норма), -1=ошибка.
    Q_PROPERTY(int vaultStatus READ vaultStatus NOTIFY vaultStatusChanged)

public:
    explicit MainBackend(NotificationCoordinator &notifications, QObject *parent = nullptr);
    ~MainBackend() override;

    bool isLoggedIn() const;
    QString username() const;
    QString server() const;
    bool hasAdminAccess() const;
    QString devicePubkey() const;
    QString activeProfileId() const;
    bool hasStoredClientProfiles() const;
    int vaultStatus() const;

    Q_INVOKABLE void vaultSetPin(const QString &pin);
    Q_INVOKABLE void vaultUnlock(const QString &pin);
    Q_INVOKABLE void vaultLock();
    Q_INVOKABLE quint64 vaultLockoutSeconds() const;
    /// Сменить PIN с полной перешифровкой всех vault-protected JSON-файлов и БД.
    /// Async. Результат через vaultChangePinResult(int):
    ///   0=ok, 1=wrong_old_pin, -1=internal (см. paranoia_last_error).
    Q_INVOKABLE void vaultChangePin(const QString &oldPin, const QString &newPin);

    Q_INVOKABLE void generateKeyPair();
    Q_INVOKABLE void loginClient(const QString &server, const QString &reserveServer, const QString &username,
                                 const QString &private_key);
    Q_INVOKABLE void activateProfile(const QString &profileId);
    Q_INVOKABLE void registerUser(const QString &domain, const QString &pubkey);
    Q_INVOKABLE QVariantList getReserveDomains(const QString &targetType, const QString &targetId,
                                               const QString &primaryDomain) const;
    Q_INVOKABLE void addAdminReserveDomain(const QString &primaryDomain, const QString &reserveDomain);
    Q_INVOKABLE void addClientReserveDomain(const QString &profileId, const QString &reserveDomain);
    Q_INVOKABLE void removeAdminReserveDomain(const QString &primaryDomain, const QString &reserveDomain);
    Q_INVOKABLE void removeClientReserveDomain(const QString &profileId, const QString &reserveDomain);
    Q_INVOKABLE void checkReserveDomain(const QString &targetType, const QString &targetId,
                                        const QString &primaryDomain, const QString &reserveDomain);

    /// Список резервных TURN-серверов профиля. Возвращает строки вида
    /// "host:port" / "host" в порядке хранения. Первичный TURN не входит —
    /// он выводится из URL активной сессии в VoipSystem.
    Q_INVOKABLE QStringList getTurnServers(const QString &profileId) const;
    /// Добавить TURN-сервер в список профиля. Валидирует формат и
    /// дедуплицирует. На успех эмитит turnServerAdded(profileId, url).
    Q_INVOKABLE void addTurnServer(const QString &profileId, const QString &turnUrl);
    /// Удалить TURN из списка профиля.
    Q_INVOKABLE void removeTurnServer(const QString &profileId, const QString &turnUrl);
    /// Проверить достижимость TURN-сервера (попытка allocate через session-сокет
    /// активной сессии). Асинхронно; результат через turnServerCheckFinished.
    Q_INVOKABLE void checkTurnServer(const QString &profileId, const QString &turnUrl);

    Q_INVOKABLE QVariantMap createDialogKeyInvitation(const QString &peer) const;
    Q_INVOKABLE QVariantMap createDialogKeyResponse(const QString &invitationPayloadJson);
    Q_INVOKABLE QVariantMap dialogKeyFingerprint(const QString &localStateJson, const QString &peerPayloadJson);
    Q_INVOKABLE QVariantMap confirmDialogKeyExchange(const QString &peer, const QString &localStateJson,
                                                     const QString &peerPayloadJson, const QString &fingerprint,
                                                     bool updateExisting);
    Q_INVOKABLE void removeDialog(const QString &peer);
    Q_INVOKABLE QVariantList getDialogs() const;
    Q_INVOKABLE QVariantList getAdminServers() const;

    // ── Корпоративный API: синхронизация связки сотрудника ──────────────────
    /// Конфиг Корп-API активного профиля: {url, psk}.
    Q_INVOKABLE QVariantMap corporateConfig() const;
    /// Сохранить URL Корп-API и PSK для активного профиля.
    Q_INVOKABLE void setCorporateApi(const QString &url, const QString &psk);
    /// Подтянуть связку (ключи диалогов с коллегами) по Корп-API и применить.
    Q_INVOKABLE void syncCorporateKeyring();

    Q_INVOKABLE QVariantList getSessionList() const;
    Q_INVOKABLE void switchSession(const QString &profileId);

    Q_INVOKABLE void deleteDialogLocal(const QString &peer);
    /// Очистить диалог: удалить всю историю и на сервере, и локально, оставив
    /// сам диалог и его ключи (можно продолжать общение).
    Q_INVOKABLE void clearDialogHistory(const QString &peer);

    Q_INVOKABLE QVariantMap exportProfile(const QString &profileType, const QStringList &peers,
                                          const QString &receiverPubkeyB64, const QString &filePath);
    Q_INVOKABLE QVariantMap importProfile(const QString &filePath);
    Q_INVOKABLE QVariantMap deleteExportFile(const QString &filePath);

    /// Конвертировать QML-овский url (например, FileDialog.selectedFile) в
    /// локальный путь файловой системы. На Windows file:///C:/x → C:/x,
    /// на POSIX file:///x → /x. Принимает как QUrl, так и строку (Qt сам
    /// проведёт конверсию через QUrl).
    Q_INVOKABLE QString urlToLocalPath(const QUrl &url) const;

    // Возвращает «pending share» от системного share-sheet'а. На текущий момент
    // реализовано на Android (см. AndroidManifest intent-filter ACTION_SEND);
    // на других ОС вернёт пустую карту. Карта:
    //   { "text": "...", "files": [uri, uri, ...] }
    // После вызова данные у платформы очищаются (одна попытка применить).
    Q_INVOKABLE QVariantMap takeShareTarget();

    // Singleton-accessor для JNI bridge'а (см.
    // Java_app_paranoia_client_ParanoiaActivity_nativeShareTargetReady).
    // Java вызывает после storeShareTarget, чтобы QML гарантированно
    // подобрал share-данные, даже если onActiveChanged не сработал
    // (был уже foreground).
    static MainBackend *instance() { return s_instance; }

public slots:
    /// Пересобрать polling-snapshot для notifications-сервиса.
    /// Берёт минимум данных: signing key, server_id, peer server_id,
    /// last_pulled_seq. Подключён к dialogsChanged/sessionsChanged
    /// MainBackend'а + ChatBackend::pulledNewMessages.
    void publishServiceSnapshot();

signals:
    // Эмитится из JNI bridge'а после того, как Java сохранил share-target
    // в shared prefs. QML слушает и зовёт takeShareTarget() заново.
    void shareTargetReady();
    void keyPairGenerated(const QString &pubkey, const QString &private_key);
    void loginStateChanged();
    void deviceKeyChanged();
    void adminStateChanged();
    void loginError(const QString &msg);
    void userRegistered();
    void registerUserError(const QString &msg);
    void reserveDomainAdded(const QString &targetType, const QString &targetId, const QString &reserveDomain);
    void reserveDomainRemoved(const QString &targetType, const QString &targetId, const QString &reserveDomain);
    void reserveDomainCheckFinished(const QString &targetType, const QString &targetId, const QString &reserveDomain,
                                    bool ok, const QString &msg, qint64 pingMs);
    void reserveDomainError(const QString &msg);
    void turnServerAdded(const QString &profileId, const QString &turnUrl);
    void turnServerRemoved(const QString &profileId, const QString &turnUrl);
    void turnServerCheckFinished(const QString &profileId, const QString &turnUrl, bool ok, const QString &msg,
                                 qint64 pingMs);
    void turnServerError(const QString &msg);
    void dialogsChanged();
    void dialogDeleted(const QString &peer);
    void serverHistoryCleared(const QString &peer);
    void serverHistoryError(const QString &msg);
    // Cross-backend coordination
    void dialogRemoved(const QString &peer);
    void sessionReset();
    void sessionsChanged();
    void sessionSwitched();
    void storedClientProfilesChanged();
    void vaultStatusChanged();
    void vaultUnlocked();
    void vaultLocked();
    /// Эмитится из vaultUnlock() async-задачи на UI-потоке.
    /// result: 0=ok, 1=wrong_pin, 2=locked_out, 3=not_initialized, -1=internal.
    void vaultUnlockResult(int result);
    void vaultSetPinResult(int result);
    void vaultChangePinResult(int result);
    void corporateConfigChanged();
    /// Результат синхронизации связки по Корп-API. ok, число обновлённых
    /// диалогов, сообщение.
    void corporateSyncFinished(bool ok, int updated, const QString &message);

private:
    static MainBackend *s_instance;
    NotificationCoordinator *m_notifications = nullptr;
    class QNetworkAccessManager *m_net = nullptr; // ленивая инициализация для Корп-API
    QString m_devicePrivkey;
    bool m_hasStoredClientProfiles = false;
    void setHasStoredClientProfiles(bool hasProfiles);
    void loginClientInternal(const QString &server, const QString &username, const QString &private_key,
                             const QStringList &reserveServerUrls, bool makeActive,
                             bool rotateRegistrationKeyOnSuccess = false);
    void rotateRegistrationKeyPair(const QString &previousPrivateKey = {});
    void loadClientConfig();
    void saveDeviceKey() const;
    void loadDeviceKey();
    void upsertDialogKeyringEntry(const QString &peer, const QString &peerServerId, const QByteArray &sessionKey,
                                  quint64 startSeq, bool resetKeyring);
    /// Применить расшифрованный JSON связки (roster+keyring) к активной сессии.
    /// Вызывать на главном потоке.
    void applyCorporateKeyring(const QString &keyringJson);

    // ── Local Vault lifecycle ────────────────────────────────────────────
    void initVault();
    void onVaultUnlocked();
    /// Тело смены PIN. Вызывается отложенно из vaultChangePin() через
    /// QueuedConnection — чтобы UI успел отрисовать busy-overlay перед
    /// тем, как начнётся session teardown и Argon2.
    void doVaultChangePinAsync(const QString &oldPin, const QString &newPin);
};
