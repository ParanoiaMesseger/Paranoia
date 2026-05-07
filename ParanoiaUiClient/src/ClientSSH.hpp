#pragma once

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
using SshSocket = SOCKET;
#else
using SshSocket = int;
#endif

#include <QString>
#include <QThread>

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
    void runScript(QByteArray scriptContent);
    void disconnectFromHost();

signals:
    void connected();
    void disconnected();
    void connectionError(const QString &reason);
    void scriptFinished(int exitCode);
    void scriptError(const QString &reason);

private:
    bool waitSocket();
    void cleanup();

    void *session_  = nullptr; // LIBSSH2_SESSION*
    SshSocket sock_ = static_cast<SshSocket>(-1);
    bool connected_ = false;
#if defined(_WIN32)
    bool winsockReady_ = false;
#endif
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
    void runScriptByPath(const QString &localScriptPath);
    void runScript(QByteArray scriptContent);
    void disconnectFromHost();

signals:
    void connected();
    void disconnected();
    void connectionError(const QString &reason);
    void scriptFinished(int exitCode);
    void scriptError(const QString &reason);

    // Внутренние сигналы → Worker (QueuedConnection)
    void _connectRequested(const SshConnectionParams &params);
    void _runScriptRequested(QByteArray scriptContent);
    void _disconnectRequested();

private:
    QThread *thread_;
    SshWorker *worker_;
};
