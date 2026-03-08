#include "ClientSSH.hpp"

#include <iostream>
#include <libssh2.h>
#include <qlogging.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/select.h>

#include <QFile>
#include <QFileInfo>
#include <QHostAddress>
#include <QRegularExpression>
#include <QMetaType>

#define BLOCK(__block__) {__block__}
#define ERR(err_) BLOCK(err = err_; return false;)
#define ERR_SCRIPT(err_) BLOCK(emit scriptError(err_); return;)
#define ERR_CONNECT(err_) BLOCK(emit connectionError(err_); return;)

Q_DECLARE_METATYPE(SshConnectionParams)

ClientSSH::ClientSSH(QObject *parent) : QObject(parent), thread_(new QThread(this)), worker_(new SshWorker)
{
    qRegisterMetaType<SshConnectionParams>("SshConnectionParams");
    worker_->moveToThread(thread_);

    // Worker → наружу (auto QueuedConnection т.к. разные потоки)
    connect(worker_, &SshWorker::connected, this, &ClientSSH::connected);
    connect(worker_, &SshWorker::disconnected, this, &ClientSSH::disconnected);
    connect(worker_, &SshWorker::connectionError, this, &ClientSSH::connectionError);
    connect(worker_, &SshWorker::scriptStarted, this, &ClientSSH::scriptStarted);
    connect(worker_, &SshWorker::scriptOutput, this, &ClientSSH::scriptOutput);
    connect(worker_, &SshWorker::scriptFinished, this, &ClientSSH::scriptFinished);
    connect(worker_, &SshWorker::scriptError, this, &ClientSSH::scriptError);

    // Наружу → Worker (QueuedConnection)
    connect(this, &ClientSSH::_connectRequested, worker_, &SshWorker::connectToHost);
    connect(this, &ClientSSH::_runScriptRequested, worker_, &SshWorker::runScript);
    connect(this, &ClientSSH::_disconnectRequested, worker_, &SshWorker::disconnectFromHost);

    // Чистый снос worker при завершении потока
    connect(thread_, &QThread::finished, worker_, &QObject::deleteLater);

    thread_->start();
}

ClientSSH::~ClientSSH()
{
    thread_->quit();
    thread_->wait(3000);
}

// ── Статическая валидация ────────────────────────────────────────────────────

bool ClientSSH::validateParams(const SshConnectionParams &p, QString &err)
{
    if (p.host.trimmed().isEmpty()) ERR("Host не задан");
    if (p.username.trimmed().isEmpty()) ERR("Username не задан");
    if (p.password.isEmpty()) ERR("Не указан ни пароль");
    return true;
}

// ── Слоты-делегаты ──────────────────────────────────────────────────────────

void ClientSSH::connectToHost(const SshConnectionParams &params)
{
    QString err;
    if (!validateParams(params, err)) ERR_CONNECT("Ошибка параметров: " + err);
    emit _connectRequested(params);
}

QByteArray ClientSSH::getScriptContent(const QString &path)
{
    if (path.trimmed().isEmpty()) BLOCK(emit scriptError("Путь к скрипту не задан"); return {};);
    if (!QFileInfo::exists(path)) BLOCK(emit scriptError(QString("Скрипт не найден: %1").arg(path)); return {};);
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text))
        BLOCK(emit scriptError(QString("Не удалось открыть скрипт: %1").arg(path)); return {};);
    return f.readAll();
}

void ClientSSH::runScript(QByteArray scriptContent, const QString &localScriptPath)
{
    emit _runScriptRequested(scriptContent, localScriptPath);
}

void ClientSSH::runScript(const QString &path)
{
    auto contnet = getScriptContent(path);
    if (contnet.isEmpty()) return;
    emit _runScriptRequested(contnet, path);
}

void ClientSSH::disconnectFromHost() { emit _disconnectRequested(); }

SshWorker::SshWorker(QObject *parent) : QObject(parent) { libssh2_init(0); }

SshWorker::~SshWorker()
{
    cleanup();
    libssh2_exit();
}

bool SshWorker::waitSocket()
{
    int dir = libssh2_session_block_directions(static_cast<LIBSSH2_SESSION *>(session_));
    if (!dir) return true;

    fd_set rfd, wfd;
    FD_ZERO(&rfd);
    FD_ZERO(&wfd);
    if (dir & LIBSSH2_SESSION_BLOCK_INBOUND) FD_SET(sock_, &rfd);
    if (dir & LIBSSH2_SESSION_BLOCK_OUTBOUND) FD_SET(sock_, &wfd);

    timeval tv{10, 0}; // 10 сек максимум на одно ожидание
    return select(sock_ + 1, &rfd, &wfd, nullptr, &tv) > 0;
}

