#include "MainBackend.hpp"

#include "Paths.hpp"
#include "NotificationCoordinator.hpp"
#include "utils/adminStorage.hpp"
#include "session/Dialog.hpp"
#include "session/ServerSession.hpp"
#include "session/SessionStore.hpp"
#include "platform/PlatformNotifications.hpp"
#include "utils/Utils.hpp"
#include <ParanoiaFFI>
#include <QFileInfo>
#include <QFutureWatcher>
#include <QGuiApplication>

#include <limits>

#include <QCryptographicHash>
#include <QFuture>
#include <QHash>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QPointer>
#include <QUrl>
#include <QJsonParseError>
#include <QMutexLocker>
#include <QThreadPool>
#include <QtConcurrent>
#include <QElapsedTimer>
#include <QDir>
#include <QPointer>
#include <QSet>
#include <QUrl>
#include <algorithm>

#if defined(Q_OS_ANDROID)
#include <QCoreApplication>
#include <QJniEnvironment>
#include <QJniObject>
#endif

#if defined(Q_OS_IOS)
extern "C" bool paranoia_ios_take_share_target(char **out_text, char ***out_files, int *out_file_count);
extern "C" void paranoia_ios_free_share_target(char *text, char **files, int file_count);
#endif

namespace
{
    QStringList reserveUrlsFromObject(const QJsonObject &obj, const QString &primaryUrl)
    {
        return Utils::normalizedServerUrls(Utils::stringListFromJsonArray(obj.value("reserve_server_urls").toArray()),
                                           primaryUrl);
    }

    /// TURN-сервера хранятся как "host:port" или "host" (тогда default port
    /// добавляется при использовании). Нормализуем: trim, deduplicate, lower-case host.
    QStringList turnUrlsFromObject(const QJsonObject &obj)
    {
        QStringList raw = Utils::stringListFromJsonArray(obj.value("turn_server_urls").toArray());
        QStringList out;
        out.reserve(raw.size());
        for (auto &item : raw) {
            const QString trimmed = item.trimmed();
            if (trimmed.isEmpty()) continue;
            if (!out.contains(trimmed, Qt::CaseInsensitive)) out.append(trimmed);
        }
        return out;
    }

    QStringList appendReserveUrl(QStringList urls, const QString &primaryUrl, const QString &reserveUrl)
    {
        urls.append(reserveUrl);
        return Utils::normalizedServerUrls(urls, primaryUrl);
    }

    QString serverIdFromPubkey(const QString &pubkey)
    {
        QByteArray pubkeyBytes;
        if (!Utils::decodeFixedBase64(pubkey, 32, &pubkeyBytes)) return {};
        QCryptographicHash hasher(QCryptographicHash::Sha256);
        hasher.addData(QByteArrayLiteral("paranoia:server-id:v1\n"));
        hasher.addData(pubkeyBytes);
        return QString::fromLatin1(hasher.result().toHex());
    }

    bool isValidRegistrationKeyPair(const QString &pubkey, const QString &privateKey)
    {
        if (!Utils::decodeFixedBase64(pubkey, 32) || !Utils::decodeFixedBase64(privateKey, 32)) return false;
        const QString privateServerId = ParanoiaFFI::derive_server_id(privateKey);
        return !privateServerId.isEmpty() && privateServerId == serverIdFromPubkey(pubkey);
    }

    QJsonObject readPendingRegistrationKeyPair() { return Utils::readJsonObjectFile(Paths::pendingRegistrationKey()); }

    void savePendingRegistrationKeyPair(const QString &pubkey, const QString &privateKey)
    {
        if (!isValidRegistrationKeyPair(pubkey, privateKey)) return;
        QJsonObject obj;
        obj["public_key"]  = pubkey;
        obj["private_key"] = privateKey;
        obj["updated_at"]  = QDateTime::currentDateTimeUtc().toString(Qt::ISODate);
        Utils::writeJsonObjectFile(Paths::pendingRegistrationKey(), obj);
    }

    QStringList removeReserveUrl(QStringList urls, const QString &primaryUrl, const QString &reserveUrl)
    {
        urls = Utils::normalizedServerUrls(urls, primaryUrl);
        urls.removeAll(Utils::normalizedServerUrl(reserveUrl));
        return Utils::normalizedServerUrls(urls, primaryUrl);
    }

    bool isLoadableClientProfile(const QString &profileId)
    {
        if (profileId.trimmed().isEmpty()) return false;
        const auto obj = Utils::readJsonObjectFile(Paths::profileClient(profileId));
        return !obj.value("server").toString().trimmed().isEmpty() &&
               !obj.value("private_key").toString().trimmed().isEmpty();
    }

    bool hasStoredClientProfileOnDisk()
    {
        QSet<QString> seen;
        auto checkId = [&](const QString &profileId) {
            const QString id = profileId.trimmed();
            if (id.isEmpty() || seen.contains(id)) return false;
            seen.insert(id);
            return isLoadableClientProfile(id);
        };

        const QJsonObject manifest = Utils::loadProfilesManifest();
        const QJsonArray profiles  = manifest.value("profiles").toArray();
        for (const auto &value : profiles)
            if (checkId(value.toObject().value("id").toString())) return true;
        if (checkId(manifest.value("last_profile_id").toString())) return true;

        const QDir profilesRoot = Paths::profilesRoot();
        for (const auto &entry : profilesRoot.entryInfoList(QDir::Dirs | QDir::NoDotAndDotDot))
            if (checkId(entry.fileName())) return true;
        return false;
    }
}

MainBackend *MainBackend::s_instance = nullptr;

MainBackend::MainBackend(NotificationCoordinator &notifications, QObject *parent)
    : QObject(parent), m_notifications(&notifications)
{
    s_instance = this;
    initVault();
    m_hasStoredClientProfiles = hasStoredClientProfileOnDisk();
    connect(SessionStore::instance(), &SessionStore::activeSessionChanged, this, &MainBackend::loginStateChanged);
    connect(SessionStore::instance(), &SessionStore::sessionsChanged, this, &MainBackend::sessionsChanged);
    connect(SessionStore::instance(), &SessionStore::activeSessionChanged, this, &MainBackend::sessionsChanged);
    // Авто-синхронизация корпоративной связки при активации сессии (вход/старт).
    // Тихо no-op, если профиль не корпоративный (нет corp-конфига).
    connect(SessionStore::instance(), &SessionStore::activeSessionChanged, this,
            &MainBackend::syncCorporateKeyring);

    // Любое изменение списка диалогов / keyring'а / сессий — повод пересобрать
    // snapshot для notifications-сервиса. Подцепляем оба сигнала: dialogsChanged
    // покрывает add/remove/keyring-update, sessionsChanged — login/logout/смену
    // профиля. publishServiceSnapshot — дешёвый (просто read из RAM + JNI call),
    // дополнительное дробление по «реально ли seq сдвинулся» — за ChatBackend
    // (см. вызовы оттуда после successful pull).
    connect(this, &MainBackend::dialogsChanged, this, &MainBackend::publishServiceSnapshot);
    connect(this, &MainBackend::sessionsChanged, this, &MainBackend::publishServiceSnapshot);

    // device_key.json и admins.crypt теперь под vault'ом — отложены до unlock'а.
    // Lock происходит ТОЛЬКО при выходе (деструктор) — авто-lock в фоне отключён
    // по решению пользователя: сворачивание не должно требовать повторного ввода PIN.
    if (vaultStatus() == 2) onVaultUnlocked();
}

MainBackend::~MainBackend()
{
    ParanoiaFFI::vault_lock();
    s_instance = nullptr;
}

#if defined(Q_OS_ANDROID)
// JNI bridge: Java вызывает после storeShareTarget(), чтобы QML гарантированно
// подобрал данные. Без этого, если приложение уже было в foreground'е,
// onActiveChanged может не сработать → банер "Поделиться" не появится.
extern "C" JNIEXPORT void JNICALL
Java_app_paranoia_client_ParanoiaActivity_nativeShareTargetReady(JNIEnv *, jclass)
{
    auto *backend = MainBackend::instance();
    if (!backend) return;
    QMetaObject::invokeMethod(backend, [backend]() { emit backend->shareTargetReady(); },
                              Qt::QueuedConnection);
}
#endif

bool MainBackend::isLoggedIn() const
{
    const auto session = SessionStore::instance()->activeSession();
    return session && session->isLoggedIn();
}

QString MainBackend::username() const
{
    const auto session = SessionStore::instance()->activeSession();
    return session ? session->username : QString();
}

QString MainBackend::server() const
{
    const auto session = SessionStore::instance()->activeSession();
    return session ? session->server : QString();
}

bool MainBackend::hasAdminAccess() const { return !admin::Admin::admins.empty(); }

QString MainBackend::devicePubkey() const { return ParanoiaFFI::ecies_pubkey(m_devicePrivkey); }

QString MainBackend::activeProfileId() const
{
    const auto session = SessionStore::instance()->activeSession();
    return session ? session->profileId : QString();
}

bool MainBackend::hasStoredClientProfiles() const { return m_hasStoredClientProfiles; }

// ── Local Vault ──────────────────────────────────────────────────────────────

int MainBackend::vaultStatus() const
{
    switch (ParanoiaFFI::vault_status()) {
        case ParanoiaFFI::VaultStatus::NotInitialized: return 0;
        case ParanoiaFFI::VaultStatus::Locked:         return 1;
        case ParanoiaFFI::VaultStatus::Unlocked:       return 2;
        default:                                       return -1;
    }
}

quint64 MainBackend::vaultLockoutSeconds() const { return ParanoiaFFI::vault_lockout_seconds(); }

void MainBackend::initVault()
{
    const QString root = Paths::appDataRoot().path();
    if (ParanoiaFFI::vault_init(root) != 0)
        qWarning().noquote() << "vault_init failed:" << ParanoiaFFI::last_error();
    // Диагностика персистентности: путь и наличие vault.json при старте.
    qInfo().noquote() << "[vault] appDataRoot =" << root
                      << " vault.json exists =" << QFileInfo::exists(root + "/vault.json")
                      << " status =" << static_cast<int>(ParanoiaFFI::vault_status());
}

void MainBackend::vaultSetPin(const QString &pin)
{
    auto *watcher = new QFutureWatcher<int>(this);
    connect(watcher, &QFutureWatcher<int>::finished, this, [this, watcher]() {
        const int rc = watcher->result();
        watcher->deleteLater();
        emit vaultSetPinResult(rc);
        if (rc == 0) {
            // Сначала onVaultUnlocked() — поднимает профили и обновляет
            // hasStoredClientProfiles. Потом vaultStatusChanged — Main.qml
            // gate уже видит правильное значение и роутит на нужную страницу.
            onVaultUnlocked();
            emit vaultStatusChanged();
        }
    });
    watcher->setFuture(QtConcurrent::run([pin]() {
        return ParanoiaFFI::vault_set_pin(pin);
    }));
}

void MainBackend::vaultUnlock(const QString &pin)
{
    auto *watcher = new QFutureWatcher<int>(this);
    connect(watcher, &QFutureWatcher<int>::finished, this, [this, watcher]() {
        const int rc = static_cast<int>(watcher->result());
        watcher->deleteLater();
        emit vaultUnlockResult(rc);
        if (rc == 0) {
            // Сначала onVaultUnlocked() — поднимает профили и обновляет
            // hasStoredClientProfiles. Потом vaultStatusChanged — Main.qml
            // gate уже видит правильное значение и роутит на нужную страницу.
            onVaultUnlocked();
            emit vaultStatusChanged();
        }
    });
    watcher->setFuture(QtConcurrent::run([pin]() -> int {
        const auto r = ParanoiaFFI::vault_unlock(pin);
        return static_cast<int>(r);
    }));
}

void MainBackend::vaultLock()
{
    ParanoiaFFI::vault_lock();
    SessionStore::instance()->setActiveSession({});
    // Расшифрованные превью держатся только в EncryptedImageProvider'е
    // (in-memory). main.cpp подключён к сигналу vaultLocked и вызовет
    // imageProvider->clear() — здесь дополнительная очистка не нужна.
    emit vaultLocked();
    emit vaultStatusChanged();
}

void MainBackend::vaultChangePin(const QString &oldPin, const QString &newPin)
{
    // Откладываем ВСЁ (включая session teardown) на следующий event-loop tick
    // через QueuedConnection: иначе вызов остаётся синхронным внутри JS-handler'а
    // QML, Qt не успевает отрисовать busy-overlay и пользователь видит
    // фриз перед появлением спиннера.
    QMetaObject::invokeMethod(
        this,
        [this, oldPin, newPin]() {
            doVaultChangePinAsync(oldPin, newPin);
        },
        Qt::QueuedConnection);
}

