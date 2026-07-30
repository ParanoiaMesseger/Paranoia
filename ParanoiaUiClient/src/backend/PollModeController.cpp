#include "PollModeController.hpp"

#include "platform/PlatformNotifications.hpp"

#include <QCoreApplication>
#include <QSettings>
#include <QVariantMap>

namespace {
constexpr auto kSettingsKey = "ui/pollMode";
}

PollModeController::PollModeController(QObject *parent)
    : QObject(parent)
{
    QSettings settings;
    m_pollMode = settings.value(QString::fromLatin1(kSettingsKey),
                                QStringLiteral("normal")).toString();
    if (m_pollMode != QStringLiteral("normal") &&
        m_pollMode != QStringLiteral("battery_saving") &&
        m_pollMode != QStringLiteral("off"))
    {
        m_pollMode = QStringLiteral("normal");
    }
}

QVariantList PollModeController::availablePollModes() const
{
    QVariantList list;
    auto add = [&list](const QString &code, const QString &label, const QString &icon) {
        QVariantMap m;
        m.insert(QStringLiteral("code"), code);
        m.insert(QStringLiteral("label"), label);
        m.insert(QStringLiteral("icon"), icon);
        list.append(m);
    };
    add(QStringLiteral("normal"), tr("60 сек"), QStringLiteral("refresh"));
    add(QStringLiteral("battery_saving"), tr("5 мин"), QStringLiteral("moon"));
    // «—» вместо пустой подписи: строка под глифом резервируется у всех
    // сегментов (симметрия), а совсем пустая выглядит дырой (фидбэк Ивана).
    add(QStringLiteral("off"), QStringLiteral("—"), QStringLiteral("close"));
    return list;
}

void PollModeController::setPollMode(const QString &mode)
{
    QString m = mode;
    if (m != QStringLiteral("normal") && m != QStringLiteral("battery_saving") &&
        m != QStringLiteral("off"))
    {
        return;
    }
    if (m == m_pollMode)
        return;

    m_pollMode = m;
    persist(m);
    // Контроллер — только держатель состояния. Android-сервису режим доезжает
    // персистом (свежий процесс :notifications) и snapshot'ом (живой), а
    // стартом/остановкой фоновой доставки на всех платформах управляет
    // NotificationCoordinator, подписанный на pollModeChanged.
    PlatformNotifications::persistPollMode(m);
    emit pollModeChanged();
}

void PollModeController::persist(const QString &mode)
{
    QSettings settings;
    settings.setValue(QString::fromLatin1(kSettingsKey), mode);
}
