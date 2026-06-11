#include "VersionInfoBackend.hpp"

#include <QCoreApplication>
#include <QDesktopServices>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QProcess>
#include <QSslConfiguration>
#include <QStandardPaths>
#include <QStringList>
#include <QSysInfo>
#include <QUrl>
#include <QVersionNumber>

#include <QThreadPool>
#include <cstdint>

#if defined(Q_OS_ANDROID)
#include <QJniObject>
#endif

// ── #30/#37: HTTP обновлений идёт через Rust/rustls (единый TLS-стек; на Android
// работает БЕЗ Qt-OpenSSL-бандла). Объявления FFI из libparanoia (паттерн как в
// MainBackend — inline extern "C", без include заголовка).
extern "C" {
char *paranoia_http_get(const char *url);
int paranoia_http_download(const char *url, const char *dest_path,
                           int (*progress)(uint64_t, uint64_t, void *), void *user_data);
const char *paranoia_last_error();
void paranoia_free_string(char *s);
}

namespace
{
    constexpr auto kReleasePageUrl = "https://github.com/ParanoiaMesseger/Paranoia/releases";
    constexpr auto kLatestReleaseApiUrl =
        "https://api.github.com/repos/ParanoiaMesseger/Paranoia/releases/latest";

    // #37 резервный источник обновлений: CSV-манифест на собственном домене —
    // используется, когда api.github.com заблокирован. Формат строки:
    //   type,sha256,path,version
    constexpr auto kReserveArtefactsUrl = "https://paranoia.run/artefacts.csv";
    constexpr auto kReserveBaseUrl      = "https://paranoia.run";

    // Тип артефакта текущей платформы в манифесте artefacts.csv.
    // ⚠ РЕКОНСТРУКЦИЯ (исходник был утерян, восстановлено по описанию+бинарю):
    // СВЕРИТЬ точные имена типов с серверным artefacts.csv.
    QString reserveArtefactType()
    {
#if defined(Q_OS_ANDROID)
        return QStringLiteral("client-android");
#elif defined(Q_OS_IOS)
        return QStringLiteral("client-ios");
#elif defined(Q_OS_WIN)
        return QStringLiteral("client-windows");
#elif defined(Q_OS_MACOS)
        return QStringLiteral("client-macos");
#elif defined(Q_OS_LINUX)
        return QStringLiteral("client-linux");
#else
        return {};
#endif
    }

    QString normalizedVersionTag(QString tag)
    {
        tag = tag.trimmed();
        if (tag.startsWith(QLatin1Char('v')) || tag.startsWith(QLatin1Char('V'))) tag.remove(0, 1);
        return tag;
    }

    bool isRemoteVersionNewer(const QString &remote, const QString &current)
    {
        const auto remoteVersion  = QVersionNumber::fromString(normalizedVersionTag(remote));
        const auto currentVersion = QVersionNumber::fromString(normalizedVersionTag(current));
        return !remoteVersion.isNull() && !currentVersion.isNull() &&
               QVersionNumber::compare(remoteVersion, currentVersion) > 0;
    }

    QStringList preferredUpdateAssetNames()
    {
#if defined(Q_OS_ANDROID)
        return {QStringLiteral("paranoia-android-arm64.apk"), QStringLiteral("android")};
#elif defined(Q_OS_IOS)
        return {QStringLiteral("paranoia-ios-arm64.ipa"), QStringLiteral("ios")};
#elif defined(Q_OS_WIN)
        return {QStringLiteral("paranoia-windows-x86_64-installer.exe"), QStringLiteral("windows")};
#elif defined(Q_OS_LINUX)
        const QString arch = QSysInfo::currentCpuArchitecture();
        if (arch == QStringLiteral("arm64") || arch == QStringLiteral("aarch64"))
            return {QStringLiteral("paranoia-arm64"), QStringLiteral("linux")};
        if (arch == QStringLiteral("arm") || arch == QStringLiteral("armhf"))
            return {QStringLiteral("paranoia-armhf"), QStringLiteral("linux")};
        return {QStringLiteral("paranoia-linux-x86_64-installer"), QStringLiteral("amd64"), QStringLiteral("x86_64")};
#else
        return {};
#endif
    }

