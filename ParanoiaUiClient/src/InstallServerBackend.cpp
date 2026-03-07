#include "InstallServerBackend.h"
#include <QDebug>
#include <unistd.h>
#include <QApplicationStatic>

InstallServerBackend::InstallServerBackend(QObject *parent) : QObject{parent} {}

// ── Точка входа из QML
// ────────────────────────────────────────────────────────
void InstallServerBackend::install(const QString &domain, const QString &ip, const QString &username, const QString &password,
                            int port)
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

    for (int i = 0; i < StepCount; ++i) {
        for (int j = 0; j < 5000; ++j){
            usleep(10);
            qApp->processEvents();
        }
        setStep(static_cast<Step>(i), Running);
        for (int j = 0; j < 5000; ++j){
            usleep(10);
            qApp->processEvents();
        }
        setStep(static_cast<Step>(i), Done);
    }

    emit installFinished("domain.com");

    // TODO: запустить воркер/поток и реализовать шаги

    // Пример последовательности (будет заменена реальной логикой):
    // setStep(StepGenerateKeys, Running);
    // ... generateAdminKeyPair() ...
    // setStep(StepGenerateKeys, Done);
    //
    // setStep(StepSshConnect, Running);
    // ... sshConnect(ip, username, password) ...
    // setStep(StepSshConnect, Done);
    //
    // ... и т.д. для каждого шага ...
    //
    // emit installFinished(m_domain);
}

void InstallServerBackend::cancel()
{
    if (!m_running) return;

    // TODO: прервать воркер
    m_running = false;
}

// ── Вспомогательный метод: обновить шаг и уведомить QML ─────────────────────
void InstallServerBackend::setStep(Step step, StepStatus status)
{
    emit stepStatusChanged(static_cast<int>(step), static_cast<int>(status));
}
