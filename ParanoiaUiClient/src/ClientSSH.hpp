#pragma once
#include <QObject>
#include <QString>
#include <QThread>
#include <qstringview.h>

struct SshConnectionParams {
    QString host;
    uint16_t port = 22;
    QString username;
    QString password;
    int timeoutMs = 10000;
};

class SshWorker : public QObject
{
    Q_OBJECT

public:
    explicit SshWorker(QObject *parent = nullptr);
    ~SshWorker() override;

public slots:
    void connectToHost(const SshConnectionParams &params);
    void runScript(QByteArray scriptContent, const QString &localScriptPath);
    void disconnectFromHost();

signals:
    void connected();
    void disconnected();
    void connectionError(const QString &reason);
    void scriptStarted(const QString &scriptPath);
    void scriptOutput(const QString &text);
    void scriptFinished(int exitCode);
    void scriptError(const QString &reason);

private:
    bool waitSocket();
    void cleanup();

    void *session_  = nullptr; // LIBSSH2_SESSION*
    int sock_       = -1;
    bool connected_ = false;
    SshConnectionParams params_;
};

class ClientSSH : public QObject
{
    Q_OBJECT

public:
    explicit ClientSSH(QObject *parent = nullptr);
    ~ClientSSH() override;

    // Статическая валидация параметров (без сетевого обращения)
    static bool validateParams(const SshConnectionParams &p, QString &outError);
    QByteArray getScriptContent(const QString &localScriptPath);
public slots:
    void connectToHost(const SshConnectionParams &params);
    void runScript(const QString &localScriptPath);
    void runScript(QByteArray scriptContent, const QString &localScriptPath);
    void disconnectFromHost();

signals:
    void connected();
    void disconnected();
    void connectionError(const QString &reason);
    void scriptStarted(const QString &scriptPath);
    void scriptOutput(const QString &text);
    void scriptFinished(int exitCode);
    void scriptError(const QString &reason);

    // Внутренние сигналы → Worker (QueuedConnection)
    void _connectRequested(const SshConnectionParams &params);
    void _runScriptRequested(QByteArray scriptContent, const QString &path);
    void _disconnectRequested();

private:
    QThread *thread_;
    SshWorker *worker_;
};
