#pragma once

#include <QObject>
#include <QString>
#include <QQmlEngine>

class InstallServerBackend : public QObject
{
    Q_OBJECT
    QML_ELEMENT

public:
    explicit InstallServerBackend(QObject *parent = nullptr);

    // ── Статусы шагов (совпадают с QML: 0=pending 1=running 2=done 3=error) ──
    enum StepStatus { Pending = 0, Running = 1, Done = 2, Error = 3 };
    Q_ENUM(StepStatus)

    // ── Индексы шагов ────────────────────────────────────────────────────────
    enum Step {
        StepGenerateKeys   = 0,
        StepSshConnect     = 1,
        StepCreateConfig   = 2,
        StepInstallNginx   = 3,
        StepGetCert        = 4,
        StepConfigureNginx = 5,
        StepDownloadServer = 6,
        StepSystemdService = 7,
        StepStartServer    = 8,
        StepVerifyServer   = 9,
        StepRegisterServer = 10,
        StepCount          = 11
    };
    Q_ENUM(Step)

public slots:
    // ── Вызывается из QML при нажатии «Установить» ───────────────────────────
    void install(const QString &domain, const QString &ip, const QString &username, const QString &password, int port);

    // ── Вызывается из QML при отмене (если добавите кнопку) ─────────────────
    void cancel();

signals:
    // ── Прогресс: статус конкретного шага изменился ──────────────────────────
    void stepStatusChanged(int step, int status);

    // ── Установка завершена успешно ──────────────────────────────────────────
    void installFinished(const QString &domain);

    // ── Ошибка (шаг + человекочитаемое сообщение) ───────────────────────────
    void installError(int step, const QString &message);

private:
    void setStep(Step step, StepStatus status);

    QString m_domain;
    QString m_ip;
    QString m_username;
    QString m_password;
    int m_port     = 1455;
    bool m_running = false;
};