    QString selectDownloadUrl(const QJsonObject &release)
    {
        // GitHub Releases API: assets — массив объектов с name и browser_download_url
        // (абсолютные ссылки, в отличие от относительных links у GitLab).
        const QJsonArray assets          = release.value(QStringLiteral("assets")).toArray();
        const QStringList preferredNames = preferredUpdateAssetNames();
        QString fallback;
        for (const auto &assetValue : assets) {
            const QJsonObject asset = assetValue.toObject();
            const QString name      = asset.value(QStringLiteral("name")).toString();
            const QString url       = asset.value(QStringLiteral("browser_download_url")).toString().trimmed();
            if (url.isEmpty()) continue;
            if (fallback.isEmpty()) fallback = url;
            for (const auto &preferred : preferredNames) {
                if (name.contains(preferred, Qt::CaseInsensitive)) return url;
            }
        }
        return fallback.isEmpty() ? QString::fromLatin1(kReleasePageUrl) : fallback;
    }
}

VersionInfoBackend::VersionInfoBackend(QObject *parent) : QObject(parent)
{
    // HTTP проверки/скачивания обновлений идут через Rust/rustls (см. checkForUpdates),
    // поэтому Qt QNetworkAccessManager здесь не нужен (и не работал бы на Android без
    // OpenSSL-бандла). TLS + проверка сертификатов — на стороне Rust.

    // Чистим остаток прошлой загрузки (после установки апдейта мы стартуем уже
    // новой версией — самое время убрать скачанный установщик, чтобы не копить).
    cleanupDownloads();
}

VersionInfoBackend::~VersionInfoBackend() = default;

bool VersionInfoBackend::updateCheckInProgress() const { return m_updateCheckInProgress; }

bool VersionInfoBackend::updateAvailable() const { return m_updateAvailable; }

QString VersionInfoBackend::latestVersion() const { return m_latestVersion; }

QString VersionInfoBackend::updateStatus() const { return m_updateStatus; }

QString VersionInfoBackend::releasePageUrl() const { return QString::fromLatin1(kReleasePageUrl); }

QString VersionInfoBackend::downloadUrl() const { return m_downloadUrl; }

// #30: in-app установка поддержана там, где можем штатно запустить установщик.
// mac/iOS — установка только через App Store (canInstallInApp=false → кнопка
// «Скачать»/переход в стор).
bool VersionInfoBackend::canInstallInApp() const
{
#if defined(Q_OS_ANDROID) || defined(Q_OS_WIN) || (defined(Q_OS_LINUX) && !defined(Q_OS_ANDROID))
    return true;
#else
    return false;
#endif
}

bool VersionInfoBackend::downloading() const { return m_downloading; }

double VersionInfoBackend::downloadProgress() const { return m_downloadProgress; }

QString VersionInfoBackend::downloadStatus() const { return m_downloadStatus; }

void VersionInfoBackend::setDownloadStatus(const QString &status)
{
    m_downloadStatus = status;
    emit downloadChanged();
}

QString VersionInfoBackend::updateDownloadDir() const
{
#if defined(Q_OS_ANDROID)
    // files-dir (AppDataLocation): именно его покрывает qtprovider FileProvider
    // (files-path), а cache-dir (TempLocation) — НЕТ → getUriForFile упал бы.
    // Отдельная подпапка updates/ — чтобы чистить её целиком, не трогая данные.
    const QString base = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
#else
    const QString base = QStandardPaths::writableLocation(QStandardPaths::TempLocation);
#endif
    return QDir(base).filePath(QStringLiteral("paranoia-updates"));
}

void VersionInfoBackend::cleanupDownloads()
{
    QDir dir(updateDownloadDir());
    if (dir.exists()) dir.removeRecursively();
}

