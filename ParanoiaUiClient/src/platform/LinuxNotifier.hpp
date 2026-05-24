#pragma once

#include <QObject>
#include <QString>

// Linux-only D-Bus обёртка над org.freedesktop.Notifications. Используется в
// DesktopTray вместо QSystemTrayIcon::showMessage, потому что нативный путь
// (StatusNotifierItem) не отдаёт ID карточки — а без ID нельзя вызвать
// CloseNotification, когда приложение выходит на передний план. Без этого
// карточки накапливаются в шторке KDE/GNOME (см. NotificationsPolicy.md).
//
// При отсутствии работающего D-Bus сервиса notifications instance остаётся в
// disabled-состоянии; вызывающая сторона должна откатиться на fallback
// (QSystemTrayIcon::showMessage), который хотя бы показывает popup.
class LinuxNotifier : public QObject
{
    Q_OBJECT
public:
    explicit LinuxNotifier(QObject *parent = nullptr);

    // Доступна ли реализация: на dev-машине без сессионного D-Bus вернёт false.
    bool isAvailable() const;

    // Показывает (или заменяет) уведомление о новых сообщениях. Возвращает true,
    // если notification удалось отправить (вызывающая сторона должна не
    // дублировать через системный tray).
    bool showMessageCount(quint64 count);

    // Гасит текущее уведомление, если оно ещё в шторке. Вызывается при выходе
    // приложения на передний план.
    void closeCurrent();

private:
    bool m_available           = false;
    unsigned int m_currentId   = 0;
};