void MainBackend::doVaultChangePinAsync(const QString &oldPin, const QString &newPin)
{
    // 1) Закрываем активные сессии — только vector ops + сигналы (быстро).
    //    Сам тяжёлый teardown (WAL checkpoint, paranoia_client_free) переносится
    //    в worker: держим последние strong-refs в shared vector и роняем их там.
    SessionStore::instance()->setActiveSession({});
    auto ownedSessions =
        std::make_shared<std::vector<std::shared_ptr<ServerSession>>>(
            SessionStore::instance()->allSessions());
    for (const auto &s : *ownedSessions) {
        SessionStore::instance()->removeSession(s);
    }

    // 2) Всё остальное — enumeration файлов + verify_pin + rekey — в worker.
    //    Enumeration (entryInfoList, QFile::exists по всем профилям + attachment-cache)
    //    на медленном диске может занимать сотни мс; на UI thread это видимая
    //    заморозка между нажатием кнопки и появлением busy-overlay.
    auto *watcher = new QFutureWatcher<int>(this);
    connect(watcher, &QFutureWatcher<int>::finished, this, [this, watcher]() {
        const int rc = watcher->result();
        watcher->deleteLater();
        emit vaultChangePinResult(rc);
        if (rc == 0) onVaultUnlocked();
    });
    watcher->setFuture(QtConcurrent::run([oldPin, newPin, ownedSessions]() -> int {
        // 0. Drop ServerSession'ов здесь — WAL checkpoint происходит на воркере.
        ownedSessions->clear();

        // 1. Собрать список JSON-файлов, БД и attachment'ов для перешифровки.
        QStringList jsonFiles;
        if (QFile::exists(Paths::profilesManifest())) jsonFiles << Paths::profilesManifest();
        if (QFile::exists(Paths::deviceKey())) jsonFiles << Paths::deviceKey();
        if (QFile::exists(Paths::pendingRegistrationKey())) jsonFiles << Paths::pendingRegistrationKey();
        if (QFile::exists(Paths::admins())) jsonFiles << Paths::admins();

        QStringList dbFiles;
        QList<QPair<QString, QString>> attachmentFiles;
        const QDir profilesRoot = Paths::profilesRoot();
        for (const auto &entry :
             profilesRoot.entryInfoList(QDir::Dirs | QDir::NoDotAndDotDot)) {
            const QString id = entry.fileName();
            const QString clientPath  = Paths::profileClient(id);
            const QString dialogsPath = Paths::profileDialogs(id);
            const QString dbPath      = Paths::profileDb(id);
            if (QFile::exists(clientPath))  jsonFiles << clientPath;
            if (QFile::exists(dialogsPath)) jsonFiles << dialogsPath;
            if (QFile::exists(dbPath))      dbFiles << dbPath;

            QDir attachDir(entry.absoluteFilePath() + QStringLiteral("/attachment-cache"));
            if (attachDir.exists()) {
                for (const auto &f : attachDir.entryInfoList(QStringList{"*.enc"}, QDir::Files)) {
                    attachmentFiles.append({f.completeBaseName(), f.absoluteFilePath()});
                }
            }
        }

        // 2. Verify старый PIN.
        const int verifyRc = ParanoiaFFI::vault_verify_pin(oldPin);
        if (verifyRc == 1) return 1;
        if (verifyRc != 0) return -1;

        // 3. rekey_begin → файлы → БД → attachments → commit.
        if (ParanoiaFFI::vault_rekey_begin(newPin) != 0) {
            ParanoiaFFI::vault_rekey_abort();
            return -1;
        }
        for (const QString &p : jsonFiles) {
            if (ParanoiaFFI::vault_rekey_file(p) != 0) {
                ParanoiaFFI::vault_rekey_abort();
                return -1;
            }
        }
        for (const QString &db : dbFiles) {
            if (ParanoiaFFI::vault_rekey_db(db) != 0) {
                ParanoiaFFI::vault_rekey_abort();
                return -1;
            }
        }
        for (const auto &att : attachmentFiles) {
            if (ParanoiaFFI::vault_rekey_attachment(att.first, att.second) != 0) {
                ParanoiaFFI::vault_rekey_abort();
                return -1;
            }
        }
        if (ParanoiaFFI::vault_rekey_commit() != 0) {
            ParanoiaFFI::vault_rekey_abort();
            return -1;
        }
        return 0;
    }));
}

void MainBackend::onVaultUnlocked()
{
    // Теперь, когда master_key в RAM, можно читать device_key.json, admins.crypt,
    // profiles.json и поднимать сессии. Перед чтением — сбросить флаг
    // vault-IO-failure: до unlock'а readAll мог получить "vault_locked"
    // (нормальное состояние), и мы НЕ хотим, чтобы оно блокировало
    // последующие легитимные writeFile'ы.
    Utils::resetVaultIoFailure();
    admin::Admin::initAdmins();
    emit adminStateChanged();
    loadDeviceKey();
    loadClientConfig();
    setHasStoredClientProfiles(hasStoredClientProfileOnDisk());
    emit vaultUnlocked();
    // Снапшот для notifications-сервиса: сессии уже подняты loadClientConfig().
    publishServiceSnapshot();
}

// ─────────────────────────────────────────────────────────────────────────────

void MainBackend::setHasStoredClientProfiles(bool hasProfiles)
{
    if (m_hasStoredClientProfiles == hasProfiles) return;
    m_hasStoredClientProfiles = hasProfiles;
    emit storedClientProfilesChanged();
}

// ── Key Generation ────────────────────────────────────────────────────────────

void MainBackend::generateKeyPair()
{
    const QJsonObject pending       = readPendingRegistrationKeyPair();
    const QString pendingPubkey     = pending.value("public_key").toString().trimmed();
    const QString pendingPrivateKey = pending.value("private_key").toString().trimmed();
    if (isValidRegistrationKeyPair(pendingPubkey, pendingPrivateKey)) {
        emit keyPairGenerated(pendingPubkey, pendingPrivateKey);
        return;
    }

    QPointer self(this);
    QThreadPool::globalInstance()->start([self]() {
        auto [secret, pubkey] = ParanoiaFFI::generate_keypair();
        savePendingRegistrationKeyPair(pubkey, secret);
        if (!self) return;
        QMetaObject::invokeMethod(self, [self, pubkey, secret]() {
            if (self) emit self->keyPairGenerated(pubkey, secret);
        });
    });
}

void MainBackend::rotateRegistrationKeyPair(const QString &previousPrivateKey)
{
    const QString expected = previousPrivateKey.trimmed();
    if (!expected.isEmpty()) {
        const QJsonObject pending       = readPendingRegistrationKeyPair();
        const QString currentPrivateKey = pending.value("private_key").toString().trimmed();
        if (!currentPrivateKey.isEmpty() && currentPrivateKey != expected) return;
    }
    auto [secret, pubkey] = ParanoiaFFI::generate_keypair();
    savePendingRegistrationKeyPair(pubkey, secret);
}

// ── Client Login ──────────────────────────────────────────────────────────────

void MainBackend::loginClient(const QString &server, const QString &reserveServer, const QString &username,
                              const QString &private_key)
{
    QStringList reserveUrls;
    if (!reserveServer.trimmed().isEmpty()) reserveUrls.append(reserveServer);
    loginClientInternal(server, username, private_key, reserveUrls, true, true);
}

void MainBackend::loginClientWithMeta(const QString &server, const QString &reserveServer, const QString &username,
                                      const QString &private_key, const QString &tariff, const QString &maskingUrl,
                                      const QString &maskingBearer, const QString &maskingTrustedPubkey)
{
    QStringList reserveUrls;
    if (!reserveServer.trimmed().isEmpty()) reserveUrls.append(reserveServer);
    QJsonObject meta;
    if (!tariff.trimmed().isEmpty())               meta["tariff"] = tariff.trimmed();
    if (!maskingUrl.trimmed().isEmpty())           meta["masking_url"] = maskingUrl.trimmed();
    if (!maskingBearer.trimmed().isEmpty())        meta["masking_bearer"] = maskingBearer.trimmed();
    if (!maskingTrustedPubkey.trimmed().isEmpty()) meta["masking_trusted_pubkey"] = maskingTrustedPubkey.trimmed();
    loginClientInternal(server, username, private_key, reserveUrls, true, true, meta);
}

QVariantMap MainBackend::parseConnectionBundle(const QString &pathOrText) const
{
    // Принимаем либо путь к файлу, либо сырой текст QR. Если это похоже на JSON —
    // парсим как текст; иначе читаем как файл (учитывая content:// URI на Android).
    QByteArray bytes;
    const QString trimmed = pathOrText.trimmed();
    if (trimmed.startsWith('{')) {
        bytes = trimmed.toUtf8();
    } else {
        bytes = Utils::readAll(Utils::resolveImportPath(pathOrText));
        if (bytes.isEmpty()) return QVariantMap{{"ok", false}, {"error", MainBackend::tr("Не удалось прочитать файл")}};
    }
    QJsonParseError perr;
    const QJsonDocument doc = QJsonDocument::fromJson(bytes, &perr);
    if (perr.error != QJsonParseError::NoError || !doc.isObject())
        return QVariantMap{{"ok", false}, {"error", MainBackend::tr("Некорректный профиль подключения (не JSON)")}};
    const QJsonObject o = doc.object();
    if (o.value("type").toString() != QStringLiteral("paranoia.connect.v1"))
        return QVariantMap{{"ok", false}, {"error", MainBackend::tr("Неподдерживаемый формат профиля подключения")}};
    const QString server = Utils::normalizedServerUrl(o.value("server").toString());
    if (server.isEmpty())
        return QVariantMap{{"ok", false}, {"error", MainBackend::tr("В профиле не указан адрес сервера")}};
    const QString tariff = o.value("tariff").toString();
    QStringList reserve = Utils::stringListFromJsonArray(o.value("reserve_server_urls").toArray());
    return QVariantMap{
        {"ok", true},
        {"tariff", tariff},
        {"server", server},
        {"reserve_server_urls", reserve},
        {"masking_url", o.value("masking_url").toString()},
        {"masking_trusted_pubkey", o.value("masking_trusted_pubkey").toString()},
    };
}

