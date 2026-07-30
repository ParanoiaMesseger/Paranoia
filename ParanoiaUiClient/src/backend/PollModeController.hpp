#pragma once

#include <QObject>
#include <QString>
#include <QVariantList>

// Режим фонового опроса уведомлений.
// "normal" — штатный (60 с + long-poll 15 с + call-poll 12 с)
// "battery_saving" — экономный (300 с ±30% jitter, без long-poll и call-poll)
// "off" — фоновый сервис остановлен, уведомления только при открытом приложении
class PollModeController : public QObject
{
    Q_OBJECT

    Q_PROPERTY(QString pollMode READ pollMode NOTIFY pollModeChanged)
    // NOTIFY, не CONSTANT: подписи сегментов идут через tr() и должны
    // обновляться при горячей смене языка (сигнал эмитится из main.cpp по
    // LanguageController::languageChanged).
    Q_PROPERTY(QVariantList availablePollModes READ availablePollModes NOTIFY availablePollModesChanged)

public:
    explicit PollModeController(QObject *parent = nullptr);

    QString pollMode() const { return m_pollMode; }
    QVariantList availablePollModes() const;

    Q_INVOKABLE void setPollMode(const QString &mode);

signals:
    void pollModeChanged();
    void availablePollModesChanged();

private:
    void persist(const QString &mode);

    QString m_pollMode;
};
