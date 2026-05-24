#include "MainBackend.hpp"

#include "Paths.hpp"
#include "NotificationCoordinator.hpp"
#include "utils/adminStorage.hpp"
#include "session/Dialog.hpp"
#include "session/ServerSession.hpp"
#include "session/SessionStore.hpp"
#include "utils/Utils.hpp"
#include <ParanoiaFFI>
#include <QFutureWatcher>
#include <QGuiApplication>

#include <limits>

#include <QCryptographicHash>
#include <QFuture>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
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

void MainBackend::loginClientInternal(const QString &server, const QString &username, const QString &private_key,
                                      const QStringList &reserveServerUrls, bool makeActive,
                                      bool rotateRegistrationKeyOnSuccess)
{
    const QString url                    = Utils::normalizedServerUrl(server);
    const QStringList normalizedReserves = Utils::normalizedServerUrls(reserveServerUrls, url);
    const QString reserveUrlsJson        = Utils::reserveServerUrlsJson(normalizedReserves);
    const QString trimmedUsername        = username.trimmed();
    const QString serverId               = ParanoiaFFI::derive_server_id(private_key);
    if (serverId.isEmpty()) {
        if (makeActive) emit loginError("Не удалось вычислить server ID из ключа.");
        return;
    }
    const QString profileId = Utils::profileIdFor(url, serverId);
    if (!Paths::ensureProfileDir(profileId)) {
        if (makeActive) emit loginError("Не удалось подготовить каталог профиля.");
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
                                          rotateRegistrationKeyOnSuccess]() {
        if (!self) return;
        QMetaObject::invokeMethod(self, [self, dbPath, url, normalizedReserves, turnServerUrls, reserveUrlsJson,
                                         trimmedUsername, serverId, private_key, profileId, makeActive,
                                         rotateRegistrationKeyOnSuccess]() {
            auto handle = std::make_shared<ParanoiaFFI>(url, reserveUrlsJson, serverId, private_key, dbPath);
            if (!self) return;
            if (!handle || !handle->isRawOk()) {
                if (makeActive) emit self->loginError("Не удалось подключиться. Проверьте адрес сервера и ключ.");
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
        emit loginError("Профиль не найден.");
        return;
    }
    const QString server          = obj.value("server").toString();
    const QString username        = obj.value("username").toString();
    const QString private_key     = obj.value("private_key").toString();
    const QStringList reserveUrls = reserveUrlsFromObject(obj, server);
    if (server.isEmpty() || private_key.isEmpty()) {
        emit loginError("Профиль повреждён.");
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
        emit registerUserError("Нет прав администратора для этого сервера.");
        return;
    }
    const QString serverId = serverIdFromPubkey(pubkey);
    if (serverId.isEmpty()) {
        emit registerUserError("Некорректный публичный ключ.");
        return;
    }
    found->regUser(serverId, pubkey).then([this](QFuture<bool> future) {
        const bool ok = future.resultCount() > 0 && future.resultAt(0);
        QMetaObject::invokeMethod(this, [this, ok]() {
            if (ok)
                emit userRegistered();
            else
                emit registerUserError("Ошибка регистрации. Проверьте данные.");
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
        emit reserveDomainError("Нет прав администратора для этого сервера.");
        return;
    }

    const QString reserveUrl = Utils::normalizedServerUrl(reserveDomain);
    if (reserveUrl.isEmpty()) {
        emit reserveDomainError("Укажите резервный домен.");
        return;
    }
    if (reserveUrl == found->domain) {
        emit reserveDomainError("Резервный домен совпадает с основным.");
        return;
    }
    if (Utils::normalizedServerUrls(found->reserveServerUrls, found->domain).contains(reserveUrl)) {
        emit reserveDomainError("Этот резервный домен уже добавлен.");
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
        emit reserveDomainError("Не выбран клиентский профиль.");
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
        emit reserveDomainError("Клиентский профиль повреждён.");
        return;
    }

    const QString reserveUrl = Utils::normalizedServerUrl(reserveDomain);
    if (reserveUrl.isEmpty()) {
        emit reserveDomainError("Укажите резервный домен.");
        return;
    }
    if (reserveUrl == primaryUrl) {
        emit reserveDomainError("Резервный домен совпадает с основным.");
        return;
    }
    if (reserveUrls.contains(reserveUrl)) {
        emit reserveDomainError("Этот резервный домен уже добавлен.");
        return;
    }
    if (serverId.isEmpty()) serverId = ParanoiaFFI::derive_server_id(privateKey);
    if (serverId.isEmpty()) {
        emit reserveDomainError("Не удалось вычислить server ID из ключа профиля.");
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
        emit reserveDomainError("Нет прав администратора для этого сервера.");
        return;
    }

    const QString reserveUrl = Utils::normalizedServerUrl(reserveDomain);
    QStringList reserveUrls  = Utils::normalizedServerUrls(found->reserveServerUrls, found->domain);
    if (reserveUrl.isEmpty() || !reserveUrls.contains(reserveUrl)) {
        emit reserveDomainError("Резервный домен не найден.");
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
        emit reserveDomainError("Не выбран клиентский профиль.");
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
        emit reserveDomainError("Клиентский профиль повреждён.");
        return;
    }

    const QString reserveUrl = Utils::normalizedServerUrl(reserveDomain);
    if (reserveUrl.isEmpty() || !reserveUrls.contains(reserveUrl)) {
        emit reserveDomainError("Резервный домен не найден.");
        return;
    }
    if (serverId.isEmpty()) serverId = ParanoiaFFI::derive_server_id(privateKey);
    if (serverId.isEmpty()) {
        emit reserveDomainError("Не удалось вычислить server ID из ключа профиля.");
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
        emit reserveDomainCheckFinished(targetType, targetId, reserveUrl, false, "Укажите резервный домен.", -1);
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
            msg = err.isEmpty() ? QStringLiteral("Ошибка FFI") : QStringLiteral("Ошибка FFI: ") + err;
        } else {
            QJsonParseError parseError;
            const auto doc = QJsonDocument::fromJson(resultJson.toUtf8(), &parseError);
            if (parseError.error != QJsonParseError::NoError || !doc.isObject()) {
                msg = QStringLiteral("Невалидный ответ FFI");
            } else {
                const auto obj = doc.object();
                ok             = obj.value("ok").toBool();
                if (ok) {
                    msg = QStringLiteral("Endpoint /notify доступен.");
                } else {
                    const QString errText = obj.value("error").toString();
                    msg = errText.isEmpty() ? QStringLiteral("Endpoint недоступен") : errText;
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
        emit turnServerError("Укажите адрес TURN-сервера (host:port).");
        return;
    }

    const QJsonObject obj = Utils::readJsonObjectFile(Paths::profileClient(profileId));
    if (obj.value("server").toString().isEmpty()) {
        emit turnServerError("Профиль не найден или повреждён.");
        return;
    }
    QStringList list = turnUrlsFromObject(obj);
    if (list.contains(normalized, Qt::CaseInsensitive)) {
        emit turnServerError("Этот TURN-сервер уже добавлен.");
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
        emit turnServerError("Пустой адрес TURN-сервера.");
        return;
    }
    const QJsonObject obj = Utils::readJsonObjectFile(Paths::profileClient(profileId));
    if (obj.value("server").toString().isEmpty()) {
        emit turnServerError("Профиль не найден или повреждён.");
        return;
    }
    QStringList list = turnUrlsFromObject(obj);
    const int before = list.size();
    list.removeIf([&](const QString &s) { return QString::compare(s, normalized, Qt::CaseInsensitive) == 0; });
    if (list.size() == before) {
        emit turnServerError("TURN-сервер не найден.");
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
        emit turnServerCheckFinished(profileId, turnUrl, false, "Пустой адрес TURN-сервера.", -1);
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
        emit turnServerCheckFinished(profileId, normalized, false, "Не удалось разобрать host:port.", -1);
        return;
    }
    // Заглушка: эмитим «ok с 0ms» — UI покажет «доступен» (по факту проверка
    // ограничена синтаксисом). TODO: добавить FFI paranoia_turn_probe(host, port).
    emit turnServerCheckFinished(profileId, normalized, true, QStringLiteral("сохранён"), 0);
}

// ── Dialogs Management ────────────────────────────────────────────────────────

QVariantMap MainBackend::createDialogKeyInvitation(const QString &peer) const
{
    const auto session        = SessionStore::instance()->activeSession();
    const QString trimmedPeer = peer.trimmed();
    if (!session || session->serverId.isEmpty() || trimmedPeer.isEmpty())
        return ParanoiaFFI::errorResult("Не указан server ID или собеседник.");

    const QString bundleJson = ParanoiaFFI::qr_create_invitation(session->serverId);
    if (bundleJson.isEmpty()) return ParanoiaFFI::lastRustErrorResult();
    const auto doc = QJsonDocument::fromJson(bundleJson.toUtf8());
    if (!doc.isObject()) return ParanoiaFFI::errorResult("Некорректный JSON invitation.");
    const auto obj            = doc.object();
    const QString stateJson   = Utils::compactJson(obj.value("state"));
    const QString payloadJson = Utils::compactJson(obj.value("payload"));
    if (stateJson.isEmpty() || payloadJson.isEmpty()) return ParanoiaFFI::errorResult("Некорректный JSON invitation.");
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
        return ParanoiaFFI::errorResult("Нет invitation payload или server ID.");
    const QString bundleJson = ParanoiaFFI::qr_create_response(invitationPayloadJson, session->serverId);
    if (bundleJson.isEmpty()) return ParanoiaFFI::lastRustErrorResult();
    const auto doc = QJsonDocument::fromJson(bundleJson.toUtf8());
    if (!doc.isObject()) return ParanoiaFFI::errorResult("Некорректный JSON response.");
    const auto obj            = doc.object();
    const QString stateJson   = Utils::compactJson(obj.value("state"));
    const QString payloadJson = Utils::compactJson(obj.value("payload"));
    if (stateJson.isEmpty() || payloadJson.isEmpty()) return ParanoiaFFI::errorResult("Некорректный JSON response.");
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
        return ParanoiaFFI::errorResult("Нет state или payload для расчёта SAS.");
    const QString fingerprint = ParanoiaFFI::qr_fingerprint(localStateJson, peerPayloadJson);
    if (fingerprint.isEmpty()) return ParanoiaFFI::lastRustErrorResult();
    return QVariantMap{{"ok", true}, {"fingerprint", fingerprint}};
}

QVariantMap MainBackend::confirmDialogKeyExchange(const QString &peer, const QString &localStateJson,
                                                  const QString &peerPayloadJson, const QString &fingerprint,
                                                  const bool updateExisting)
{
    const QString trimmedPeer = peer.trimmed();
    if (trimmedPeer.isEmpty()) return ParanoiaFFI::errorResult("Не указан собеседник.");
    const QString completedJson = ParanoiaFFI::qr_confirm_exchange(localStateJson, peerPayloadJson, fingerprint);
    if (completedJson.isEmpty()) return ParanoiaFFI::lastRustErrorResult();

    const auto doc = QJsonDocument::fromJson(completedJson.toUtf8());
    if (!doc.isObject()) return ParanoiaFFI::errorResult("Некорректный JSON завершения обмена.");
    const auto completedObj     = doc.object();
    const QByteArray sessionKey = QByteArray::fromBase64(completedObj.value("session_key_b64").toString().toLatin1());
    const QString fpResult      = completedObj.value("fingerprint").toString();
    if (sessionKey.size() != 32) return ParanoiaFFI::errorResult("Некорректный ключ диалога.");

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
                emit self->serverHistoryError("Ошибка удаления локальной истории: " + err);
        });
    });
}

void MainBackend::clearDialogHistory(const QString &peer)
{
    auto session = SessionStore::instance()->activeSession();
    if (!session) {
        emit serverHistoryError("Нет активной сессии.");
        return;
    }
    const auto *dlg = session->findDialog(peer);
    if (!dlg) {
        emit serverHistoryError("Диалог не найден.");
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
                emit self->serverHistoryError("Сервер недоступен.");
            else
                emit self->serverHistoryError("Ошибка очистки диалога: " + err);
        });
    });
}

// ── Export / Import ───────────────────────────────────────────────────────────

QVariantMap MainBackend::exportProfile(const QString &profileType, const QStringList &peers,
                                       const QString &receiverPubkeyB64, const QString &filePath)
{
    const QString normalizedProfile = profileType.trimmed();
    if (!Utils::isSupportedExportProfile(normalizedProfile))
        return ParanoiaFFI::errorResult("Неподдерживаемый тип профиля экспорта.");
    if (receiverPubkeyB64.trimmed().isEmpty())
        return ParanoiaFFI::errorResult("Не указан публичный ключ принимающего устройства.");
    const QString normalizedFilePath = Utils::normalizeLocalFilePath(filePath);
    if (normalizedFilePath.isEmpty()) return ParanoiaFFI::errorResult("Не указан путь к файлу.");
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
            return ParanoiaFFI::errorResult("Нет активной клиентской сессии для экспорта.");
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
            return ParanoiaFFI::errorResult("Нет выбранных диалогов с keyring для экспорта.");
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
            return ParanoiaFFI::errorResult("Некорректный публичный ключ принимающего устройства.");
        return ParanoiaFFI::errorResult("Ошибка шифрования экспорта.");
    }
    QFile file(normalizedFilePath);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate))
        return ParanoiaFFI::errorResult("Не удалось открыть файл для записи: " + normalizedFilePath);
    const QByteArray envelopeBytes = envelope.toUtf8();
    if (file.write(envelopeBytes) != envelopeBytes.size()) {
        file.close();
        return ParanoiaFFI::errorResult("Не удалось полностью записать файл экспорта.");
    }
    file.close();
    Utils::setOwnerOnlyPermissions(normalizedFilePath);
    return QVariantMap{
        {"ok", true},
        {"path", normalizedFilePath},
        {"dialogues", exportedDialogues},
        {"keyEntries", exportedKeyEntries},
    };
}

