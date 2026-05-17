#pragma once

#include <QObject>
#include <QString>

class QNetworkAccessManager;

class VersionInfoBackend : public QObject
{
    Q_OBJECT

    Q_PROPERTY(bool updateCheckInProgress READ updateCheckInProgress NOTIFY updateCheckChanged)
    Q_PROPERTY(bool updateAvailable READ updateAvailable NOTIFY updateCheckChanged)
    Q_PROPERTY(QString latestVersion READ latestVersion NOTIFY updateCheckChanged)
    Q_PROPERTY(QString updateStatus READ updateStatus NOTIFY updateCheckChanged)
    Q_PROPERTY(QString releasePageUrl READ releasePageUrl CONSTANT)
    Q_PROPERTY(QString downloadUrl READ downloadUrl NOTIFY updateCheckChanged)

public:
    explicit VersionInfoBackend(QObject *parent = nullptr);
    ~VersionInfoBackend() override;

    bool updateCheckInProgress() const;
    bool updateAvailable() const;
    QString latestVersion() const;
    QString updateStatus() const;
    QString releasePageUrl() const;
    QString downloadUrl() const;

    Q_INVOKABLE void checkForUpdates();
    Q_INVOKABLE void openDownloadUrl();
    Q_INVOKABLE void openReleasePage();

signals:
    void updateCheckChanged();

private:
    void openUrlExternally(const QString &url);

    QNetworkAccessManager *m_updateNetwork = nullptr;
    bool m_updateCheckInProgress           = false;
    bool m_updateAvailable                 = false;
    QString m_latestVersion;
    QString m_updateStatus;
    QString m_downloadUrl;
};