void VersionInfoBackend::checkForUpdates()
{
    // Во время активной загрузки не перезапускаем проверку — иначе сбросим
    // m_downloadUrl/статус под идущей установкой (VersionInfoPage зовёт проверку
    // в onCompleted, а попап «Обновить» уже стартовал downloadAndInstall).
    if (m_updateCheckInProgress || m_downloading) return;
    m_updateCheckInProgress = true;
    m_updateAvailable       = false;
    m_updateStatus          = tr("Проверка обновлений…");
    m_downloadUrl.clear();
    emit updateCheckChanged();

    auto *self = this;
    // GET через Rust/rustls (блокирующий) — на воркере; парсинг JSON в GUI-потоке.
    QThreadPool::globalInstance()->start([self]() {
        char *raw       = paranoia_http_get(kLatestReleaseApiUrl);
        const bool ok   = raw != nullptr;
        const QString body = ok ? QString::fromUtf8(raw) : QString();
        if (raw) paranoia_free_string(raw);
        QMetaObject::invokeMethod(
            self,
            [self, ok, body]() {
                self->m_updateCheckInProgress = false;
                if (!ok) {
                    // #37: api.github.com недоступен/заблокирован → резервный источник.
                    self->checkReserveUpdates();
                    return;
                }
                QJsonParseError parseError;
                const QJsonDocument doc = QJsonDocument::fromJson(body.toUtf8(), &parseError);
                if (parseError.error != QJsonParseError::NoError || !doc.isObject()) {
                    self->m_updateAvailable = false;
                    self->m_updateStatus = VersionInfoBackend::tr("Сервер вернул некорректный ответ о релизе.");
                    self->m_downloadUrl  = QString::fromLatin1(kReleasePageUrl);
                    emit self->updateCheckChanged();
                    return;
                }
                const QJsonObject release = doc.object();
                self->m_latestVersion = release.value(QStringLiteral("tag_name")).toString();
                if (self->m_latestVersion.isEmpty()) {
                    self->m_updateAvailable = false;
                    self->m_updateStatus = VersionInfoBackend::tr("В последнем релизе не указана версия.");
                    self->m_downloadUrl  = QString::fromLatin1(kReleasePageUrl);
                    emit self->updateCheckChanged();
                    return;
                }
                self->m_updateAvailable =
                    isRemoteVersionNewer(self->m_latestVersion, QCoreApplication::applicationVersion());
                self->m_downloadUrl = self->m_updateAvailable ? selectDownloadUrl(release)
                                                              : QString::fromLatin1(kReleasePageUrl);
                self->m_updateStatus =
                    self->m_updateAvailable
                        ? VersionInfoBackend::tr("Доступна новая версия %1.").arg(self->m_latestVersion)
                        : VersionInfoBackend::tr("Установлена актуальная версия %1.")
                              .arg(QCoreApplication::applicationVersion());
                emit self->updateCheckChanged();
            },
            Qt::QueuedConnection);
    });
}