void SshWorker::connectToHost(const SshConnectionParams &params)
{
    cleanup();
    qDebug() << "connectToHost : " << params.host;
    params_ = params;

    addrinfo hints{}, *res = nullptr;
    hints.ai_family   = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    QString portStr   = QString::number(params.port);

    if (getaddrinfo(params.host.toUtf8(), portStr.toUtf8(), &hints, &res) != 0)
        ERR_CONNECT(QString("Не удалось разрешить хост: %1").arg(params.host));
    sock_ = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (sock_ < 0) {
        freeaddrinfo(res);
        ERR_CONNECT("Ошибка создания сокета");
    }

    timeval tv{params.timeoutMs / 1000, (params.timeoutMs % 1000) * 1000};
    setsockopt(sock_, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    setsockopt(sock_, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    if (::connect(sock_, res->ai_addr, res->ai_addrlen) != 0) {
        freeaddrinfo(res);
        ERR_CONNECT(QString("TCP connect failed: %1:%2 — %3").arg(params.host).arg(params.port).arg(strerror(errno)));
    }
    freeaddrinfo(res);

    auto *sess = libssh2_session_init();
    session_   = sess;
    libssh2_session_set_timeout(sess, params.timeoutMs);
    qDebug() << "libssh2_session_handshake";
    if (libssh2_session_handshake(sess, sock_) != 0) {
        char *msg;
        libssh2_session_last_error(sess, &msg, nullptr, 0);
        cleanup();
        ERR_CONNECT(QString("SSH handshake failed: %1").arg(msg));
    }
    qDebug() << "libssh2_userauth_password";
    int rc = libssh2_userauth_password(sess, params.username.toUtf8(), params.password.toUtf8());
    if (rc != 0) {
        char *msg;
        libssh2_session_last_error(sess, &msg, nullptr, 0);
        cleanup();
        ERR_CONNECT(QString("Аутентификация не прошла: %1").arg(msg));
    }
    qDebug() << "Connected";
    connected_ = true;
    emit connected();
}

void SshWorker::runScript(QByteArray scriptContent, const QString &localScriptPath)
{
    std::cout << "RUN>" << scriptContent.toStdString();
    std::cout.flush();
    if (!connected_ || !session_) ERR_SCRIPT("Нет активного SSH-соединения");

    auto *sess = static_cast<LIBSSH2_SESSION *>(session_);

    LIBSSH2_CHANNEL *ch = nullptr;
    while (!ch) {
        ch = libssh2_channel_open_session(sess);
        if (!ch) {
            int err = libssh2_session_last_errno(sess);
            if (err == LIBSSH2_ERROR_EAGAIN) {
                waitSocket();
                continue;
            }
            char *msg;
            libssh2_session_last_error(sess, &msg, nullptr, 0);
            ERR_SCRIPT(QString("Не удалось открыть канал: %1").arg(msg));
        }
    }

    libssh2_channel_handle_extended_data2(ch, LIBSSH2_CHANNEL_EXTENDED_DATA_MERGE);

    const char *cmd = "bash -s";
    int rc;
    while ((rc = libssh2_channel_exec(ch, cmd)) == LIBSSH2_ERROR_EAGAIN) waitSocket();

    if (rc != 0) {
        char *msg;
        libssh2_session_last_error(sess, &msg, nullptr, 0);
        libssh2_channel_free(ch);
        ERR_SCRIPT(QString("exec failed: %1").arg(msg));
    }

    qint64 sent = 0;
    while (sent < scriptContent.size()) {
        rc = libssh2_channel_write(ch, scriptContent.constData() + sent,
                                   static_cast<size_t>(scriptContent.size() - sent));
        if (rc == LIBSSH2_ERROR_EAGAIN) {
            waitSocket();
            continue;
        }
        if (rc < 0) {
            char *msg;
            libssh2_session_last_error(sess, &msg, nullptr, 0);
            libssh2_channel_free(ch);
            ERR_SCRIPT(QString("Ошибка записи stdin: %1").arg(msg));
        }
        sent += rc;
    }
    libssh2_channel_send_eof(ch);

    emit scriptStarted(localScriptPath);

    char buf[4096];
    while (true) {
        rc = libssh2_channel_read(ch, buf, sizeof(buf));
        if (rc == LIBSSH2_ERROR_EAGAIN) {
            waitSocket();
            continue;
        }
        if (rc <= 0) break;
        std::cout << "$>" << QString::fromUtf8(buf, rc).toStdString();
        std::cout.flush();
        emit scriptOutput(QString::fromUtf8(buf, rc));
    }

    libssh2_channel_wait_eof(ch);
    libssh2_channel_close(ch);
    libssh2_channel_wait_closed(ch);

    int exitCode = libssh2_channel_get_exit_status(ch);
    libssh2_channel_free(ch);

    if (exitCode != 0) emit scriptError(QString("Скрипт завершился с кодом %1").arg(exitCode));
    emit scriptFinished(exitCode);
}

void SshWorker::disconnectFromHost()
{
    cleanup();
    emit disconnected();
}

void SshWorker::cleanup()
{
    if (session_) {
        auto *sess = static_cast<LIBSSH2_SESSION *>(session_);
        libssh2_session_disconnect(sess, "Normal shutdown");
        libssh2_session_free(sess);
        session_ = nullptr;
    }
    if (sock_ >= 0) {
        ::close(sock_);
        sock_ = -1;
    }
    connected_ = false;
}
