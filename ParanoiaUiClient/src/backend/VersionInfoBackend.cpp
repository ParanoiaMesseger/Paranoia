#include "VersionInfoBackend.hpp"

#include <QCoreApplication>
#include <QDesktopServices>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QStringList>
#include <QSysInfo>
#include <QUrl>
#include <QVersionNumber>

namespace
{
    constexpr auto kGitLabBaseUrl  = "https://github.com";
    constexpr auto kReleasePageUrl = "https://github.com/ParanoiaMesseger/Paranoia/-/releases";
    constexpr auto kLatestReleaseApiUrl =
        "https://github.com/api/v4/projects/ParanoiaMesseger%2FParanoia/releases/permalink/latest";

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

    QString absoluteGitLabUrl(const QString &rawUrl)
    {
        const QUrl url(rawUrl.trimmed());
        if (!url.isValid()) return {};
        if (url.isRelative()) return QUrl(QString::fromLatin1(kGitLabBaseUrl)).resolved(url).toString();
        return url.toString();
    }

    QString selectDownloadUrl(const QJsonObject &release)
    {
        const QJsonArray links =
            release.value(QStringLiteral("assets")).toObject().value(QStringLiteral("links")).toArray();
        const QStringList preferredNames = preferredUpdateAssetNames();
        QString fallback;
        for (const auto &linkValue : links) {
            const QJsonObject link = linkValue.toObject();
            const QString name     = link.value(QStringLiteral("name")).toString();
            const QString url      = absoluteGitLabUrl(
                link.value(QStringLiteral("direct_asset_url")).toString(link.value(QStringLiteral("url")).toString()));
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
    m_updateNetwork = new QNetworkAccessManager(this);
}

VersionInfoBackend::~VersionInfoBackend() = default;

bool VersionInfoBackend::updateCheckInProgress() const { return m_updateCheckInProgress; }

bool VersionInfoBackend::updateAvailable() const { return m_updateAvailable; }

QString VersionInfoBackend::latestVersion() const { return m_latestVersion; }

QString VersionInfoBackend::updateStatus() const { return m_updateStatus; }

QString VersionInfoBackend::releasePageUrl() const { return QString::fromLatin1(kReleasePageUrl); }

QString VersionInfoBackend::downloadUrl() const { return m_downloadUrl; }

void VersionInfoBackend::checkForUpdates()
{
    if (m_updateCheckInProgress || !m_updateNetwork) return;
    m_updateCheckInProgress = true;
    m_updateAvailable       = false;
    m_updateStatus          = QStringLiteral("Проверка обновлений…");
    m_downloadUrl.clear();
    emit updateCheckChanged();

    QNetworkRequest request{QUrl(QString::fromLatin1(kLatestReleaseApiUrl))};
    request.setHeader(QNetworkRequest::UserAgentHeader,
                      QStringLiteral("Paranoia/%1").arg(QCoreApplication::applicationVersion()));
    auto *reply = m_updateNetwork->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        m_updateCheckInProgress = false;

        const int httpStatus = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (reply->error() != QNetworkReply::NoError || (httpStatus != 0 && (httpStatus < 200 || httpStatus >= 300))) {
            m_updateAvailable = false;
            m_updateStatus = QStringLiteral("Не удалось проверить обновления. Откройте страницу релизов вручную.");
            m_downloadUrl = QString::fromLatin1(kReleasePageUrl);
            emit updateCheckChanged();
            return;
        }

        QJsonParseError parseError;
        const QJsonDocument doc = QJsonDocument::fromJson(reply->readAll(), &parseError);
        if (parseError.error != QJsonParseError::NoError || !doc.isObject()) {
            m_updateAvailable = false;
            m_updateStatus = QStringLiteral("GitLab вернул некорректный ответ о релизе.");
            m_downloadUrl  = QString::fromLatin1(kReleasePageUrl);
            emit updateCheckChanged();
            return;
        }

        const QJsonObject release = doc.object();
        m_latestVersion           = release.value(QStringLiteral("tag_name")).toString();
        if (m_latestVersion.isEmpty()) {
            m_updateAvailable = false;
            m_updateStatus    = QStringLiteral("В последнем релизе не указана версия.");
            m_downloadUrl     = QString::fromLatin1(kReleasePageUrl);
            emit updateCheckChanged();
            return;
        }

        m_updateAvailable = isRemoteVersionNewer(m_latestVersion, QCoreApplication::applicationVersion());
        m_downloadUrl     = m_updateAvailable ? selectDownloadUrl(release) : QString::fromLatin1(kReleasePageUrl);
        m_updateStatus =
            m_updateAvailable
                ? QStringLiteral("Доступна новая версия %1.").arg(m_latestVersion)
                : QStringLiteral("Установлена актуальная версия %1.").arg(QCoreApplication::applicationVersion());
        emit updateCheckChanged();
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