void MainBackend::loginClientInternal(const QString &server, const QString &username, const QString &private_key,
                                      const QStringList &reserveServerUrls, bool makeActive,
                                      bool rotateRegistrationKeyOnSuccess, const QJsonObject &connectionMeta)
{
    const QString url                    = Utils::normalizedServerUrl(server);
    const QStringList normalizedReserves = Utils::normalizedServerUrls(reserveServerUrls, url);
    const QString reserveUrlsJson        = Utils::reserveServerUrlsJson(normalizedReserves);
    const QString trimmedUsername        = username.trimmed();
    const QString serverId               = ParanoiaFFI::derive_server_id(private_key);
    if (serverId.isEmpty()) {
        if (makeActive) emit loginError(MainBackend::tr("Не удалось вычислить server ID из ключа."));
        return;
    }
    const QString profileId = Utils::profileIdFor(url, serverId);
    if (!Paths::ensureProfileDir(profileId)) {
        if (makeActive) emit loginError(MainBackend::tr("Не удалось подготовить каталог профиля."));
        return;
    }
    // TURN-список хранится в profile JSON отдельно от reserveServerUrls и не
    // влияет на login-flow — поэтому грузим его здесь и пробрасываем в
    // SessionStore. Reserve может прийти из аргумента (свежий login,
    // import-flow), а TURN всегда из persisted конфига; если JSON нет —
    // пустой список, добавится позже через UI.
    const QStringList turnServerUrls =
        turnUrlsFromObject(Utils::readJsonObjectFile(Paths::profileClient(profileId)));
    const QString dbPath = Paths::profileDb(profileId);
    QPointer self(this);
    QThreadPool::globalInstance()->start([self, url, normalizedReserves, turnServerUrls, reserveUrlsJson,
                                          trimmedUsername, serverId, private_key, dbPath, profileId, makeActive,
                                          rotateRegistrationKeyOnSuccess, connectionMeta]() {
        if (!self) return;
        QMetaObject::invokeMethod(self, [self, dbPath, url, normalizedReserves, turnServerUrls, reserveUrlsJson,
                                         trimmedUsername, serverId, private_key, profileId, makeActive,
                                         rotateRegistrationKeyOnSuccess, connectionMeta]() {
            auto handle = std::make_shared<ParanoiaFFI>(url, reserveUrlsJson, serverId, private_key, dbPath);
            if (!self) return;
            if (!handle || !handle->isRawOk()) {
                if (makeActive) emit self->loginError(MainBackend::tr("Не удалось подключиться. Проверьте адрес сервера и ключ."));
                return;
            }
            auto *store  = SessionStore::instance();
            auto session = store->addSession(std::move(handle), url, trimmedUsername, serverId, private_key, profileId,
                                             normalizedReserves, turnServerUrls);
            session->loadDialogs();
            if (!session->findDialog(QStringLiteral("Избранное"))) {
                QCryptographicHash hasher(QCryptographicHash::Sha256);
                hasher.addData(QByteArrayLiteral("paranoia:self-dialog:v1\n"));
                hasher.addData(serverId.toUtf8());
                hasher.addData(private_key.toUtf8());
                const QByteArray derived = hasher.result();
                QList<DialogKeyEntry> keyring;
                keyring.append({1, derived.left(32)});
                session->dialogs.append({QStringLiteral("Избранное"), serverId, keyring, QString(), QString(), true});
                session->saveDialogs();
            }
            session->saveClientConfig();
            // Метаданные подключения (тариф + параметры маскировки) пишем в
            // client.json поверх — saveClientConfigForProfile их сохраняет при
            // последующих перезаписях.
            if (!connectionMeta.isEmpty()) {
                QJsonObject client = Utils::readJsonObjectFile(Paths::profileClient(profileId));
                for (auto it = connectionMeta.begin(); it != connectionMeta.end(); ++it)
                    client[it.key()] = it.value();
                Utils::writeJsonObjectFile(Paths::profileClient(profileId), client);
            }
            self->setHasStoredClientProfiles(true);
            if (rotateRegistrationKeyOnSuccess) self->rotateRegistrationKeyPair(private_key);
            const QString notificationHintProfileId = self->m_notifications->notificationHintProfileId();
            const bool notificationTargetsThisProfile =
                !notificationHintProfileId.isEmpty() && notificationHintProfileId == profileId;
            const bool notificationTargetsOtherProfile =
                !notificationHintProfileId.isEmpty() && !notificationTargetsThisProfile;
            if (notificationTargetsThisProfile ||
                (makeActive && (!notificationTargetsOtherProfile || !store->activeSession()))) {
                store->setActiveSession(session);
                emit self->sessionReset();
                emit self->loginStateChanged();
                emit self->dialogsChanged();
                // Маскировка commercial/corporate раздаётся нодой — сверяем и
                // применяем при входе (no-op, если профиль её не задаёт).
                self->syncMaskingFromNode();
                // Корпоративная связка: подтянуть ключи диалогов с коллегами
                // (no-op, если профиль не корпоративный — нет corp-конфига).
                self->syncCorporateKeyring();
            }
            self->m_notifications->schedulePoll(0);
        });
    });
}

// ── Activate Profile ─────────────────────────────────────────────────────────

void MainBackend::activateProfile(const QString &profileId)
{
    const auto obj = Utils::readJsonObjectFile(Paths::profileClient(profileId));
    if (obj.isEmpty()) {
        emit loginError(MainBackend::tr("Профиль не найден."));
        return;
    }
    const QString server          = obj.value("server").toString();
    const QString username        = obj.value("username").toString();
    const QString private_key     = obj.value("private_key").toString();
    const QStringList reserveUrls = reserveUrlsFromObject(obj, server);
    if (server.isEmpty() || private_key.isEmpty()) {
        emit loginError(MainBackend::tr("Профиль повреждён."));
        return;
    }
    loginClientInternal(server, username, private_key, reserveUrls, true);
}

// ── Register User (admin action) ──────────────────────────────────────────────

void MainBackend::registerUser(const QString &domain, const QString &pubkey)
{
    const auto found =
        std::ranges::find_if(admin::Admin::admins, [&](const admin::Admin &a) { return a.domain == domain; });
    if (found == admin::Admin::admins.end()) {
        emit registerUserError(MainBackend::tr("Нет прав администратора для этого сервера."));
        return;
    }
    const QString serverId = serverIdFromPubkey(pubkey);
    if (serverId.isEmpty()) {
        emit registerUserError(MainBackend::tr("Некорректный публичный ключ."));
        return;
    }
    found->regUser(serverId, pubkey).then([this](QFuture<bool> future) {
        const bool ok = future.resultCount() > 0 && future.resultAt(0);
        QMetaObject::invokeMethod(this, [this, ok]() {
            if (ok)
                emit userRegistered();
            else
                emit registerUserError(MainBackend::tr("Ошибка регистрации. Проверьте данные."));
        });
    });
}

QVariantList MainBackend::getReserveDomains(const QString &targetType, const QString &targetId,
                                            const QString &primaryDomain) const
{
    QStringList urls;
    if (targetType == "client") {
        const auto session    = SessionStore::instance()->sessionForProfile(targetId);
        const QJsonObject obj = Utils::readJsonObjectFile(Paths::profileClient(targetId));
        QString primaryUrl    = obj.value("server").toString();
        if (primaryUrl.isEmpty() && session) primaryUrl = session->server;
        if (primaryUrl.isEmpty()) primaryUrl = primaryDomain;
        // Disk is authoritative: add/remove writes the new list via saveClientConfigForProfile
        // synchronously before any signal fires, so the session's cached list can be stale.
        urls = Utils::normalizedServerUrls(reserveUrlsFromObject(obj, primaryUrl), primaryUrl);
    } else {
        const QString primaryUrl = Utils::normalizedServerUrl(primaryDomain.isEmpty() ? targetId : primaryDomain);
        const auto found =
            std::ranges::find_if(admin::Admin::admins, [&](const admin::Admin &a) { return a.domain == primaryUrl; });
        if (found != admin::Admin::admins.end())
            urls = Utils::normalizedServerUrls(found->reserveServerUrls, found->domain);
    }

    QVariantList result;
    for (const auto &url : urls) result.append(url);
    return result;
}

void MainBackend::addAdminReserveDomain(const QString &primaryDomain, const QString &reserveDomain)
{
    const QString primaryUrl = Utils::normalizedServerUrl(primaryDomain);
    auto found =
        std::ranges::find_if(admin::Admin::admins, [&](const admin::Admin &a) { return a.domain == primaryUrl; });
    if (found == admin::Admin::admins.end()) {
        emit reserveDomainError(MainBackend::tr("Нет прав администратора для этого сервера."));
        return;
    }

    const QString reserveUrl = Utils::normalizedServerUrl(reserveDomain);
    if (reserveUrl.isEmpty()) {
        emit reserveDomainError(MainBackend::tr("Укажите резервный домен."));
        return;
    }
    if (reserveUrl == found->domain) {
        emit reserveDomainError(MainBackend::tr("Резервный домен совпадает с основным."));
        return;
    }
    if (Utils::normalizedServerUrls(found->reserveServerUrls, found->domain).contains(reserveUrl)) {
        emit reserveDomainError(MainBackend::tr("Этот резервный домен уже добавлен."));
        return;
    }

    found->reserveServerUrls = appendReserveUrl(found->reserveServerUrls, found->domain, reserveUrl);
    admin::Admin::saveAdmins();
    emit adminStateChanged();
    emit reserveDomainAdded("admin", found->domain, reserveUrl);
}

void MainBackend::addClientReserveDomain(const QString &profileId, const QString &reserveDomain)
{
    if (profileId.trimmed().isEmpty()) {
        emit reserveDomainError(MainBackend::tr("Не выбран клиентский профиль."));
        return;
    }

    auto *store              = SessionStore::instance();
    const auto session       = store->sessionForProfile(profileId);
    const auto activeSession = store->activeSession();
    const QJsonObject obj    = Utils::readJsonObjectFile(Paths::profileClient(profileId));
    QString primaryUrl       = obj.value("server").toString();
    QString username         = obj.value("username").toString();
    QString privateKey       = obj.value("private_key").toString();
    QString serverId         = obj.value("server_id").toString();
    QStringList reserveUrls  = reserveUrlsFromObject(obj, primaryUrl);
    if (session) {
        if (primaryUrl.isEmpty()) primaryUrl = session->server;
        if (username.isEmpty()) username = session->username;
        if (privateKey.isEmpty()) privateKey = session->private_key;
        if (serverId.isEmpty()) serverId = session->serverId;
        reserveUrls.append(session->reserveServerUrls);
    }
    primaryUrl  = Utils::normalizedServerUrl(primaryUrl);
    reserveUrls = Utils::normalizedServerUrls(reserveUrls, primaryUrl);
    if (primaryUrl.isEmpty() || privateKey.isEmpty()) {
        emit reserveDomainError(MainBackend::tr("Клиентский профиль повреждён."));
        return;
    }

    const QString reserveUrl = Utils::normalizedServerUrl(reserveDomain);
    if (reserveUrl.isEmpty()) {
        emit reserveDomainError(MainBackend::tr("Укажите резервный домен."));
        return;
    }
    if (reserveUrl == primaryUrl) {
        emit reserveDomainError(MainBackend::tr("Резервный домен совпадает с основным."));
        return;
    }
    if (reserveUrls.contains(reserveUrl)) {
        emit reserveDomainError(MainBackend::tr("Этот резервный домен уже добавлен."));
        return;
    }
    if (serverId.isEmpty()) serverId = ParanoiaFFI::derive_server_id(privateKey);
    if (serverId.isEmpty()) {
        emit reserveDomainError(MainBackend::tr("Не удалось вычислить server ID из ключа профиля."));
        return;
    }

    const QStringList updatedReserveUrls = appendReserveUrl(reserveUrls, primaryUrl, reserveUrl);
    ServerSession::saveClientConfigForProfile(profileId, primaryUrl, username, serverId, privateKey,
                                              updatedReserveUrls);
    const QJsonObject manifest = Utils::loadProfilesManifest();
    Utils::upsertProfileManifest(profileId, primaryUrl, username,
                                 manifest.value("last_profile_id").toString() == profileId);
    if (session)
        loginClientInternal(primaryUrl, username, privateKey, updatedReserveUrls, session == activeSession);
    else
        emit sessionsChanged();
    emit reserveDomainAdded("client", profileId, reserveUrl);
}

void MainBackend::removeAdminReserveDomain(const QString &primaryDomain, const QString &reserveDomain)
{
    const QString primaryUrl = Utils::normalizedServerUrl(primaryDomain);
    auto found =
        std::ranges::find_if(admin::Admin::admins, [&](const admin::Admin &a) { return a.domain == primaryUrl; });
    if (found == admin::Admin::admins.end()) {
        emit reserveDomainError(MainBackend::tr("Нет прав администратора для этого сервера."));
        return;
    }

    const QString reserveUrl = Utils::normalizedServerUrl(reserveDomain);
    QStringList reserveUrls  = Utils::normalizedServerUrls(found->reserveServerUrls, found->domain);
    if (reserveUrl.isEmpty() || !reserveUrls.contains(reserveUrl)) {
        emit reserveDomainError(MainBackend::tr("Резервный домен не найден."));
        return;
    }

    found->reserveServerUrls = removeReserveUrl(reserveUrls, found->domain, reserveUrl);
    admin::Admin::saveAdmins();
    emit adminStateChanged();
    emit reserveDomainRemoved("admin", found->domain, reserveUrl);
}

