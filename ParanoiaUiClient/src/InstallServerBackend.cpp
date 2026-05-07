#include "InstallServerBackend.h"
#include "ClientSSH.hpp"
#include <QDebug>
#include <memory>
#include <QFileInfo>
#include "adminStorage.hpp"
#include "paranoia_lib.h"

InstallServerBackend::InstallServerBackend(QObject *parent) : QObject{parent}, ssh(nullptr) {}

void InstallServerBackend::install(const QString &domain, const QString &ip, const QString &username,
                                   const QString &password, int port)
{
    if (m_running) return;

    m_running  = true;
    m_domain   = domain;
    m_port     = port;

    // Сброс всех шагов в Pending
    for (int i = 0; i < StepCount; ++i) setStep(static_cast<Step>(i), Pending);

    setStep(Step::StepGenerateKeys, Running);
    auto [private_, public_] = genKayPair();
    private_admin_key        = private_;
    public_admin_key         = public_;
    setStep(Step::StepGenerateKeys, Done);

    setStep(Step::StepSshConnect, Running);
    ssh = std::make_unique<ClientSSH>();
    connect(ssh.get(), &ClientSSH::connected, this, &InstallServerBackend::on_connected);
    connect(ssh.get(), &ClientSSH::disconnected, this, &InstallServerBackend::on_disconnected);
    connect(ssh.get(), &ClientSSH::connectionError, this, &InstallServerBackend::on_connectionError);
    connect(ssh.get(), &ClientSSH::scriptFinished, this, &InstallServerBackend::on_scriptFinished);
    connect(ssh.get(), &ClientSSH::scriptError, this, &InstallServerBackend::on_scriptError);
    ssh->connectToHost({
        .host      = ip,
        .port      = 22,
        .username  = username,
        .password  = password,
        .timeoutMs = 4000,
    });
}

void InstallServerBackend::cancel()
{
    if (!m_running) return;
    ssh->disconnectFromHost();
    m_running = false;
}

void InstallServerBackend::setStep(Step step, StepStatus status)
{
    currentStep = step;
    emit stepStatusChanged(static_cast<int>(step), static_cast<int>(status));
}

void InstallServerBackend::on_connected()
{
    setStep(StepSshConnect, Done);
    setStep(StepCreateConfig, Running);
    QByteArray scriptContent = ssh->getScriptContent(":/CreateConfig.sh");
    if (scriptContent.isEmpty()) return;
    scriptContent.replace(QByteArray("{ADMIN_KEY}"), public_admin_key.toUtf8());
    ssh->runScript(scriptContent);
}

void InstallServerBackend::on_disconnected()
{
    if (!m_running) return;
    setStep(StepSshConnect, Error);
    installError(StepSshConnect, "Соединение ssh разорвано((");
    cancel();
}

void InstallServerBackend::on_connectionError(const QString &reason)
{
    setStep(StepSshConnect, Error);
    installError(StepSshConnect, reason);
    cancel();
}

void InstallServerBackend::on_scriptFinished(int exitCode)
{
    if (exitCode != 0) return;
    setStep(currentStep, Done);
    currentStep = static_cast<Step>(static_cast<int>(currentStep) + 1);
    setStep(currentStep, Running);
    switch (currentStep) {
        case StepInstallNginx: ssh->runScriptByPath(":/InstallNginx.sh"); break;
        case StepGetCert: {
            QByteArray scriptContent = ssh->getScriptContent(":/GetCert.sh");
            scriptContent.replace(QByteArray("{DOMAIN}"), m_domain.toUtf8());
            ssh->runScript(scriptContent);
        } break;
        case StepConfigureNginx: {
            QByteArray scriptContent = ssh->getScriptContent(":/ConfigureNginx.sh");
            scriptContent.replace(QByteArray("{DOMAIN}"), m_domain.toUtf8());
            scriptContent.replace(QByteArray("{PARANOIA_PORT}"), QString::number(m_port).toUtf8());
            ssh->runScript(scriptContent);
        } break;
        case StepDownloadServer: ssh->runScriptByPath(":/DownloadServer.sh"); break;
        case StepSystemdService: {
            QByteArray scriptContent = ssh->getScriptContent(":/SystemdService.sh");
            scriptContent.replace(QByteArray("{DOMAIN}"), m_domain.toUtf8());
            ssh->runScript(scriptContent);
        } break;
        case StepStartServer: ssh->runScriptByPath(":/StartServer.sh"); break;
        case StepVerifyServer: {
            usleep(1000);
            QString url = m_domain;
            if (!url.startsWith("http://") && !url.startsWith("https://")) url = "https://" + url;
            admin::Admin{url, private_admin_key}.regUser("admin", public_admin_key).then(this, [this, url](bool res) {
                if (res) {
                    admin::Admin::admins.push_back({url, private_admin_key});
                    admin::Admin::saveAdmins();
                    on_scriptFinished(0);
                } else {
                    installError(currentStep, "Error on check server.");
                }
            });
        } break;
        case StepRegisterServer: emit installFinished(m_domain); break;
        case StepCreateConfig:
        case StepSshConnect:
        case StepGenerateKeys:
        case StepCount: break;
    }
}

void InstallServerBackend::on_scriptError(const QString &reason)
{
    installError(currentStep, reason);
    cancel();
}

std::pair<QString, QString> InstallServerBackend::genKayPair()
{
    char *secret = nullptr;
    char *pubkey = nullptr;
    paranoia_generate_keypair(&secret, &pubkey);
    QString Secret = QString::fromUtf8(secret);
    QString Pubkey = QString::fromUtf8(pubkey);
    paranoia_free_string(secret);
    paranoia_free_string(pubkey);
    secret = nullptr;
    pubkey = nullptr;
    return {Secret, Pubkey};
}