// #37 ⚠ РЕКОНСТРУКЦИЯ (исходник утерян при rewrite истории, восстановлено по
// описанию + строкам из сборки 10.06). Логика: тянем CSV-манифест с резервного
// домена, ищем строку для текущей платформы (type), сравниваем версию. СВЕРИТЬ
// формат/имена типов с реальным artefacts.csv.
void VersionInfoBackend::checkReserveUpdates()
{
    m_updateCheckInProgress = true;
    m_updateStatus          = tr("Проверка резервного источника обновлений…");
    emit updateCheckChanged();

    auto *self = this;
    QThreadPool::globalInstance()->start([self]() {
        char *raw       = paranoia_http_get(kReserveArtefactsUrl);
        const bool ok   = raw != nullptr;
        const QString body = ok ? QString::fromUtf8(raw) : QString();
        if (raw) paranoia_free_string(raw);
        QMetaObject::invokeMethod(
            self,
            [self, ok, body]() {
                self->m_updateCheckInProgress = false;
                if (!ok) {
                    self->m_updateAvailable = false;
                    self->m_updateStatus =
                        VersionInfoBackend::tr("Не удалось проверить обновления. Откройте страницу релизов вручную.");
                    self->m_downloadUrl = QString::fromLatin1(kReleasePageUrl);
                    emit self->updateCheckChanged();
                    return;
                }
                const QString type = reserveArtefactType();
                QString foundVersion, foundPath;
                const QStringList lines = body.split(QLatin1Char('\n'), Qt::SkipEmptyParts);
                for (const QString &line : lines) {
                    // type,sha256,path,version
                    const QStringList cols = line.split(QLatin1Char(','));
                    if (cols.size() < 4) continue;
                    if (cols.at(0).trimmed() != type) continue;
                    foundPath    = cols.at(2).trimmed();
                    foundVersion = cols.at(3).trimmed();
                    break;
                }
                if (foundVersion.isEmpty()) {
                    self->m_updateAvailable = false;
                    self->m_updateStatus =
                        VersionInfoBackend::tr("Резервный источник не содержит сборку для этой платформы.");
                    self->m_downloadUrl = QString::fromLatin1(kReleasePageUrl);
                    emit self->updateCheckChanged();
                    return;
                }
                self->m_latestVersion = foundVersion;
                self->m_updateAvailable =
                    isRemoteVersionNewer(foundVersion, QCoreApplication::applicationVersion());
                if (self->m_updateAvailable) {
                    // path — абсолютный URL или относительный к kReserveBaseUrl.
                    self->m_downloadUrl =
                        foundPath.startsWith(QStringLiteral("http"))
                            ? foundPath
                            : QString::fromLatin1(kReserveBaseUrl)
                                  + (foundPath.startsWith(QLatin1Char('/')) ? foundPath
                                                                            : QLatin1Char('/') + foundPath);
                } else {
                    self->m_downloadUrl = QString::fromLatin1(kReleasePageUrl);
                }
                self->m_updateStatus =
                    self->m_updateAvailable
                        ? VersionInfoBackend::tr("Доступна новая версия %1.").arg(self->m_latestVersion)
                        : VersionInfoBackend::tr("Установлена актуальная версия %1.")
                              .arg(QCoreApplication::applicationVersion());
                emit self->updateCheckChanged();
            },
            Qt::QueuedConnection);
    });
}

void VersionInfoBackend::openUrlExternally(const QString &url)
{
    const QUrl parsed(url.trimmed());
    if (parsed.isValid()) QDesktopServices::openUrl(parsed);
}

void VersionInfoBackend::openDownloadUrl()
{
    openUrlExternally(m_downloadUrl.isEmpty() ? QString::fromLatin1(kReleasePageUrl) : m_downloadUrl);
}

void VersionInfoBackend::openReleasePage() { openUrlExternally(QString::fromLatin1(kReleasePageUrl)); }