QVariantMap MainBackend::importProfile(const QString &filePath)
{
    if (m_devicePrivkey.isEmpty()) return ParanoiaFFI::errorResult("Device keypair не инициализирован.");
    const QString normalizedFilePath = Utils::normalizeLocalFilePath(filePath);
    if (normalizedFilePath.isEmpty()) return ParanoiaFFI::errorResult("Не указан путь к файлу.");
    QFile file(normalizedFilePath);
    if (!file.open(QIODevice::ReadOnly)) return ParanoiaFFI::errorResult("Не удалось открыть файл: " + normalizedFilePath);
    if (file.size() > Utils::MaxExportFileBytes) {
        file.close();
        return ParanoiaFFI::errorResult("Файл экспорта слишком большой.");
    }
    const QString envelopeJson = QString::fromUtf8(file.readAll());
    file.close();
    if (envelopeJson.trimmed().isEmpty()) return ParanoiaFFI::errorResult("Файл пуст.");
    auto payloadJson = ParanoiaFFI::ecies_decrypt(m_devicePrivkey, envelopeJson);
    if (payloadJson.isEmpty()) {
        const QString err = ParanoiaFFI::last_error();
        if (err == "ecies_decrypt_error")
            return ParanoiaFFI::errorResult(
                "Не удалось расшифровать файл. Файл зашифрован другим ключом или повреждён.");
        if (err == "ecies_unsupported_version")
            return ParanoiaFFI::errorResult("Неподдерживаемая версия формата экспорта.");
        return ParanoiaFFI::errorResult("Ошибка расшифровки.");
    }
    QJsonParseError parseError;
    const auto doc = QJsonDocument::fromJson(payloadJson.toUtf8(), &parseError);
    if (parseError.error != QJsonParseError::NoError || !doc.isObject())
        return ParanoiaFFI::errorResult("Некорректный формат payload после расшифровки.");
    const auto payload = doc.object();
    if (payload["format_version"].toInt() != 1)
        return ParanoiaFFI::errorResult("Неподдерживаемая версия формата payload.");
    const QString profileType = payload["profile_type"].toString();
    if (!Utils::isSupportedExportProfile(profileType))
        return ParanoiaFFI::errorResult("Неподдерживаемый тип профиля в payload.");
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
            return ParanoiaFFI::errorResult("Слишком много client-профилей в export payload.");
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
                return ParanoiaFFI::errorResult("Некорректный private signing key в client-профиле export payload.");
            const QString importedServerId = ParanoiaFFI::derive_server_id(signingKey);
            if (importedServerId.isEmpty())
                return ParanoiaFFI::errorResult("Не удалось вычислить server_id из ключа в export payload.");
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
                return ParanoiaFFI::errorResult("Слишком много диалогов в export payload.");
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
                    return ParanoiaFFI::errorResult("Слишком много keyring entries в export payload.");
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
            return ParanoiaFFI::errorResult("Слишком много admin-профилей в export payload.");
        for (const auto &adminVal : adminServers) {
            const auto adminObj           = adminVal.toObject();
            const QString url             = Utils::normalizedServerUrl(adminObj["url"].toString());
            const QString private_key     = adminObj["admin_private_key_b64"].toString().trimmed();
            const QStringList reserveUrls = Utils::normalizedServerUrls(
                Utils::stringListFromJsonArray(adminObj["reserve_server_urls"].toArray()), url);
            if (url.isEmpty() || private_key.isEmpty()) continue;
            if (!Utils::decodeFixedBase64(private_key, 32))
                return ParanoiaFFI::errorResult("Некорректный private admin key в export payload.");
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
    const QString trimmedPath = Utils::normalizeLocalFilePath(filePath);
    if (trimmedPath.isEmpty()) return ParanoiaFFI::errorResult("Не указан путь к файлу.");
    if (!QFile::exists(trimmedPath))
        return QVariantMap{{"ok", true}, {"deleted", false}, {"message", "Файл уже удалён."}};
    if (!QFile::remove(trimmedPath))
        return ParanoiaFFI::errorResult("Не удалось удалить файл экспорта: " + trimmedPath);
    return QVariantMap{{"ok", true}, {"deleted", true}};
}

QString MainBackend::urlToLocalPath(const QUrl &url) const
{
    if (url.isLocalFile()) return url.toLocalFile();
    // QML может передать сюда уже-локальный путь как строку — Qt сконвертирует
    // в QUrl с пустым scheme, тогда .path() даст обратно ту же строку.
    if (url.scheme().isEmpty()) return url.toString();
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
