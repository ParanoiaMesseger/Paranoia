#pragma once
#include <QObject>
class QQmlApplicationEngine;

#if PARANOIA_DESKTOP_TRAY
#include <QCoreApplication>
#include <QSystemTrayIcon>
#include <QMenu>
#include <QAction>
#endif

class DesktopTray : public QObject
{
    Q_OBJECT
public:
    static bool desktopTrayEnabled();
    DesktopTray(QQmlApplicationEngine &engine);
public slots:
    void notificationAvailable(quint64 count);
#if PARANOIA_DESKTOP_TRAY
    void showWindow();

private:
    QSystemTrayIcon tray_;
    QMenu trayMenu_;
    QAction showAction_;
    QAction quitAction_;
    QQmlApplicationEngine &engine_;
#endif
};