// #30 ⚠ РЕКОНСТРУКЦИЯ (исходник утерян при rewrite истории; восстановлено по
// описанию + интерфейсу из бинаря/QML). Скачивает артефакт во временный файл с
// прогрессом и запускает установку штатным для платформы способом.
void VersionInfoBackend::downloadAndInstall()
{
    if (m_downloading) return;
    // Платформы без in-app установки (mac/iOS) — переход по ссылке/в стор.
    if (!canInstallInApp()) { openDownloadUrl(); return; }

    const QString url = m_downloadUrl;
    if (url.isEmpty() || url == QString::fromLatin1(kReleasePageUrl)) { openDownloadUrl(); return; }

    QString fileName = QUrl(url).fileName();
    if (fileName.isEmpty()) fileName = QStringLiteral("paranoia-update");
    const QString dir = updateDownloadDir();
    QDir().mkpath(dir);
    m_downloadFilePath = QDir(dir).filePath(fileName);

    m_downloading      = true;
    m_downloadProgress = 0.0;
    m_downloadStatus   = tr("Скачивание…");
    m_cancelRequested.store(false);
    emit downloadChanged();

    auto *self = this;
    const QByteArray urlUtf8  = url.toUtf8();
    const QByteArray destUtf8 = m_downloadFilePath.toUtf8();
    // Загрузка через Rust/rustls (блокирующая) — на воркере; прогресс/результат в GUI.
    QThreadPool::globalInstance()->start([self, urlUtf8, destUtf8]() {
        const int rc = paranoia_http_download(urlUtf8.constData(), destUtf8.constData(),
                                              &VersionInfoBackend::downloadProgressCallback, self);
        QString err;
        if (rc == -1) {
            const char *e = paranoia_last_error();
            err = e ? QString::fromUtf8(e) : QString();
        }
        QMetaObject::invokeMethod(
            self,
            [self, rc, err]() {
                self->m_downloading = false;
                if (rc == 0) {
                    self->m_downloadProgress = 1.0;
                    self->setDownloadStatus(VersionInfoBackend::tr("Запуск установки…"));
                    self->installDownloadedFile(self->m_downloadFilePath);
                    return;
                }
                QFile::remove(self->m_downloadFilePath);
                self->m_downloadProgress = 0.0;
                if (rc == -2)
                    self->setDownloadStatus(VersionInfoBackend::tr("Загрузка отменена."));
                else
                    self->setDownloadStatus(
                        VersionInfoBackend::tr("Ошибка загрузки. Откройте страницу релизов вручную."));
            },
            Qt::QueuedConnection);
    });
}

// static — вызывается из Rust на воркер-потоке на каждый чанк. Постит прогресс в
// GUI (queued) и читает флаг отмены. Возврат 0 => Rust прервёт загрузку.
int VersionInfoBackend::downloadProgressCallback(uint64_t received, uint64_t total, void *userData)
{
    auto *self = static_cast<VersionInfoBackend *>(userData);
    if (!self) return 0;
    const double progress = total > 0 ? double(received) / double(total) : 0.0;
    QMetaObject::invokeMethod(
        self,
        [self, progress, total]() {
            self->m_downloadProgress = progress;
            self->m_downloadStatus =
                total > 0 ? VersionInfoBackend::tr("Скачивание… %1%").arg(int(progress * 100))
                          : VersionInfoBackend::tr("Скачивание…");
            emit self->downloadChanged();
        },
        Qt::QueuedConnection);
    return self->m_cancelRequested.load() ? 0 : 1;
}

void VersionInfoBackend::cancelDownload()
{
    m_cancelRequested.store(true);  // progress-колбэк вернёт 0 → Rust прервёт загрузку
}

void VersionInfoBackend::installDownloadedFile(const QString &filePath)
{
#if defined(Q_OS_ANDROID)
    // Системный диалог установки APK: Java-хелпер строит FileProvider-URI +
    // Intent(ACTION_VIEW, mime application/vnd.android.package-archive).
    QJniObject jPath   = QJniObject::fromString(filePath);
    QJniObject context = QNativeInterface::QAndroidApplication::context();
    QJniObject::callStaticMethod<void>(
        "app/paranoia/client/ParanoiaAndroidUtils", "installApk",
        "(Landroid/content/Context;Ljava/lang/String;)V",
        context.object(), jPath.object());
    setDownloadStatus(tr("Открыт системный установщик."));
#elif defined(Q_OS_LINUX)
    // pkexec dpkg -i <file> — графический запрос пароля администратора (polkit).
    const bool started = QProcess::startDetached(
        QStringLiteral("pkexec"), {QStringLiteral("dpkg"), QStringLiteral("-i"), filePath});
    setDownloadStatus(started
                          ? tr("Запущена установка — введите пароль администратора.")
                          : tr("Не удалось запустить pkexec. Установите вручную: %1").arg(filePath));
#elif defined(Q_OS_WIN)
    // Запуск установщика (IFW).
    const bool started = QProcess::startDetached(filePath, {});
    setDownloadStatus(started ? tr("Запущен установщик.")
                              : tr("Не удалось запустить установщик: %1").arg(filePath));
#else
    openUrlExternally(QUrl::fromLocalFile(filePath).toString());
#endif
}