void MainBackend::removeClientReserveDomain(const QString &profileId, const QString &reserveDomain)
{
    if (profileId.trimmed().isEmpty()) {
        emit reserveDomainError(MainBackend::tr("Не выбран клиентский профиль."));
        return;
    }

    auto *store              = SessionStore::instance();
    const auto session       = store->sessionForProfile(profileId);
    const auto activeSession = store->activeSession();
    const QJsonObject obj    = Utils::readJsonObjectFile(Paths::profileClient(profileId));
    QString primaryUrl       = obj.value("server").toString();
    QString username         = obj.value("username").toString();
    QString privateKey       = obj.value("private_key").toString();
    QString serverId         = obj.value("server_id").toString();
    QStringList reserveUrls  = reserveUrlsFromObject(obj, primaryUrl);
    if (session) {
        if (primaryUrl.isEmpty()) primaryUrl = session->server;
        if (username.isEmpty()) username = session->username;
        if (privateKey.isEmpty()) privateKey = session->private_key;
        if (serverId.isEmpty()) serverId = session->serverId;
        reserveUrls.append(session->reserveServerUrls);
    }
    primaryUrl  = Utils::normalizedServerUrl(primaryUrl);
    reserveUrls = Utils::normalizedServerUrls(reserveUrls, primaryUrl);
    if (primaryUrl.isEmpty() || privateKey.isEmpty()) {
        emit reserveDomainError(MainBackend::tr("Клиентский профиль повреждён."));
        return;
    }

    const QString reserveUrl = Utils::normalizedServerUrl(reserveDomain);
    if (reserveUrl.isEmpty() || !reserveUrls.contains(reserveUrl)) {
        emit reserveDomainError(MainBackend::tr("Резервный домен не найден."));
        return;
    }
    if (serverId.isEmpty()) serverId = ParanoiaFFI::derive_server_id(privateKey);
    if (serverId.isEmpty()) {
        emit reserveDomainError(MainBackend::tr("Не удалось вычислить server ID из ключа профиля."));
        return;
    }

    const QStringList updatedReserveUrls = removeReserveUrl(reserveUrls, primaryUrl, reserveUrl);
    ServerSession::saveClientConfigForProfile(profileId, primaryUrl, username, serverId, privateKey,
                                              updatedReserveUrls);
    const QJsonObject manifest = Utils::loadProfilesManifest();
    Utils::upsertProfileManifest(profileId, primaryUrl, username,
                                 manifest.value("last_profile_id").toString() == profileId);
    if (session)
        loginClientInternal(primaryUrl, username, privateKey, updatedReserveUrls, session == activeSession);
    else
        emit sessionsChanged();
    emit reserveDomainRemoved("client", profileId, reserveUrl);
}

void MainBackend::checkReserveDomain(const QString &targetType, const QString &targetId, const QString &primaryDomain,
                                     const QString &reserveDomain)
{
    const QString reserveUrl = Utils::normalizedServerUrl(reserveDomain);
    if (reserveUrl.isEmpty()) {
        emit reserveDomainCheckFinished(targetType, targetId, reserveUrl, false, MainBackend::tr("Укажите резервный домен."), -1);
        return;
    }

    const QString normalizedTargetId =
        targetType == "client" ? targetId
                               : Utils::normalizedServerUrl(primaryDomain.isEmpty() ? targetId : primaryDomain);

    QPointer<MainBackend> self(this);
    QThreadPool::globalInstance()->start([self, targetType, normalizedTargetId, reserveUrl]() {
        QElapsedTimer timer;
        timer.start();
        const QString resultJson = ParanoiaFFI::check_reserve_url(reserveUrl);
        const qint64 pingMs      = timer.elapsed();

        bool ok = false;
        QString msg;
        if (resultJson.isEmpty()) {
            const QString err = ParanoiaFFI::last_error();
            msg = err.isEmpty() ? MainBackend::tr("Ошибка FFI") : MainBackend::tr("Ошибка FFI: ") + err;
        } else {
            QJsonParseError parseError;
            const auto doc = QJsonDocument::fromJson(resultJson.toUtf8(), &parseError);
            if (parseError.error != QJsonParseError::NoError || !doc.isObject()) {
                msg = MainBackend::tr("Невалидный ответ FFI");
            } else {
                const auto obj = doc.object();
                ok             = obj.value("ok").toBool();
                if (ok) {
                    msg = MainBackend::tr("Endpoint /notify доступен.");
                } else {
                    const QString errText = obj.value("error").toString();
                    msg = errText.isEmpty() ? MainBackend::tr("Endpoint недоступен") : errText;
                }
            }
        }

        QMetaObject::invokeMethod(
            self.data(),
            [self, targetType, normalizedTargetId, reserveUrl, ok, msg, pingMs]() {
                if (self)
                    emit self->reserveDomainCheckFinished(targetType, normalizedTargetId, reserveUrl, ok, msg, pingMs);
            },
            Qt::QueuedConnection);
    });
}

// ── TURN servers ──────────────────────────────────────────────────────────────

namespace
{
    /// Парсит "host:port" / "host" / "turn:host:port" и возвращает
    /// каноническую строку "host:port" (с дефолтным портом 3478, если не задан).
    /// Пустая строка → пусто.
    QString normalizeTurnUrl(const QString &raw)
    {
        QString s = raw.trimmed();
        if (s.isEmpty()) return {};
        // Срезаем префиксы scheme'ов если случайно ввели (turn://, turns://).
        if (s.startsWith("turn://", Qt::CaseInsensitive)) s.remove(0, 7);
        if (s.startsWith("turns://", Qt::CaseInsensitive)) s.remove(0, 8);
        if (s.startsWith("turn:", Qt::CaseInsensitive)) s.remove(0, 5);
        if (s.startsWith("turns:", Qt::CaseInsensitive)) s.remove(0, 6);
        // IPv6 в квадратных скобках: [::1]:3478. Не лезем внутрь — только проверяем
        // наличие порта после ']'.
        if (s.startsWith('[')) {
            const int close = s.indexOf(']');
            if (close <= 0) return {};
            const QString after = s.mid(close + 1);
            if (after.isEmpty() || !after.startsWith(':')) return s + ":3478";
            return s;
        }
        const int lastColon = s.lastIndexOf(':');
        if (lastColon < 0) return s + ":3478";
        // Если "только хост содержит точку и нет порта" — добавим default.
        const QString tail = s.mid(lastColon + 1);
        bool isPort        = !tail.isEmpty();
        for (QChar c : tail) {
            if (!c.isDigit()) {
                isPort = false;
                break;
            }
        }
        if (!isPort) return s + ":3478";
        return s;
    }
} // namespace

QStringList MainBackend::getTurnServers(const QString &profileId) const
{
    const auto session = SessionStore::instance()->sessionForProfile(profileId);
    if (session) return session->turnServerUrls;
    // Профиль не залогинен в этом ран-тайме — читаем с диска.
    return turnUrlsFromObject(Utils::readJsonObjectFile(Paths::profileClient(profileId)));
}

void MainBackend::addTurnServer(const QString &profileId, const QString &turnUrl)
{
    const QString normalized = normalizeTurnUrl(turnUrl);
    if (normalized.isEmpty()) {
        emit turnServerError(MainBackend::tr("Укажите адрес TURN-сервера (host:port)."));
        return;
    }

    const QJsonObject obj = Utils::readJsonObjectFile(Paths::profileClient(profileId));
    if (obj.value("server").toString().isEmpty()) {
        emit turnServerError(MainBackend::tr("Профиль не найден или повреждён."));
        return;
    }
    QStringList list = turnUrlsFromObject(obj);
    if (list.contains(normalized, Qt::CaseInsensitive)) {
        emit turnServerError(MainBackend::tr("Этот TURN-сервер уже добавлен."));
        return;
    }
    list.append(normalized);

    // Сохраняем через ServerSession::saveClientConfigForProfile, чтобы
    // reserve-серверы и прочие поля профиля остались целыми.
    const QString url        = obj.value("server").toString();
    const QString username   = obj.value("username").toString();
    const QString privateKey = obj.value("private_key").toString();
    const QString serverId   = obj.value("server_id").toString();
    ServerSession::saveClientConfigForProfile(profileId, url, username, serverId, privateKey,
                                              reserveUrlsFromObject(obj, url), list);

    // Обновляем runtime-state сессии если она активна.
    const auto session = SessionStore::instance()->sessionForProfile(profileId);
    if (session) {
        session->turnServerUrls = list;
        emit sessionsChanged(); // VoipSystem подписан → переподтянет TURN-список
    }
    emit turnServerAdded(profileId, normalized);
}

void MainBackend::removeTurnServer(const QString &profileId, const QString &turnUrl)
{
    const QString normalized = normalizeTurnUrl(turnUrl);
    if (normalized.isEmpty()) {
        emit turnServerError(MainBackend::tr("Пустой адрес TURN-сервера."));
        return;
    }
    const QJsonObject obj = Utils::readJsonObjectFile(Paths::profileClient(profileId));
    if (obj.value("server").toString().isEmpty()) {
        emit turnServerError(MainBackend::tr("Профиль не найден или повреждён."));
        return;
    }
    QStringList list = turnUrlsFromObject(obj);
    const int before = list.size();
    list.removeIf([&](const QString &s) { return QString::compare(s, normalized, Qt::CaseInsensitive) == 0; });
    if (list.size() == before) {
        emit turnServerError(MainBackend::tr("TURN-сервер не найден."));
        return;
    }
    const QString url        = obj.value("server").toString();
    const QString username   = obj.value("username").toString();
    const QString privateKey = obj.value("private_key").toString();
    const QString serverId   = obj.value("server_id").toString();
    ServerSession::saveClientConfigForProfile(profileId, url, username, serverId, privateKey,
                                              reserveUrlsFromObject(obj, url), list);
    const auto session = SessionStore::instance()->sessionForProfile(profileId);
    if (session) {
        session->turnServerUrls = list;
        emit sessionsChanged();
    }
    emit turnServerRemoved(profileId, normalized);
}

void MainBackend::checkTurnServer(const QString &profileId, const QString &turnUrl)
{
    const QString normalized = normalizeTurnUrl(turnUrl);
    if (normalized.isEmpty()) {
        emit turnServerCheckFinished(profileId, turnUrl, false, MainBackend::tr("Пустой адрес TURN-сервера."), -1);
        return;
    }
    // Простая проверка: попытаться разобрать адрес. Реальный allocate-probe
    // выполняется в момент звонка через ICE connectivity check (см. CallController);
    // сюда подключим полноценный async-probe позже, когда FFI получит
    // standalone turn_allocate без сессии.
    const QString host =
        normalized.contains(':') && !normalized.startsWith('[')
            ? normalized.left(normalized.lastIndexOf(':'))
            : normalized;
    if (host.isEmpty()) {
        emit turnServerCheckFinished(profileId, normalized, false, MainBackend::tr("Не удалось разобрать host:port."), -1);
        return;
    }
    // Заглушка: эмитим «ok с 0ms» — UI покажет «доступен» (по факту проверка
    // ограничена синтаксисом). TODO: добавить FFI paranoia_turn_probe(host, port).
    emit turnServerCheckFinished(profileId, normalized, true, MainBackend::tr("сохранён"), 0);
}

// ── Dialogs Management ────────────────────────────────────────────────────────

QVariantMap MainBackend::createDialogKeyInvitation(const QString &peer) const
{
    const auto session        = SessionStore::instance()->activeSession();
    const QString trimmedPeer = peer.trimmed();
    if (!session || session->serverId.isEmpty() || trimmedPeer.isEmpty())
        return ParanoiaFFI::errorResult(MainBackend::tr("Не указан server ID или собеседник."));

    const QString bundleJson = ParanoiaFFI::qr_create_invitation(session->serverId);
    if (bundleJson.isEmpty()) return ParanoiaFFI::lastRustErrorResult();
    const auto doc = QJsonDocument::fromJson(bundleJson.toUtf8());
    if (!doc.isObject()) return ParanoiaFFI::errorResult(MainBackend::tr("Некорректный JSON invitation."));
    const auto obj            = doc.object();
    const QString stateJson   = Utils::compactJson(obj.value("state"));
    const QString payloadJson = Utils::compactJson(obj.value("payload"));
    if (stateJson.isEmpty() || payloadJson.isEmpty()) return ParanoiaFFI::errorResult(MainBackend::tr("Некорректный JSON invitation."));
    return QVariantMap{
        {"ok", true},
        {"peer", trimmedPeer},
        {"stateJson", stateJson},
        {"payloadJson", payloadJson},
    };
}

QVariantMap MainBackend::createDialogKeyResponse(const QString &invitationPayloadJson)
{
    const auto session = SessionStore::instance()->activeSession();
    if (!session || session->serverId.isEmpty() || invitationPayloadJson.trimmed().isEmpty())
        return ParanoiaFFI::errorResult(MainBackend::tr("Нет invitation payload или server ID."));
    const QString bundleJson = ParanoiaFFI::qr_create_response(invitationPayloadJson, session->serverId);
    if (bundleJson.isEmpty()) return ParanoiaFFI::lastRustErrorResult();
    const auto doc = QJsonDocument::fromJson(bundleJson.toUtf8());
    if (!doc.isObject()) return ParanoiaFFI::errorResult(MainBackend::tr("Некорректный JSON response."));
    const auto obj            = doc.object();
    const QString stateJson   = Utils::compactJson(obj.value("state"));
    const QString payloadJson = Utils::compactJson(obj.value("payload"));
    if (stateJson.isEmpty() || payloadJson.isEmpty()) return ParanoiaFFI::errorResult(MainBackend::tr("Некорректный JSON response."));
    QVariantMap fingerprint = dialogKeyFingerprint(stateJson, invitationPayloadJson);
    if (!fingerprint.value("ok").toBool()) return fingerprint;
    return QVariantMap{
        {"ok", true},
        {"stateJson", stateJson},
        {"payloadJson", payloadJson},
        {"fingerprint", fingerprint.value("fingerprint").toString()},
    };
}

