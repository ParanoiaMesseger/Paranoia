#include "InstallServerBackend.h"
#include "ClientSSH.hpp"
#include <QDebug>
#include <cstdint>
#include <unistd.h>
#include <QFile>
#include <QFileInfo>

InstallServerBackend::InstallServerBackend(QObject *parent) : QObject{parent}
{

    connect(&ssh, &ClientSSH::connected, this, &InstallServerBackend::on_connected);
    connect(&ssh, &ClientSSH::disconnected, this, &InstallServerBackend::on_disconnected);
    connect(&ssh, &ClientSSH::connectionError, this, &InstallServerBackend::on_connectionError);
    connect(&ssh, &ClientSSH::scriptStarted, this, &InstallServerBackend::on_scriptStarted);
    connect(&ssh, &ClientSSH::scriptOutput, this, &InstallServerBackend::on_scriptOutput);
    connect(&ssh, &ClientSSH::scriptFinished, this, &InstallServerBackend::on_scriptFinished);
    connect(&ssh, &ClientSSH::scriptError, this, &InstallServerBackend::on_scriptError);
}

/*

AdminKeys                                           "Генерация ключей администратора",
ConnectSSH                                          "Подключение по SSH",
ssh.runScript(":/CreateConfig.sh")         "Создание /opt/Paranoia и конфигурации",
ssh.runScript(":/InstallNginx.sh")                  "Установка nginx",
ssh.runScript(":/GetCert.sh")                      "Получение TLS-сертификата",
ssh.runScript(":/ConfigureNginx.sh")        "Настройка nginx → Paranoia",
ssh.runScript(":/DownloadServer.sh")         "Загрузка paranoia-server",
ssh.runScript(":/SystemdService.sh")        "Регистрация systemd-сервиса",
ssh.runScript(":/StartServer.sh")                     "Запуск сервера",
CheckConnection                                     "Проверка соединения",
AddServerInList                                     "Добавление сервера в список"
*/

void InstallServerBackend::install(const QString &domain, const QString &ip, const QString &username,
                                   const QString &password, int port)
{
    if (m_running) return;

    m_running  = true;
    m_domain   = domain;
    m_ip       = ip;
    m_username = username;
    m_password = password;
    m_port     = port;

    // Сброс всех шагов в Pending
    for (int i = 0; i < StepCount; ++i) setStep(static_cast<Step>(i), Pending);

    setStep(Step::StepSshConnect, Running);
    ssh.connectToHost({
        .host      = ip,
        .port      = (uint16_t)port,
        .username  = username,
        .password  = password,
        .timeoutMs = 4000,
    });
}

void InstallServerBackend::cancel()
{
    if (!m_running) return;
    ssh.disconnectFromHost();
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
    QByteArray scriptContent = ssh.getScriptContent(":/CreateConfig.sh");
    if (scriptContent.isEmpty()) return;
    scriptContent.replace(QByteArray("{ADMIN_KEY}"), public_admin_key.toUtf8());
    ssh.runScript(scriptContent, ":/CreateConfig.sh");
}

void InstallServerBackend::on_disconnected() {}

void InstallServerBackend::on_connectionError(const QString &reason)
{
    setStep(StepSshConnect, Error);
    installError(StepSshConnect, reason);
}

void InstallServerBackend::on_scriptStarted(const QString &scriptPath) {}

void InstallServerBackend::on_scriptOutput(const QString &text) {}

void InstallServerBackend::on_scriptFinished(int exitCode)
{
    setStep(currentStep, Done);
    currentStep = static_cast<Step>(static_cast<int>(currentStep) + 1);
    setStep(currentStep, Running);
    switch (currentStep) {
        case StepInstallNginx: ssh.runScript(":/InstallNginx.sh"); break;
        case StepGetCert: ssh.runScript(":/GetCert.sh"); break;
        case StepConfigureNginx: ssh.runScript(":/ConfigureNginx.sh"); break;
        case StepDownloadServer: ssh.runScript(":/DownloadServer.sh"); break;
        case StepSystemdService: ssh.runScript(":/SystemdService.sh"); break;
        case StepStartServer: ssh.runScript(":/StartServer.sh"); break;
        case StepVerifyServer: break;
        case StepRegisterServer: break;
        case StepCreateConfig:
        case StepSshConnect:
        case StepGenerateKeys:
        case StepCount: break;
    }
}

void InstallServerBackend::on_scriptError(const QString &reason) { installError(currentStep, reason); }
