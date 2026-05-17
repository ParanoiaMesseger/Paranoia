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
      showAction_(QStringLiteral("Открыть Paranoia"), &trayMenu_), quitAction_(QStringLiteral("Выйти"), &trayMenu_)
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
    if (tray_.isVisible())
        tray_.showMessage(QStringLiteral("Paranoia"), QStringLiteral("Новых сообщений: %1").arg(count),
                          QSystemTrayIcon::Information, 10000);
#else
    Q_UNUSED(count);
#endif
}