QVariantMap MainBackend::dialogKeyFingerprint(const QString &localStateJson, const QString &peerPayloadJson)
{
    if (localStateJson.trimmed().isEmpty() || peerPayloadJson.trimmed().isEmpty())
        return ParanoiaFFI::errorResult(MainBackend::tr("Нет state или payload для расчёта SAS."));
    const QString fingerprint = ParanoiaFFI::qr_fingerprint(localStateJson, peerPayloadJson);
    if (fingerprint.isEmpty()) return ParanoiaFFI::lastRustErrorResult();
    return QVariantMap{{"ok", true}, {"fingerprint", fingerprint}};
}

QVariantMap MainBackend::confirmDialogKeyExchange(const QString &peer, const QString &localStateJson,
                                                  const QString &peerPayloadJson, const QString &fingerprint,
                                                  const bool updateExisting)
{
    const QString trimmedPeer = peer.trimmed();
    if (trimmedPeer.isEmpty()) return ParanoiaFFI::errorResult(MainBackend::tr("Не указан собеседник."));
    const QString completedJson = ParanoiaFFI::qr_confirm_exchange(localStateJson, peerPayloadJson, fingerprint);
    if (completedJson.isEmpty()) return ParanoiaFFI::lastRustErrorResult();

    const auto doc = QJsonDocument::fromJson(completedJson.toUtf8());
    if (!doc.isObject()) return ParanoiaFFI::errorResult(MainBackend::tr("Некорректный JSON завершения обмена."));
    const auto completedObj     = doc.object();
    const QByteArray sessionKey = QByteArray::fromBase64(completedObj.value("session_key_b64").toString().toLatin1());
    const QString fpResult      = completedObj.value("fingerprint").toString();
    if (sessionKey.size() != 32) return ParanoiaFFI::errorResult(MainBackend::tr("Некорректный ключ диалога."));

    auto session               = SessionStore::instance()->activeSession();
    const QString initiatorId  = completedObj.value("initiator_id").toString();
    const QString responderId  = completedObj.value("responder_id").toString();
    const QString peerServerId = (session && initiatorId == session->serverId) ? responderId : initiatorId;

    if (!updateExisting) {
        upsertDialogKeyringEntry(trimmedPeer, peerServerId, sessionKey, 1, true);
    } else {
        if (session) {
            QPointer self(this);
            QThreadPool::globalInstance()->start([self, session, trimmedPeer, peerServerId, sessionKey]() {
                if (!self) return;
                quint64 seq = 1;
                {
                    QMutexLocker locker(&session->ffiMutex);
                    if (session->ffi && !session->serverId.isEmpty() && !peerServerId.isEmpty()) {
                        uint64_t last = 0;
                        session->ffi->last_pulled_seq(session->serverId, peerServerId, last);
                        seq = static_cast<quint64>(last) + 1;
                    }
                }
                QMetaObject::invokeMethod(self, [self, trimmedPeer, peerServerId, sessionKey, seq]() {
                    if (self) self->upsertDialogKeyringEntry(trimmedPeer, peerServerId, sessionKey, seq, false);
                });
            });
        }
    }
    return QVariantMap{
        {"ok", true},
        {"peer", trimmedPeer},
        {"fingerprint", fpResult},
    };
}

void MainBackend::removeDialog(const QString &peer)
{
    auto session = SessionStore::instance()->activeSession();
    if (!session) return;
    session->dialogs.removeIf([&peer](const Dialog &d) { return d.peer == peer; });
    m_notifications->clearPeer(session->profileId, peer);
    emit dialogRemoved(peer);
    emit dialogsChanged();
    session->saveDialogs();
    m_notifications->schedulePoll();
}

QVariantList MainBackend::getDialogs() const
{
    const auto session = SessionStore::instance()->activeSession();
    if (!session) return {};
    const QString profileId = session->profileId;
    QVariantList result;
    for (const auto &dlg : session->dialogs)
        result.append(QVariantMap{{"peer", dlg.peer},
                                  {"lastMsg", dlg.lastMsg},
                                  {"hasKey", !dlg.keyring.isEmpty()},
                                  {"unreadCount", m_notifications->unreadCount(profileId, dlg.peer)},
                                  {"notificationHint", m_notifications->isNotificationHintFor(profileId, dlg.peer)}});
    return result;
}

QVariantList MainBackend::getAdminServers() const
{
    QVariantList result;
    for (const auto &a : admin::Admin::admins) {
        QVariantMap m;
        QVariantList reserveDomains;
        for (const auto &url : Utils::normalizedServerUrls(a.reserveServerUrls, a.domain)) reserveDomains.append(url);
        m["domain"]         = a.domain;
        m["reserveDomains"] = reserveDomains;
        result.append(m);
    }
    return result;
}

// ── Корпоративный API: синхронизация связки ────────────────────────────────────
// Конфиг (url+psk) задаётся только импортом корпоративного бандла при регистрации
// (см. importProfile → corp.json) — ручной настройки в UI нет.

void MainBackend::applyCorporateKeyring(const QString &keyringJson)
{
    const auto session = SessionStore::instance()->activeSession();
    if (!session) return;
    const QJsonObject root = QJsonDocument::fromJson(keyringJson.toUtf8()).object();
    // Своё ФИО приходит с корп-сервера — для корпоративных профилей оно и есть
    // отображаемое имя пользователя (ник пользователь не задаёт сам).
    const QString selfFullName = root.value("full_name").toString().trimmed();
    if (!selfFullName.isEmpty() && session->username != selfFullName) {
        session->username = selfFullName;
        ServerSession::saveClientConfigForProfile(session->profileId, session->server, selfFullName,
                                                  session->serverId, session->private_key,
                                                  session->reserveServerUrls, session->turnServerUrls);
        Utils::upsertProfileManifest(session->profileId, session->server, selfFullName, true);
        emit loginStateChanged();
    }
    // roster: username(server_id) → ФИО (имя диалога)
    QHash<QString, QString> names;
    for (const auto &v : root.value("roster").toArray()) {
        const QJsonObject o = v.toObject();
        names.insert(o.value("username").toString(), o.value("full_name").toString());
    }
    int updated = 0;
    for (const auto &v : root.value("keyring").toArray()) {
        const QJsonObject e = v.toObject();
        const QString partner  = e.value("partner").toString();
        const QByteArray key   = QByteArray::fromBase64(e.value("key").toString().toLatin1());
        const quint64 startSeq = static_cast<quint64>(e.value("start_seq").toDouble(1));
        if (partner.isEmpty() || key.size() != 32 || startSeq == 0) continue;
        // Если диалог с этим server_id уже есть — сохраняем его текущее имя
        // (локальное переименование приоритетнее ФИО), и не плодим дубликат.
        QString peer;
        for (const auto &d : session->dialogs)
            if (d.peerServerId == partner) { peer = d.peer; break; }
        if (peer.isEmpty()) peer = names.value(partner).trimmed();
        if (peer.isEmpty()) peer = partner;
        upsertDialogKeyringEntry(peer, partner, key, startSeq, false);
        ++updated;
    }
    emit corporateSyncFinished(true, updated,
                               updated > 0 ? MainBackend::tr("Связка обновлена") : MainBackend::tr("Связка пуста"));
}

void MainBackend::syncCorporateKeyring()
{
    const auto session = SessionStore::instance()->activeSession();
    if (!session) return; // тихо: вызывается и автоматически при смене сессии
    const QJsonObject cfg = Utils::readJsonObjectFile(Paths::profileCorp(session->profileId));
    QString distUrl   = cfg.value("url").toString().trimmed(); // url = нода дистрибуции
    const QString psk = cfg.value("psk").toString().trimmed();
    if (distUrl.isEmpty() || psk.isEmpty()) return; // профиль не корпоративный — тихо
    while (distUrl.endsWith('/')) distUrl.chop(1);

    const QString serverId   = session->serverId;
    const QString signingKey = session->private_key;
    if (serverId.isEmpty() || signingKey.isEmpty()) return;

    QPointer self(this);
    // corp_sync делает блокирующий HTTP + расшифровку — на worker-потоке.
    QThreadPool::globalInstance()->start([self, distUrl, serverId, signingKey, psk]() {
        const QString keyringJson = ParanoiaFFI::corp_sync(distUrl, serverId, signingKey, psk);
        // last_error потоко-локальна — читаем здесь же.
        const QString err = keyringJson.isEmpty() ? ParanoiaFFI::last_error() : QString();
        QMetaObject::invokeMethod(qApp, [self, keyringJson, err]() {
            if (!self) return;
            if (keyringJson.isEmpty()) {
                if (err.isEmpty())
                    emit self->corporateSyncFinished(true, 0, MainBackend::tr("Связка пуста"));
                else
                    emit self->corporateSyncFinished(false, 0, MainBackend::tr("Синхронизация: ") + err);
                return;
            }
            self->applyCorporateKeyring(keyringJson);
        });
    });
}

// ── Маскировка трафика ──────────────────────────────────────────────────────

namespace
{
    // Имя профиля из JSON: подписанного {profile_json,sig_b64} или плоского
    // {name,kinds,...}. Заодно сообщает, подписан ли профиль.
    QString maskingProfileNameFromJson(const QByteArray &bytes, bool *isSigned)
    {
        const QJsonObject root = QJsonDocument::fromJson(bytes).object();
        if (root.contains(QStringLiteral("profile_json")) && root.contains(QStringLiteral("sig_b64"))) {
            if (isSigned) *isSigned = true;
            const QJsonObject inner =
                QJsonDocument::fromJson(root.value(QStringLiteral("profile_json")).toString().toUtf8()).object();
            return inner.value(QStringLiteral("name")).toString();
        }
        if (isSigned) *isSigned = false;
        return root.value(QStringLiteral("name")).toString();
    }
}

void MainBackend::setMaskingState(const QString &state, const QString &profileName)
{
    bool changed = false;
    if (m_maskingState != state) { m_maskingState = state; changed = true; }
    if (!profileName.isNull() && m_maskingProfileName != profileName) {
        m_maskingProfileName = profileName;
        changed = true;
    }
    if (changed) emit maskingStateChanged();
}

QVariantMap MainBackend::activeMaskingConfig() const
{
    const auto session = SessionStore::instance()->activeSession();
    if (!session) return {};
    const QJsonObject o = Utils::readJsonObjectFile(Paths::profileClient(session->profileId));
    return QVariantMap{
        {"profileId", session->profileId},
        {"tariff",    o.value("tariff").toString()},
        {"url",       o.value("masking_url").toString().trimmed()},
        {"bearer",    o.value("masking_bearer").toString().trimmed()},
        {"trusted",   o.value("masking_trusted_pubkey").toString().trimmed()},
    };
}

QVariantMap MainBackend::maskingStatus() const
{
    const QVariantMap cfg = activeMaskingConfig();
    if (cfg.isEmpty())
        return QVariantMap{{"tariff", QString()}, {"state", QString()}, {"profileName", QString()},
                           {"hasUrl", false}, {"hasTrusted", false}};
    return QVariantMap{
        {"tariff",      cfg.value("tariff")},
        {"state",       m_maskingState},
        {"profileName", m_maskingProfileName},
        {"hasUrl",      !cfg.value("url").toString().isEmpty()},
        {"hasTrusted",  !cfg.value("trusted").toString().isEmpty()},
    };
}

QVariantMap MainBackend::resetMasking()
{
    auto session = SessionStore::instance()->activeSession();
    if (!session) return QVariantMap{{"ok", false}, {"error", MainBackend::tr("Нет активной сессии")}};
    int rc;
    {
        QMutexLocker locker(&session->ffiMutex);
        if (!session->ffi) return QVariantMap{{"ok", false}, {"error", MainBackend::tr("Сессия не готова")}};
        rc = session->ffi->set_masking_profile(QString());
    }
    if (rc != 0) return QVariantMap{{"ok", false}, {"error", ParanoiaFFI::last_error()}};
    Utils::writeJsonObjectFile(Paths::profileMaskingState(session->profileId), QJsonObject{});
    m_maskingState.clear();
    m_maskingProfileName.clear();
    emit maskingStateChanged();
    emit maskingApplied(true, MainBackend::tr("Возвращена встроенная маска"));
    return QVariantMap{{"ok", true}};
}

