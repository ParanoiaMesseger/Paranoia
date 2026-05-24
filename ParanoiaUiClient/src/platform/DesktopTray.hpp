#pragma once
#include <QObject>
class QQmlApplicationEngine;

#if PARANOIA_DESKTOP_TRAY
#include <QCoreApplication>
#include <QSystemTrayIcon>
#include <QMenu>
#include <QAction>
#endif

#if defined(OS_LINUX)
#include "platform/LinuxNotifier.hpp"
#endif

class DesktopTray : public QObject
{
    Q_OBJECT
public:
    static bool desktopTrayEnabled();
    DesktopTray(QQmlApplicationEngine &engine);
public slots:
    void notificationAvailable(quint64 count);
    void clearAccumulatedNotifications();
#if PARANOIA_DESKTOP_TRAY
    void showWindow();

private:
    QSystemTrayIcon tray_;
    QMenu trayMenu_;
    QAction showAction_;
    QAction quitAction_;
    QQmlApplicationEngine &engine_;
#if defined(OS_LINUX)
    LinuxNotifier linuxNotifier_;
#endif
#endif
};
