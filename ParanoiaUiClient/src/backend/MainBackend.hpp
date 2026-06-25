#pragma once
#include <QObject>
#include <QVariantList>
#include <QVariantMap>
#include <QStringList>
#include <QJsonObject>
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
    /// Состояние сверки маскировки активного профиля для индикатора у сервера:
    /// "" (нет/не применимо), "checking", "verified" (сверено, без изменений),
    /// "updated" (изменилось и применено), "error".
    Q_PROPERTY(QString maskingState READ maskingState NOTIFY maskingStateChanged)
    Q_PROPERTY(QString maskingProfileName READ maskingProfileName NOTIFY maskingStateChanged)
    // Состояние связи с сервером для индикатора «Подключение»: "online" |
    // "connecting" (поллинг не достучался — нет сети/сервер недоступен).
    Q_PROPERTY(QString connectionState READ connectionState NOTIFY connectionStateChanged)

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
    QString maskingState() const { return m_maskingState; }
    QString maskingProfileName() const { return m_maskingProfileName; }
    QString connectionState() const { return m_connectionState; }
    /// Обновить состояние связи (зовётся из NotificationCoordinator по результату
    /// форграунд-поллинга). online → "online", иначе "connecting".
    void setConnectionOnline(bool online);

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
    /// Логин с метаданными подключения (тариф + параметры раздачи маскировки),
    /// которые приходят из «профиля подключения» (QR/файл параметров сервера).
    /// Используется при регистрации private/commercial; corporate идёт через
    /// importProfile (полный шифрованный бандл).
    Q_INVOKABLE void loginClientWithMeta(const QString &server, const QString &reserveServer,
                                         const QString &username, const QString &private_key,
                                         const QString &tariff, const QString &maskingUrl,
                                         const QString &maskingBearer, const QString &maskingTrustedPubkey);
    /// Разобрать «профиль подключения»: путь к файлу или текст QR (открытый JSON
    /// `paranoia.connect.v1`). Возвращает {ok, error, tariff, server,
    /// reserve_server_urls, masking_url, masking_trusted_pubkey}.
    Q_INVOKABLE QVariantMap parseConnectionBundle(const QString &pathOrText) const;
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
    /// Подтянуть связку (ключи диалогов с коллегами) по Корп-API и применить.
    /// Конфиг (url+psk) задаётся только импортом корпоративного бандла при
    /// регистрации (см. importProfile) — ручной настройки нет. Вызывается
    /// автоматически при входе/смене сессии (no-op без corp.json).
    Q_INVOKABLE void syncCorporateKeyring();

    // ── Корп-API: ленивая раздача ключей (ростер + пер-диалоговые ключи) ────
    /// Корпоративный ли активный профиль (есть corp.json с url+psk). UI решает,
    /// показывать ли в «Добавить диалог» список доступных диалогов (ростер)
    /// вместо обмена QR/JSON.
    Q_INVOKABLE bool isCorporateProfile() const;
    /// Стянуть РОСТЕР — список доступных диалогов сотрудника БЕЗ ключей. Асинхронно;
    /// результат — через corporateRosterFetched. Ключи НЕ качаются: только список,
    /// чтобы показать «какие диалоги можно добавить». No-op без corp.json.
    Q_INVOKABLE void fetchCorporateRoster();
    /// Скачать ключ ОДНОГО диалога с partnerServerId и завести/обновить диалог
    /// локально (ленивая раздача — по выбору сотрудника в «Добавить диалог»).
    /// displayName — локальная метка (пусто → ФИО из ростера/server_id). Асинхронно;
    /// результат — через corporateDialogueAdded.
    Q_INVOKABLE void addCorporateDialogue(const QString &partnerServerId, const QString &displayName);

    // ── Маскировка трафика ──────────────────────────────────────────────────
    /// Статус маскировки активного профиля для экрана управления:
    /// {tariff, profileName, state, hasUrl, hasTrusted}.
    Q_INVOKABLE QVariantMap maskingStatus() const;
    /// Стянуть подписанный профиль маскировки с ноды (masking_url из конфига
    /// профиля, опц. Bearer), проверить подпись доверенным ключом и применить.
    /// Сверяет sha256 с сохранённым (индикатор verified/updated). No-op без
    /// masking_url. Асинхронно; результат — через maskingStateChanged/maskingApplied.
    Q_INVOKABLE void syncMaskingFromNode();
    /// Применить профиль маскировки из файла. Если профиль подписан и есть
    /// доверенный ключ — проверяется подпись; иначе при allowUnsigned
    /// применяется без подписи (для частного развёртывания, с предупреждением).
    /// Возвращает {ok, error, profileName, signed}.
    Q_INVOKABLE QVariantMap applyMaskingFromFile(const QString &filePath, bool allowUnsigned);
    /// Вернуть встроенную маску (очистить профиль). {ok}.
    Q_INVOKABLE QVariantMap resetMasking();

    Q_INVOKABLE QVariantList getSessionList() const;
    Q_INVOKABLE void switchSession(const QString &profileId);
    /// «Выход из профиля» — ЛОКАЛЬНОЕ удаление профиля сервера с этого устройства
    /// (сессия + запись в манифесте + папка профиля: диалоги/ключи/БД/вложения).
    /// Серверную дерегистрацию НЕ делает. Если удалён активный — переключает на
    /// другой профиль, а если их не осталось — переводит в состояние «не залогинен».
    Q_INVOKABLE void deleteProfile(const QString &profileId);

    // ── Настройки профиля (локальные: ник/аватар в манифесте) ──
    /// Ник профиля — локальный алиас, показывается в пикере вместо server_id.
    Q_INVOKABLE void setProfileLocalName(const QString &profileId, const QString &name);
    /// Аватар профиля из файла/URI (квадрат 64×64, круг запекается в PNG).
    Q_INVOKABLE bool setProfileAvatar(const QString &profileId, const QString &fileUrl);
    Q_INVOKABLE void clearProfileAvatar(const QString &profileId);
    /// Поля для экрана настроек профиля (server/serverId/username/ник/аватар/резерв).
    Q_INVOKABLE QVariantMap getProfileInfo(const QString &profileId) const;
    /// Ник активного профиля (localName, иначе username) — единое отображаемое имя.
    Q_INVOKABLE QString activeProfileDisplayName() const;
    /// Аватар активного профиля как data:-URL (пусто, если не задан).
    Q_INVOKABLE QString activeProfileAvatar() const;
    /// Сменить первичный адрес сервера профиля (переезд на другой домен). Т.к.
    /// profileId = SHA256(адрес+serverId), меняется и id → каталог профиля
    /// мигрируется (диалоги/ключи/БД сохраняются), затем профиль перелогинивается.
    /// Возвращает {ok:true} или {error:"..."}. ВНИМАНИЕ: profileId после успеха
    /// меняется — UI должен вернуться к списку профилей.
    Q_INVOKABLE QVariantMap changeProfileServer(const QString &profileId, const QString &newServerUrl);

    Q_INVOKABLE void deleteDialogLocal(const QString &peer);
    /// Очистить диалог: удалить всю историю и на сервере, и локально, оставив
    /// сам диалог и его ключи (можно продолжать общение).
    Q_INVOKABLE void clearDialogHistory(const QString &peer);

    // ── Управление данными / самоликвидация ──────────────────────────────────
    /// Разбивка занятого места по категориям для диаграммы: список
    /// {label, bytes, color}. Считает реальные размеры на диске.
    Q_INVOKABLE QVariantList storageBreakdown() const;
    /// Очистить регенерируемый кэш (кэш вложений профилей + временные файлы
    /// видео/голоса/Qt) БЕЗ удаления сообщений/ключей/профилей. Асинхронно;
    /// по завершении — cachesCleared.
    Q_INVOKABLE void clearCaches();
    /// САМОЛИКВИДАЦИЯ (необратимо!): удаляет все диалоги этого устройства со
    /// всех серверов загруженных профилей, затем затирает локальное хранилище
    /// по ГОСТ (3 прохода: случайные/единицы/нули) + crypto-erase vault, и
    /// удаляет все профили/данные. Асинхронно; прогресс — selfDestructProgress,
    /// завершение — selfDestructFinished (UI должен закрыть приложение).
    Q_INVOKABLE void selfDestruct();

    /// Локальное отображаемое имя диалога (бывший username). Маршрутизация идёт
    /// по server_id (peerServerId) — оно не трогается; меняем только показываемое
    /// имя. Локально, не синхронизируется; пусто → показываем внутренний ключ.
    Q_INVOKABLE void setDialogLocalName(const QString &peer, const QString &name);
    /// Задать локальный аватар диалога из файла (file:// или content://):
    /// масштаб до квадрата 64×64 (кроп по центру), PNG base64 в зашифрованном
    /// dialogs (в vault). Возвращает true при успехе.
    Q_INVOKABLE bool setDialogAvatar(const QString &peer, const QString &fileUrl);
    /// Убрать локальный аватар (вернуть букву).
    Q_INVOKABLE void clearDialogAvatar(const QString &peer);
    /// Аватар диалога как data-URL (`data:image/png;base64,…`) для прямого
    /// присвоения в `Image.source`, либо пустая строка если аватара нет.
    /// Нужен экрану звонка (там нет модели диалога — берём по peer).
    Q_INVOKABLE QString dialogAvatar(const QString &peer) const;

    Q_INVOKABLE QVariantMap exportProfile(const QString &profileType, const QStringList &peers,
                                          const QString &receiverPubkeyB64, const QString &filePath);
    /// activate=true: импортированный (первый client-)профиль становится активным
    /// и логинится, даже если уже есть активный профиль (поток регистрации/
    /// онбординга — «войти этим профилем»). activate=false — прежнее поведение
    /// (активирует только если активного профиля ещё нет; для импорта в настройках).
    Q_INVOKABLE QVariantMap importProfile(const QString &filePath, bool activate = false);
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
    // Самоликвидация: phase = "server"|"wipe", fraction 0..1.
    void selfDestructProgress(const QString &phase, double fraction);
    void selfDestructFinished();
    void cachesCleared();
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
    /// Результат синхронизации связки по Корп-API. ok, число обновлённых
    /// диалогов, сообщение.
    void corporateSyncFinished(bool ok, int updated, const QString &message);
    /// Результат загрузки ростера. ok, список записей
    /// [{username, fullName, added}] (added — уже заведён ли диалог локально),
    /// сообщение об ошибке.
    void corporateRosterFetched(bool ok, const QVariantList &entries, const QString &message);
    /// Результат добавления одного диалога по ростеру. ok, server_id партнёра,
    /// сообщение.
    void corporateDialogueAdded(bool ok, const QString &partnerServerId, const QString &message);
    void maskingStateChanged();
    void connectionStateChanged();
    /// Результат применения/сверки маскировки. ok, сообщение для UI.
    void maskingApplied(bool ok, const QString &message);