QVariantMap MainBackend::applyMaskingFromFile(const QString &filePath, bool allowUnsigned)
{
    auto session = SessionStore::instance()->activeSession();
    if (!session) return QVariantMap{{"ok", false}, {"error", MainBackend::tr("Нет активной сессии")}};
    const QString localPath = Utils::resolveImportPath(filePath);
    const QByteArray bytes  = Utils::readAll(localPath);
    if (bytes.isEmpty()) return QVariantMap{{"ok", false}, {"error", MainBackend::tr("Не удалось прочитать файл")}};

    bool isSigned = false;
    const QString name    = maskingProfileNameFromJson(bytes, &isSigned);
    const QString json    = QString::fromUtf8(bytes);
    const QString trusted = activeMaskingConfig().value("trusted").toString();

    if (isSigned && trusted.isEmpty())
        return QVariantMap{{"ok", false},
                           {"error", MainBackend::tr("Профиль подписан, но доверенный ключ не задан в профиле подключения")}};
    if (!isSigned && !allowUnsigned)
        return QVariantMap{{"ok", false}, {"unsigned", true},
                           {"error", MainBackend::tr("Профиль без подписи. Подтвердите применение без проверки.")}};

    int rc;
    {
        QMutexLocker locker(&session->ffiMutex);
        if (!session->ffi) return QVariantMap{{"ok", false}, {"error", MainBackend::tr("Сессия не готова")}};
        rc = isSigned ? session->ffi->set_signed_masking_profile(json, trusted)
                      : session->ffi->set_masking_profile(json);
    }
    if (rc != 0) return QVariantMap{{"ok", false}, {"error", ParanoiaFFI::last_error()}};

    // Сбрасываем сохранённый хэш — файловое применение перебивает node-сверку.
    Utils::writeJsonObjectFile(Paths::profileMaskingState(session->profileId), QJsonObject{});
    setMaskingState(QStringLiteral("updated"), name);
    emit maskingApplied(true, isSigned ? MainBackend::tr("Подписанный профиль применён")
                                       : MainBackend::tr("Профиль применён без проверки подписи"));
    return QVariantMap{{"ok", true}, {"profileName", name}, {"signed", isSigned}};
}

void MainBackend::syncMaskingFromNode()
{
    const QVariantMap cfg = activeMaskingConfig();
    const QString url = cfg.value("url").toString();
    if (url.isEmpty()) {
        // Профиль не раздаёт маскировку — индикатор скрыт.
        m_maskingState.clear();
        m_maskingProfileName.clear();
        emit maskingStateChanged();
        return;
    }
    const QString trusted = cfg.value("trusted").toString();
    if (trusted.isEmpty()) {
        setMaskingState(QStringLiteral("error"));
        emit maskingApplied(false, MainBackend::tr("Не задан доверенный ключ профиля"));
        return;
    }
    const QString bearer    = cfg.value("bearer").toString();
    const QString profileId = cfg.value("profileId").toString();

    if (!m_net) m_net = new QNetworkAccessManager(this);
    QNetworkRequest req{QUrl(url)};
    if (!bearer.isEmpty())
        req.setRawHeader("Authorization", QByteArray("Bearer ") + bearer.toUtf8());

    setMaskingState(QStringLiteral("checking"));
    QPointer self(this);
    QNetworkReply *reply = m_net->get(req);
    connect(reply, &QNetworkReply::finished, this, [self, reply, profileId, trusted]() {
        reply->deleteLater();
        if (!self) return;
        // Сессия могла смениться, пока шёл запрос — применяем только к своему профилю.
        auto session = SessionStore::instance()->activeSession();
        if (!session || session->profileId != profileId) return;
        if (reply->error() != QNetworkReply::NoError) {
            self->setMaskingState(QStringLiteral("error"));
            emit self->maskingApplied(false, MainBackend::tr("Сеть: ") + reply->errorString());
            return;
        }
        const QByteArray body = reply->readAll();
        bool isSigned = false;
        const QString name = maskingProfileNameFromJson(body, &isSigned);
        int rc;
        {
            QMutexLocker locker(&session->ffiMutex);
            if (!session->ffi) return;
            rc = session->ffi->set_signed_masking_profile(QString::fromUtf8(body), trusted);
        }
        if (rc != 0) {
            self->setMaskingState(QStringLiteral("error"));
            emit self->maskingApplied(false, MainBackend::tr("Профиль отвергнут: ") + ParanoiaFFI::last_error());
            return;
        }
        const QString hash =
            QString::fromLatin1(QCryptographicHash::hash(body, QCryptographicHash::Sha256).toHex());
        const QJsonObject prev = Utils::readJsonObjectFile(Paths::profileMaskingState(profileId));
        const bool changed = prev.value(QStringLiteral("hash")).toString() != hash;
        Utils::writeJsonObjectFile(Paths::profileMaskingState(profileId),
                                   QJsonObject{{"hash", hash}, {"name", name}});
        self->setMaskingState(changed ? QStringLiteral("updated") : QStringLiteral("verified"), name);
        emit self->maskingApplied(true, changed ? MainBackend::tr("Маска обновлена")
                                                : MainBackend::tr("Маска сверена"));
    });
}

// ── History Management ────────────────────────────────────────────────────────

void MainBackend::deleteDialogLocal(const QString &peer)
{
    auto session = SessionStore::instance()->activeSession();
    if (!session || !session->findDialog(peer)) return;
    const QString peerCopy     = peer;
    const QString serverId     = session->serverId;
    const QString profileId    = session->profileId;
    const auto *dlg            = session->findDialog(peer);
    const QString peerServerId = dlg ? dlg->peerServerId : QString();
    QPointer self(this);
    QThreadPool::globalInstance()->start([self, session, peerCopy, serverId, peerServerId, profileId]() {
        if (!self) return;
        QMutexLocker locker(&session->ffiMutex);
        if (!session->ffi) return;
        int rc   = (!serverId.isEmpty() && !peerServerId.isEmpty())
                       ? session->ffi->delete_local_dialogue(serverId, peerServerId)
                       : session->ffi->delete_local_dialogue(session->username, peerCopy);
        auto err = ParanoiaFFI::last_error();
        QMetaObject::invokeMethod(self, [self, peerCopy, profileId, rc, err]() {
            if (!self) return;
            if (rc == 0) {
                self->m_notifications->clearPeer(profileId, peerCopy);
                emit self->dialogRemoved(peerCopy);
                emit self->dialogDeleted(peerCopy);
            } else
                emit self->serverHistoryError(MainBackend::tr("Ошибка удаления локальной истории: ") + err);
        });
    });
}

void MainBackend::clearDialogHistory(const QString &peer)
{
    auto session = SessionStore::instance()->activeSession();
    if (!session) {
        emit serverHistoryError(MainBackend::tr("Нет активной сессии."));
        return;
    }
    const auto *dlg = session->findDialog(peer);
    if (!dlg) {
        emit serverHistoryError(MainBackend::tr("Диалог не найден."));
        return;
    }
    const QString peerCopy     = peer;
    const QString serverId     = session->serverId;
    const QString peerServerId = dlg->peerServerId;
    const QString keyringJson  = dlg->keyringJson();
    QPointer self(this);
    QThreadPool::globalInstance()->start([self, session, peerCopy, serverId, peerServerId, keyringJson]() {
        if (!self) return;
        QMutexLocker locker(&session->ffiMutex);
        if (!session->ffi) return;
        const QString myId   = serverId.isEmpty() ? session->username : serverId;
        const QString peerId = peerServerId.isEmpty() ? peerCopy : peerServerId;
        // u64::MAX как верхняя граница — сервер всё равно проходит только по
        // существующим ключам префикса диалога, а локально метод фильтрует
        // существующие server_seq.
        int rc      = session->ffi->delete_dialogue_range_keyring(myId, peerId, keyringJson, 0,
                                                                  std::numeric_limits<quint64>::max());
        QString err = ParanoiaFFI::last_error();
        QMetaObject::invokeMethod(self, [self, err, peerCopy, rc]() {
            if (!self) return;
            if (rc == 0) {
                emit self->serverHistoryCleared(peerCopy);
                emit self->dialogsChanged();
            } else if (err == "server_unavailable")
                emit self->serverHistoryError(MainBackend::tr("Сервер недоступен."));
            else
                emit self->serverHistoryError(MainBackend::tr("Ошибка очистки диалога: ") + err);
        });
    });
}

// ── Export / Import ───────────────────────────────────────────────────────────

QVariantMap MainBackend::exportProfile(const QString &profileType, const QStringList &peers,
                                       const QString &receiverPubkeyB64, const QString &filePath)
{
    const QString normalizedProfile = profileType.trimmed();
    if (!Utils::isSupportedExportProfile(normalizedProfile))
        return ParanoiaFFI::errorResult(MainBackend::tr("Неподдерживаемый тип профиля экспорта."));
    if (receiverPubkeyB64.trimmed().isEmpty())
        return ParanoiaFFI::errorResult(MainBackend::tr("Не указан публичный ключ принимающего устройства."));
    // На Android FileDialog (SaveFile) возвращает content:// URI — его нельзя
    // нормализовать в локальный путь, поэтому передаём цель как есть и пишем
    // через Utils::writeBytesToTarget (SAF на Android, обычный файл на desktop).
    const QString exportTarget = filePath.trimmed();
    if (exportTarget.isEmpty()) return ParanoiaFFI::errorResult(MainBackend::tr("Не указан путь к файлу."));
    QJsonObject payload;
    payload["format_version"] = 1;
    payload["profile_type"]   = normalizedProfile;
    const bool includeClient  = (normalizedProfile == "client" || normalizedProfile == "full");
    const bool includeAdmin   = (normalizedProfile == "admin" || normalizedProfile == "full");
    int exportedDialogues     = 0;
    int exportedKeyEntries    = 0;
    if (includeClient) {
        auto session = SessionStore::instance()->activeSession();
        if (!session || session->server.isEmpty() || session->private_key.isEmpty())
            return ParanoiaFFI::errorResult(MainBackend::tr("Нет активной клиентской сессии для экспорта."));
        QJsonArray dialoguesArr;
        for (const auto &dlg : session->dialogs) {
            if (!peers.isEmpty() && !peers.contains(dlg.peer)) continue;
            if (dlg.keyring.isEmpty()) continue;
            QJsonObject dlgObj;
            dlgObj["peer"]           = dlg.peer;
            dlgObj["peer_server_id"] = dlg.peerServerId;
            QJsonArray keyringArr;
            for (const auto &entry : dlg.keyring) {
                if (entry.key.size() != 32 || entry.startSeq == 0) continue;
                QJsonObject keyObj;
                keyObj["start_seq"] = static_cast<double>(entry.startSeq);
                keyObj["key"]       = QString::fromLatin1(entry.key.toBase64());
                keyringArr.append(keyObj);
            }
            if (keyringArr.isEmpty()) continue;
            dlgObj["keyring"] = keyringArr;
            dialoguesArr.append(dlgObj);
            ++exportedDialogues;
            exportedKeyEntries += keyringArr.size();
        }
        if (!peers.isEmpty() && exportedDialogues == 0)
            return ParanoiaFFI::errorResult(MainBackend::tr("Нет выбранных диалогов с keyring для экспорта."));
        QJsonObject serverObj;
        serverObj["url"]                 = session->server;
        serverObj["reserve_server_urls"] = Utils::stringListToJsonArray(session->reserveServerUrls);
        serverObj["username"]            = session->username;
        serverObj["signing_key_b64"]     = session->private_key;
        serverObj["dialogues"]           = dialoguesArr;
        payload["servers"]               = QJsonArray{serverObj};
    }

    if (includeAdmin) {
        QJsonArray adminArr;
        for (const auto &a : admin::Admin::admins) {
            QJsonObject adminObj;
            adminObj["url"]                   = a.domain;
            adminObj["admin_private_key_b64"] = a.private_key;
            adminObj["reserve_server_urls"] =
                Utils::stringListToJsonArray(Utils::normalizedServerUrls(a.reserveServerUrls, a.domain));
            adminArr.append(adminObj);
        }
        payload["admin_servers"] = adminArr;
    }
    if (!includeClient) payload["servers"] = QJsonArray{};
    if (!includeAdmin) payload["admin_servers"] = QJsonArray{};
    const QString payloadJson = QString::fromUtf8(QJsonDocument(payload).toJson(QJsonDocument::Compact));
    auto envelope             = ParanoiaFFI::ecies_encrypt(receiverPubkeyB64.trimmed(), payloadJson);
    if (envelope.isEmpty()) {
        if (ParanoiaFFI::last_error() == "invalid_device_key")
            return ParanoiaFFI::errorResult(MainBackend::tr("Некорректный публичный ключ принимающего устройства."));
        return ParanoiaFFI::errorResult(MainBackend::tr("Ошибка шифрования экспорта."));
    }
    const QByteArray envelopeBytes = envelope.toUtf8();
    if (!Utils::writeBytesToTarget(exportTarget, envelopeBytes))
        return ParanoiaFFI::errorResult(MainBackend::tr("Не удалось записать файл экспорта."));
    return QVariantMap{
        {"ok", true},
        {"path", exportTarget},
        {"dialogues", exportedDialogues},
        {"keyEntries", exportedKeyEntries},
    };
}

