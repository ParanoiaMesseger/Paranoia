#pragma once

#include <QObject>
#include <QString>

#include <atomic>
#include <cstdint>

class VersionInfoBackend : public QObject
{
    Q_OBJECT

    Q_PROPERTY(bool updateCheckInProgress READ updateCheckInProgress NOTIFY updateCheckChanged)
    Q_PROPERTY(bool updateAvailable READ updateAvailable NOTIFY updateCheckChanged)
    Q_PROPERTY(QString latestVersion READ latestVersion NOTIFY updateCheckChanged)
    Q_PROPERTY(QString updateStatus READ updateStatus NOTIFY updateCheckChanged)
    Q_PROPERTY(QString releasePageUrl READ releasePageUrl CONSTANT)
    Q_PROPERTY(QString downloadUrl READ downloadUrl NOTIFY updateCheckChanged)
    // #30 in-app обновление: скачивание + триггер установки по платформе.
    Q_PROPERTY(bool canInstallInApp READ canInstallInApp CONSTANT)
    Q_PROPERTY(bool downloading READ downloading NOTIFY downloadChanged)
    Q_PROPERTY(double downloadProgress READ downloadProgress NOTIFY downloadChanged)
    Q_PROPERTY(QString downloadStatus READ downloadStatus NOTIFY downloadChanged)

public:
    explicit VersionInfoBackend(QObject *parent = nullptr);
    ~VersionInfoBackend() override;

    bool updateCheckInProgress() const;
    bool updateAvailable() const;
    QString latestVersion() const;
    QString updateStatus() const;
    QString releasePageUrl() const;
    QString downloadUrl() const;
    bool canInstallInApp() const;
    bool downloading() const;
    double downloadProgress() const;
    QString downloadStatus() const;

    Q_INVOKABLE void checkForUpdates();
    Q_INVOKABLE void openDownloadUrl();
    Q_INVOKABLE void openReleasePage();
    // #30: скачать артефакт m_downloadUrl и запустить установку штатным для
    // платформы способом. На платформах без in-app установки (mac/iOS) —
    // эквивалентно openDownloadUrl()/переходу в стор.
    Q_INVOKABLE void downloadAndInstall();
    Q_INVOKABLE void cancelDownload();

signals:
    void updateCheckChanged();
    void downloadChanged();

private:
    void openUrlExternally(const QString &url);
    // #37: фолбэк-проверка обновлений по резервному источнику (paranoia.run/
    // artefacts.csv), когда api.github.com недоступен/заблокирован.
    void checkReserveUpdates();
    // #30: запустить установку скачанного файла (платформозависимо).
    void installDownloadedFile(const QString &filePath);
    void setDownloadStatus(const QString &status);
    // Папка под скачанные установочные файлы (отдельная подпапка — чтобы чистить
    // её целиком, не трогая данные приложения).
    QString updateDownloadDir() const;
    // Удалить остаток скачанных установочных файлов (вызывается при старте: после
    // установки апдейта приложение перезапускается новой версией и чистит хвост).
    void cleanupDownloads();
    // Колбэк прогресса для paranoia_http_download (вызывается из Rust на воркере).
    static int downloadProgressCallback(uint64_t received, uint64_t total, void *userData);

    bool m_updateCheckInProgress = false;
    bool m_updateAvailable       = false;
    QString m_latestVersion;
    QString m_updateStatus;
    QString m_downloadUrl;

    bool m_downloading        = false;
    double m_downloadProgress = 0.0;
    QString m_downloadStatus;
    std::atomic<bool> m_cancelRequested{false};
    QString m_downloadFilePath;
};
