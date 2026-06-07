#include "DesktopTray.hpp"
#include <memory>

#if PARANOIA_DESKTOP_TRAY
#include <QQmlApplicationEngine>
#include <QWindow>
#endif

bool DesktopTray::desktopTrayEnabled()
{
#if PARANOIA_DESKTOP_TRAY
    return QSystemTrayIcon::isSystemTrayAvailable();
#else
    return false;
#endif
}

#if PARANOIA_DESKTOP_TRAY
void DesktopTray::showWindow()
{
    if (engine_.rootObjects().isEmpty()) return;
    if (auto *window = qobject_cast<QWindow *>(engine_.rootObjects().first())) {
        window->show();
        window->raise();
        window->requestActivate();
    }
}
DesktopTray::DesktopTray(QQmlApplicationEngine &engine)
    : engine_(engine), tray_(QIcon(QStringLiteral(":/logo_symbol.svg"))),
      showAction_(DesktopTray::tr("Открыть Paranoia"), &trayMenu_), quitAction_(DesktopTray::tr("Выйти"), &trayMenu_)
{
    trayMenu_.addAction(&showAction_);
    trayMenu_.addSeparator();
    trayMenu_.addAction(&quitAction_);
    tray_.setContextMenu(&trayMenu_);
    connect(&showAction_, &QAction::triggered, this, &DesktopTray::showWindow);
    connect(&quitAction_, &QAction::triggered, qApp, &QCoreApplication::quit);
    connect(&tray_, &QSystemTrayIcon::activated, qApp, [&](QSystemTrayIcon::ActivationReason reason) {
        if (reason == QSystemTrayIcon::Trigger || reason == QSystemTrayIcon::DoubleClick) showWindow();
    });
    if (desktopTrayEnabled()) tray_.show();
}
#else
DesktopTray::DesktopTray(QQmlApplicationEngine &engine) {}
#endif

void DesktopTray::notificationAvailable(quint64 count)
{
#if PARANOIA_DESKTOP_TRAY
#if defined(OS_LINUX)
    // Через D-Bus daemon видит replaces_id и заменяет карточку — шторка
    // не накапливает копии. Tray::showMessage используем только fallback'ом,
    // если сессионный bus недоступен (headless/контейнер).
    if (linuxNotifier_.isAvailable() && linuxNotifier_.showMessageCount(count)) return;
#endif
    if (tray_.isVisible())
        tray_.showMessage(QStringLiteral("Paranoia"), DesktopTray::tr("Новых сообщений: %1").arg(count),
                          QSystemTrayIcon::Information, 10000);
#else
    Q_UNUSED(count);
#endif
}

void DesktopTray::clearAccumulatedNotifications()
{
#if PARANOIA_DESKTOP_TRAY
#if defined(OS_LINUX)
    linuxNotifier_.closeCurrent();
#endif
    // QSystemTrayIcon::showMessage не отдаёт handle — закрыть конкретную
    // карточку нельзя. Полагаемся на timeout (10s) для fallback-пути.
#else
    // ничего не делаем — окружение без tray не показывает баннеров.
#endif
}