QVariantMap MainBackend::importProfile(const QString &filePath)
{
    if (m_devicePrivkey.isEmpty()) return ParanoiaFFI::errorResult(MainBackend::tr("Device keypair не инициализирован."));
    // На Android FileDialog возвращает content:// URI — QFile его не откроет.
    // resolveImportPath на Android копирует контент в CacheLocation и
    // возвращает путь к копии; cleanup ниже.
    const QString normalizedFilePath = Utils::resolveImportPath(filePath);
    if (normalizedFilePath.isEmpty()) return ParanoiaFFI::errorResult(MainBackend::tr("Не указан путь к файлу."));
    const bool isContentUri =
        filePath.trimmed().startsWith(QStringLiteral("content://"), Qt::CaseInsensitive);
    QFile file(normalizedFilePath);
    if (!file.open(QIODevice::ReadOnly)) {
        if (isContentUri) QFile::remove(normalizedFilePath);
        return ParanoiaFFI::errorResult(MainBackend::tr("Не удалось открыть файл: ") + normalizedFilePath);
    }
    if (file.size() > Utils::MaxExportFileBytes) {
        file.close();
        if (isContentUri) QFile::remove(normalizedFilePath);
        return ParanoiaFFI::errorResult(MainBackend::tr("Файл экспорта слишком большой."));
    }
    const QString envelopeJson = QString::fromUtf8(file.readAll());
    file.close();
    // Кэш-копия от resolveImportPath больше не нужна — освобождаем место.
    if (isContentUri) QFile::remove(normalizedFilePath);
    if (envelopeJson.trimmed().isEmpty()) return ParanoiaFFI::errorResult(MainBackend::tr("Файл пуст."));
    auto payloadJson = ParanoiaFFI::ecies_decrypt(m_devicePrivkey, envelopeJson);
    if (payloadJson.isEmpty()) {
        const QString err = ParanoiaFFI::last_error();
        if (err == "ecies_decrypt_error")
            return ParanoiaFFI::errorResult(
                MainBackend::tr("Не удалось расшифровать файл. Файл зашифрован другим ключом или повреждён."));
        if (err == "ecies_unsupported_version")
            return ParanoiaFFI::errorResult(MainBackend::tr("Неподдерживаемая версия формата экспорта."));
        return ParanoiaFFI::errorResult(MainBackend::tr("Ошибка расшифровки."));
    }
    QJsonParseError parseError;
    const auto doc = QJsonDocument::fromJson(payloadJson.toUtf8(), &parseError);
    if (parseError.error != QJsonParseError::NoError || !doc.isObject())
        return ParanoiaFFI::errorResult(MainBackend::tr("Некорректный формат payload после расшифровки."));
    const auto payload = doc.object();
    if (payload["format_version"].toInt() != 1)
        return ParanoiaFFI::errorResult(MainBackend::tr("Неподдерживаемая версия формата payload."));
    const QString profileType = payload["profile_type"].toString();
    if (!Utils::isSupportedExportProfile(profileType))
        return ParanoiaFFI::errorResult(MainBackend::tr("Неподдерживаемый тип профиля в payload."));
    const bool allowClientImport = (profileType == "client" || profileType == "full");
    const bool allowAdminImport  = (profileType == "admin" || profileType == "full");
    int importedDialogues        = 0;
    int importedKeyEntries       = 0;
    int importedAdminServers     = 0;
    int skippedEntries           = 0;
    int conflicts                = 0;
    int importedProfiles         = 0;
    QString activateServer;
    QString activateUsername;
    QString activatePrivkey;
    QStringList activateReserveServerUrls;
    const auto mergeKeyringEntry = [](QList<Dialog> &dialogs, const QString &peer, const QString &peerServerId,
                                      const QByteArray &key, quint64 startSeq) -> int {
        for (auto &dlg : dialogs) {
            if (dlg.peer != peer) continue;
            if (dlg.peerServerId.isEmpty() && !peerServerId.isEmpty()) dlg.peerServerId = peerServerId;
            for (const auto &entry : dlg.keyring) {
                if (entry.startSeq != startSeq) continue;
                return entry.key == key ? 0 : -1;
            }
            dlg.keyring.append({startSeq, key});
            std::sort(dlg.keyring.begin(), dlg.keyring.end(),
                      [](const DialogKeyEntry &lhs, const DialogKeyEntry &rhs) { return lhs.startSeq < rhs.startSeq; });
            return 1;
        }
        dialogs.append({peer, peerServerId, QList<DialogKeyEntry>{{startSeq, key}}, QString(), QString()});
        return 1;
    };
    if (allowClientImport) {
        auto session              = SessionStore::instance()->activeSession();
        const QString myProfileId = session ? session->profileId : QString();
        const QJsonArray servers  = payload["servers"].toArray();
        if (servers.size() > Utils::MaxImportServers)
            return ParanoiaFFI::errorResult(MainBackend::tr("Слишком много client-профилей в export payload."));
        int totalDialogues  = 0;
        int totalKeyEntries = 0;
        for (const auto &serverVal : servers) {
            const auto serverObj    = serverVal.toObject();
            const QString url       = Utils::normalizedServerUrl(serverObj["url"].toString());
            QStringList reserveUrls = Utils::normalizedServerUrls(
                Utils::stringListFromJsonArray(serverObj["reserve_server_urls"].toArray()), url);
            const QString username   = serverObj["username"].toString().trimmed();
            const QString signingKey = serverObj["signing_key_b64"].toString().trimmed();
            if (url.isEmpty()) continue;
            if (!Utils::decodeFixedBase64(signingKey, 32))
                return ParanoiaFFI::errorResult(MainBackend::tr("Некорректный private signing key в client-профиле export payload."));
            const QString importedServerId = ParanoiaFFI::derive_server_id(signingKey);
            if (importedServerId.isEmpty())
                return ParanoiaFFI::errorResult(MainBackend::tr("Не удалось вычислить server_id из ключа в export payload."));
            const QString profileId    = Utils::profileIdFor(url, importedServerId);
            const bool isCurrentClient = !myProfileId.isEmpty() && (profileId == myProfileId);
            const bool profileExists   = QFile::exists(Paths::profileClient(profileId));
            if (profileExists) {
                const QJsonObject existing = Utils::readJsonObjectFile(Paths::profileClient(profileId));
                const QString existingKey  = existing.value("private_key").toString().trimmed();
                if (!existingKey.isEmpty() && existingKey != signingKey) {
                    ++conflicts;
                    continue;
                }
                reserveUrls.append(reserveUrlsFromObject(existing, url));
                reserveUrls = Utils::normalizedServerUrls(reserveUrls, url);
            }
            QList<Dialog> targetDialogs =
                isCurrentClient ? session->dialogs : Dialog::loadFromPath(Paths::profileDialogs(profileId));
            QSet<QString> touchedDialogues;
            const QJsonArray dialogues = serverObj["dialogues"].toArray();
            if (totalDialogues + dialogues.size() > Utils::MaxImportDialogues)
                return ParanoiaFFI::errorResult(MainBackend::tr("Слишком много диалогов в export payload."));
            totalDialogues += dialogues.size();
            for (const auto &dlgVal : dialogues) {
                const auto dlgObj          = dlgVal.toObject();
                const QString peer         = dlgObj["peer"].toString();
                const QString peerServerId = dlgObj["peer_server_id"].toString();
                if (peer.isEmpty()) {
                    ++skippedEntries;
                    continue;
                }
                const QJsonArray keyringArr = dlgObj["keyring"].toArray();
                if (keyringArr.isEmpty()) {
                    ++skippedEntries;
                    continue;
                }
                if (totalKeyEntries + keyringArr.size() > Utils::MaxImportKeyEntries)
                    return ParanoiaFFI::errorResult(MainBackend::tr("Слишком много keyring entries в export payload."));
                totalKeyEntries += keyringArr.size();
                for (const auto &keyVal : keyringArr) {
                    const auto keyObj      = keyVal.toObject();
                    bool seqOk             = false;
                    const quint64 startSeq = Utils::readSeq(keyObj["start_seq"], &seqOk);
                    QByteArray key;
                    if (!seqOk || !Utils::decodeFixedBase64(keyObj["key"].toString(), 32, &key)) {
                        ++skippedEntries;
                        continue;
                    }
                    const int mergeResult = mergeKeyringEntry(targetDialogs, peer, peerServerId, key, startSeq);
                    if (mergeResult < 0) {
                        ++conflicts;
                        continue;
                    }
                    if (mergeResult == 0) {
                        ++skippedEntries;
                        continue;
                    }
                    ++importedKeyEntries;
                    if (!touchedDialogues.contains(peer)) {
                        touchedDialogues.insert(peer);
                        ++importedDialogues;
                    }
                }
            }
            ServerSession::saveClientConfigForProfile(profileId, url, username, importedServerId, signingKey,
                                                      reserveUrls);
            // Корпоративный/маскировочный бандл несёт доп. метаданные подключения:
            // тариф, параметры раздачи маскировки и Корп-API. Доносим их в профиль.
            const QString bundleTariff   = serverObj["tariff"].toString();
            const QJsonObject maskingObj = serverObj["masking"].toObject();
            const QJsonObject corpObj    = serverObj["corp"].toObject();
            if (!bundleTariff.isEmpty() || !maskingObj.isEmpty()) {
                QJsonObject client = Utils::readJsonObjectFile(Paths::profileClient(profileId));
                if (!bundleTariff.isEmpty()) client["tariff"] = bundleTariff;
                if (maskingObj.contains("url"))            client["masking_url"] = maskingObj["url"].toString();
                if (maskingObj.contains("bearer"))         client["masking_bearer"] = maskingObj["bearer"].toString();
                if (maskingObj.contains("trusted_pubkey")) client["masking_trusted_pubkey"] = maskingObj["trusted_pubkey"].toString();
                Utils::writeJsonObjectFile(Paths::profileClient(profileId), client);
            }
            if (corpObj.contains("url") || corpObj.contains("psk"))
                Utils::writeJsonObjectFile(Paths::profileCorp(profileId),
                                           QJsonObject{{"url", corpObj["url"].toString()},
                                                       {"psk", corpObj["psk"].toString()}});
            Dialog::saveToPath(Paths::profileDialogs(profileId), targetDialogs);
            Utils::upsertProfileManifest(profileId, url, username, isCurrentClient || myProfileId.isEmpty());
            if (!profileExists) ++importedProfiles;
            if (myProfileId.isEmpty() && activatePrivkey.isEmpty()) {
                activateServer            = url;
                activateUsername          = username;
                activatePrivkey           = signingKey;
                activateReserveServerUrls = reserveUrls;
            }
            if (isCurrentClient) {
                session->dialogs = targetDialogs;
                emit sessionReset();
                emit dialogsChanged();
            }
        }
    }
    if (allowAdminImport) {
        const QJsonArray adminServers = payload["admin_servers"].toArray();
        if (adminServers.size() > Utils::MaxImportAdminServers)
            return ParanoiaFFI::errorResult(MainBackend::tr("Слишком много admin-профилей в export payload."));
        for (const auto &adminVal : adminServers) {
            const auto adminObj           = adminVal.toObject();
            const QString url             = Utils::normalizedServerUrl(adminObj["url"].toString());
            const QString private_key     = adminObj["admin_private_key_b64"].toString().trimmed();
            const QStringList reserveUrls = Utils::normalizedServerUrls(
                Utils::stringListFromJsonArray(adminObj["reserve_server_urls"].toArray()), url);
            if (url.isEmpty() || private_key.isEmpty()) continue;
            if (!Utils::decodeFixedBase64(private_key, 32))
                return ParanoiaFFI::errorResult(MainBackend::tr("Некорректный private admin key в export payload."));
            bool found = false;
            for (auto &a : admin::Admin::admins)
                if (a.domain == url) {
                    if (a.private_key == private_key) {
                        const QStringList merged = Utils::normalizedServerUrls(a.reserveServerUrls + reserveUrls, url);
                        if (merged != a.reserveServerUrls) {
                            a.reserveServerUrls = merged;
                            ++importedAdminServers;
                        }
                    }
                    found = true;
                    break;
                }
            if (!found) {
                admin::Admin::admins.push_back({url, private_key, reserveUrls});
                ++importedAdminServers;
            }
        }
    }
    if (importedAdminServers > 0) {
        admin::Admin::saveAdmins();
        emit adminStateChanged();
    }
    if (importedProfiles > 0 || !activatePrivkey.isEmpty()) setHasStoredClientProfiles(true);
    if (!activatePrivkey.isEmpty())
        loginClientInternal(activateServer, activateUsername, activatePrivkey, activateReserveServerUrls, true);
    return QVariantMap{
        {"ok", true},
        {"importedDialogues", importedDialogues},
        {"importedKeyEntries", importedKeyEntries},
        {"importedAdminServers", importedAdminServers},
        {"importedProfiles", importedProfiles},
        {"skippedEntries", skippedEntries},
        {"conflicts", conflicts},
    };
}

