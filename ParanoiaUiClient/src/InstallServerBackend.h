#pragma once

#include "ClientSSH.hpp"
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
        StepGenerateKeys   = 0,  /// Генерация ключей администратора
        StepSshConnect     = 1,  /// Подключение по SSH
        StepCreateConfig   = 2,  /// Создание /opt/Paranoia и конфигурации
        StepInstallNginx   = 3,  /// Установка nginx
        StepGetCert        = 4,  /// Получение TLS-сертификата
        StepConfigureNginx = 5,  /// Настройка nginx → Paranoia
        StepDownloadServer = 6,  /// Загрузка paranoia-server
        StepSystemdService = 7,  /// Регистрация systemd-сервиса
        StepStartServer    = 8,  /// Запуск сервера
        StepVerifyServer   = 9,  /// Проверка соединения
        StepRegisterServer = 10, /// Добавление сервера в списо
        StepCount          = 11  ///
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

private slots:
    void on_connected();
    void on_disconnected();
    void on_connectionError(const QString &reason);
    void on_scriptStarted(const QString &scriptPath);
    void on_scriptOutput(const QString &text);
    void on_scriptFinished(int exitCode);
    void on_scriptError(const QString &reason);

private:
    std::pair<QString, QString> genKayPair();
    void setStep(Step step, StepStatus status);

    Step currentStep = StepCount;

    ClientSSH ssh;
    QString m_domain;
    QString m_ip;
    QString m_username;
    QString m_password;
    QString private_admin_key = "private key";
    QString public_admin_key  = "public key";
    int m_port                = 1455;
    bool m_running            = false;
};