private:
    static MainBackend *s_instance;
    NotificationCoordinator *m_notifications = nullptr;
    class QNetworkAccessManager *m_net = nullptr; // ленивая инициализация для Корп-API
    QString m_devicePrivkey;
    bool m_hasStoredClientProfiles = false;
    QString m_maskingState;
    QString m_connectionState = QStringLiteral("online");
    QString m_maskingProfileName;
    void setHasStoredClientProfiles(bool hasProfiles);
    void setMaskingState(const QString &state, const QString &profileName = {});
    /// masking-конфиг активного профиля из client.json:
    /// {profileId, tariff, url, bearer, trusted}. Пусто — нет активной сессии.
    QVariantMap activeMaskingConfig() const;
    void loginClientInternal(const QString &server, const QString &username, const QString &private_key,
                             const QStringList &reserveServerUrls, bool makeActive,
                             bool rotateRegistrationKeyOnSuccess = false,
                             const QJsonObject &connectionMeta = {});
    void rotateRegistrationKeyPair(const QString &previousPrivateKey = {});
    void loadClientConfig();
    void saveDeviceKey() const;
    void loadDeviceKey();
    void upsertDialogKeyringEntry(const QString &peer, const QString &peerServerId, const QByteArray &sessionKey,
                                  quint64 startSeq, bool resetKeyring);
    /// Применить расшифрованный JSON связки (roster+keyring) к активной сессии.
    /// Вызывать на главном потоке.
    void applyCorporateKeyring(const QString &keyringJson);
    /// Применить своё ФИО из корп-блоба (full_name) как отображаемое имя
    /// корпоративного профиля. Общая часть для жадной связки и ленивого ростера.
    /// Вызывать на главном потоке.
    void applyCorporateSelfName(const QJsonObject &root);
    /// Подтянуть переименования корп-контактов с сервера: обновить метку `peer`
    /// существующих диалогов из ФИО ростера (server-authoritative для корпа).
    /// Уважает локальное переименование пользователя (localName) — его не трогает,
    /// и не создаёт коллизию меток. Вызывать на главном потоке.
    void applyCorporateRosterNames(const QJsonObject &root);
    /// Прочитать corp-конфиг активного профиля (url дистрибуции + psk + serverId +
    /// signing key). false → профиль не корпоративный/нет активной сессии.
    bool readCorpConfig(QString &distUrl, QString &psk, QString &serverId, QString &signingKey) const;

    // ── Local Vault lifecycle ────────────────────────────────────────────
    void initVault();
    void onVaultUnlocked();
    /// Тело смены PIN. Вызывается отложенно из vaultChangePin() через
    /// QueuedConnection — чтобы UI успел отрисовать busy-overlay перед
    /// тем, как начнётся session teardown и Argon2.
    void doVaultChangePinAsync(const QString &oldPin, const QString &newPin);
};