QVariantMap MainBackend::takeShareTarget()
{
    QVariantMap result;
#if defined(Q_OS_ANDROID)
    const QJniObject context = QNativeInterface::QAndroidApplication::context();
    if (!context.isValid()) return result;
    const QJniObject raw = QJniObject::callStaticObjectMethod(
        "app/paranoia/client/ParanoiaAndroidUtils", "takeShareTarget",
        "(Landroid/content/Context;)Ljava/lang/String;", context.object<jobject>());
    QJniEnvironment env;
    if (env->ExceptionCheck()) {
        env->ExceptionDescribe();
        env->ExceptionClear();
        return result;
    }
    if (!raw.isValid()) return result;
    const QString payload = raw.toString();
    if (payload.isEmpty()) return result;
    // Формат: "<text><uri1>\n<uri2>\n..." (см. ParanoiaAndroidUtils.takeShareTarget).
    const QChar separator(QChar(0x0001));
    const int idx = payload.indexOf(separator);
    QString text;
    QStringList uris;
    if (idx < 0) {
        text = payload;
    } else {
        text = payload.left(idx);
        const QString tail = payload.mid(idx + 1);
        if (!tail.isEmpty()) {
            uris = tail.split(QChar('\n'), Qt::SkipEmptyParts);
        }
    }
    if (text.isEmpty() && uris.isEmpty()) return result;
    result.insert(QStringLiteral("text"), text);
    result.insert(QStringLiteral("files"), uris);
#elif defined(Q_OS_IOS)
    char *text     = nullptr;
    char **files   = nullptr;
    int fileCount  = 0;
    if (!paranoia_ios_take_share_target(&text, &files, &fileCount)) return result;
    const QString textStr = (text != nullptr) ? QString::fromUtf8(text) : QString();
    QStringList uris;
    uris.reserve(fileCount);
    for (int i = 0; i < fileCount; ++i)
        if (files[i] != nullptr) uris.append(QString::fromUtf8(files[i]));
    paranoia_ios_free_share_target(text, files, fileCount);
    if (textStr.isEmpty() && uris.isEmpty()) return result;
    result.insert(QStringLiteral("text"), textStr);
    result.insert(QStringLiteral("files"), uris);
#endif
    return result;
}

QVariantMap MainBackend::deleteExportFile(const QString &filePath)
{
    const QString raw = filePath.trimmed();
    // content:// (Android SAF): удалять через QFile нельзя, а через
    // ContentResolver.delete() прав обычно нет. Возвращаем «manual» сразу
    // вместо вводящей в заблуждение ошибки FS.
    if (raw.startsWith(QStringLiteral("content://"), Qt::CaseInsensitive))
        return ParanoiaFFI::errorResult(
            MainBackend::tr("Файл выбран из системного хранилища — удалите его вручную через файловый менеджер."));
    const QString trimmedPath = Utils::normalizeLocalFilePath(filePath);
    if (trimmedPath.isEmpty()) return ParanoiaFFI::errorResult(MainBackend::tr("Не указан путь к файлу."));
    if (!QFile::exists(trimmedPath))
        return QVariantMap{{"ok", true}, {"deleted", false}, {"message", MainBackend::tr("Файл уже удалён.")}};
    if (!QFile::remove(trimmedPath))
        return ParanoiaFFI::errorResult(MainBackend::tr("Не удалось удалить файл экспорта: ") + trimmedPath);
    return QVariantMap{{"ok", true}, {"deleted", true}};
}

QString MainBackend::urlToLocalPath(const QUrl &url) const
{
    if (url.isLocalFile()) return url.toLocalFile();
    // QML может передать сюда уже-локальный путь как строку — Qt сконвертирует
    // в QUrl с пустым scheme, тогда .path() даст обратно ту же строку.
    if (url.scheme().isEmpty()) return url.toString();
    // Android SAF: FileDialog возвращает content:// URI. toLocalFile() для него
    // пуст, поэтому возвращаем URI как есть (в кодированном виде, чтобы не
    // потерять %-escape'ы для ContentResolver). Его разруливают
    // Utils::resolveImportPath (импорт) и Utils::writeBytesToTarget (экспорт).
    if (url.scheme().compare(QStringLiteral("content"), Qt::CaseInsensitive) == 0)
        return url.toString(QUrl::FullyEncoded);
    return url.toLocalFile();
}

// ── Helpers ───────────────────────────────────────────────────────────────────

void MainBackend::upsertDialogKeyringEntry(const QString &peer, const QString &peerServerId,
                                           const QByteArray &sessionKey, quint64 startSeq, bool resetKeyring)
{
    if (peer.isEmpty() || sessionKey.size() != 32 || startSeq == 0) return;
    auto session = SessionStore::instance()->activeSession();
    if (!session) return;
    auto &dialogs = session->dialogs;
    for (auto &d : dialogs) {
        if (d.peer == peer) {
            if (!peerServerId.isEmpty()) d.peerServerId = peerServerId;
            if (resetKeyring) d.keyring.clear();
            bool replaced = false;
            for (auto &entry : d.keyring)
                if (entry.startSeq == startSeq) {
                    entry.key = sessionKey;
                    replaced  = true;
                    break;
                }
            if (!replaced) { d.keyring.append({startSeq, sessionKey}); }
            std::sort(d.keyring.begin(), d.keyring.end(),
                      [](const DialogKeyEntry &lhs, const DialogKeyEntry &rhs) { return lhs.startSeq < rhs.startSeq; });
            emit dialogsChanged();
            session->saveDialogs();
            m_notifications->schedulePoll();
            return;
        }
    }
    dialogs.append({peer, peerServerId, QList<DialogKeyEntry>{{startSeq, sessionKey}}, QString(), QString()});
    emit dialogsChanged();
    session->saveDialogs();
    m_notifications->schedulePoll();
}

// ── Session Management ────────────────────────────────────────────────────────

QVariantList MainBackend::getSessionList() const
{
    const auto activeSession = SessionStore::instance()->activeSession();
    QVariantList result;
    for (const auto &session : SessionStore::instance()->allSessions()) {
        result.append(QVariantMap{
            {"profileId", session->profileId},
            {"server", session->server},
            {"reserveServerUrls", Utils::stringListToJsonArray(session->reserveServerUrls).toVariantList()},
            {"username", session->username},
            {"isActive", session == activeSession},
            {"totalUnread", m_notifications->totalUnreadForProfile(session->profileId)},
        });
    }
    return result;
}

void MainBackend::switchSession(const QString &profileId)
{
    auto session = SessionStore::instance()->sessionForProfile(profileId);
    if (!session || session == SessionStore::instance()->activeSession()) return;
    SessionStore::instance()->setActiveSession(session);
    m_notifications->resetActiveContext();
    emit sessionReset();
    emit dialogsChanged();
    emit sessionSwitched();
    syncMaskingFromNode();
    m_notifications->schedulePoll(0);
}

// ── Persistence ───────────────────────────────────────────────────────────────

void MainBackend::loadClientConfig()
{
    const QJsonObject manifest  = Utils::loadProfilesManifest();
    const QString lastProfileId = manifest.value("last_profile_id").toString();
    const QJsonArray profiles   = manifest.value("profiles").toArray();

    QSet<QString> loaded;
    auto tryLoad = [&](const QString &profileId, bool makeActive) {
        if (profileId.isEmpty() || loaded.contains(profileId)) return;
        const auto obj = Utils::readJsonObjectFile(Paths::profileClient(profileId));
        if (obj.isEmpty()) return;
        const QString server          = obj.value("server").toString();
        const QString username        = obj.value("username").toString();
        const QString private_key     = obj.value("private_key").toString();
        const QStringList reserveUrls = reserveUrlsFromObject(obj, server);
        if (server.isEmpty() || private_key.isEmpty()) return;
        loaded.insert(profileId);
        loginClientInternal(server, username, private_key, reserveUrls, makeActive);
    };

    for (const auto &value : profiles) {
        const QString id = value.toObject().value("id").toString();
        tryLoad(id, id == lastProfileId);
    }
    // Also try lastProfileId directly in case it's not in the profiles array yet
    if (!loaded.contains(lastProfileId)) tryLoad(lastProfileId, true);
}

void MainBackend::saveDeviceKey() const
{
    QJsonObject obj;
    obj["private_key_b64"] = m_devicePrivkey;
    if (Utils::writeFile(Paths::deviceKey(), QJsonDocument(obj).toJson()))
        Utils::setOwnerOnlyPermissions(Paths::deviceKey());
}

void MainBackend::loadDeviceKey()
{
    auto doc = QJsonDocument::fromJson(Utils::readAll(Paths::deviceKey()));
    if (doc.isObject()) {
        const QString priv = doc.object()["private_key_b64"].toString();
        if (!priv.isEmpty() && QByteArray::fromBase64(priv.toLatin1()).size() == 32) {
            m_devicePrivkey = priv;
            return;
        }
    }
    auto [privateKey, publicKey] = ParanoiaFFI::ecies_generate_keypair();
    if (!privateKey.isEmpty()) m_devicePrivkey = privateKey;
    saveDeviceKey();
    emit deviceKeyChanged();
}

void MainBackend::publishServiceSnapshot()
{
    QJsonArray profiles;
    const auto sessions = SessionStore::instance()->allSessions();
    for (const auto &session : sessions) {
        if (!session) continue;
        if (session->server.isEmpty() || session->private_key.isEmpty()
            || session->serverId.isEmpty())
            continue;

        QJsonArray reserveUrls;
        for (const QString &u : session->reserveServerUrls) reserveUrls.append(u);

        QJsonArray dialogs;
        // last_pulled_seq лежит в SQLCipher; берём его пока vault unlocked
        // и UI ещё держит handle. Сервис будет использовать это значение
        // как baseline для notify_count.
        for (const Dialog &d : session->dialogs) {
            if (d.peerServerId.isEmpty()) continue;
            uint64_t seq = 0;
            {
                QMutexLocker lock(&session->ffiMutex);
                if (session->ffi) {
                    session->ffi->last_pulled_seq(session->serverId, d.peerServerId, seq);
                }
            }
            QJsonObject dialog;
            dialog["partnerServerId"] = d.peerServerId;
            dialog["seq"]             = qint64(seq);
            dialogs.append(dialog);
        }
        if (dialogs.isEmpty()) continue;

        QJsonObject profile;
        profile["server"]         = session->server;
        profile["reserveUrls"]    = reserveUrls;
        profile["signingKeyB64"]  = session->private_key;
        profile["senderServerId"] = session->serverId;
        profile["dialogs"]        = dialogs;
        profiles.append(profile);
    }
    QJsonObject root;
    root["profiles"] = profiles;
    const QString json =
        QString::fromUtf8(QJsonDocument(root).toJson(QJsonDocument::Compact));
    PlatformNotifications::publishServiceSnapshot(json);
}
