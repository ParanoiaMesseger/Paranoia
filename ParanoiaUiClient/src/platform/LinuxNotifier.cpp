#include "LinuxNotifier.hpp"

#if defined(PARANOIA_HAS_QT_DBUS)
#include <QDBusConnection>
#include <QDBusInterface>
#include <QDBusReply>
#include <QStringList>
#include <QVariantMap>

namespace
{
    const char *kService   = "org.freedesktop.Notifications";
    const char *kPath      = "/org/freedesktop/Notifications";
    const char *kInterface = "org.freedesktop.Notifications";
}
#endif

LinuxNotifier::LinuxNotifier(QObject *parent) : QObject(parent)
{
#if defined(PARANOIA_HAS_QT_DBUS)
    if (!QDBusConnection::sessionBus().isConnected()) return;
    QDBusInterface iface(kService, kPath, kInterface, QDBusConnection::sessionBus());
    if (!iface.isValid()) return;
    m_available = true;
#endif
}

bool LinuxNotifier::isAvailable() const { return m_available; }

bool LinuxNotifier::showMessageCount(quint64 count)
{
    if (!m_available || count == 0) return false;
#if defined(PARANOIA_HAS_QT_DBUS)
    QDBusInterface iface(kService, kPath, kInterface, QDBusConnection::sessionBus());
    if (!iface.isValid()) return false;
    // Передаём текущий id как replaces_id — daemon обновит существующую карточку
    // вместо создания новой. Так шторка не пухнет от повторных опросов.
    const QString summary = QStringLiteral("Paranoia");
    const QString body    = LinuxNotifier::tr("Новых сообщений: %1").arg(count);
    QDBusReply<uint> reply = iface.call(QStringLiteral("Notify"), QStringLiteral("Paranoia"),
                                        static_cast<uint>(m_currentId), QStringLiteral("app.paranoia.client"),
                                        summary, body, QStringList(), QVariantMap(), 5000);
    if (!reply.isValid()) return false;
    m_currentId = reply.value();
    return true;
#else
    return false;
#endif
}

void LinuxNotifier::closeCurrent()
{
    if (!m_available || m_currentId == 0) return;
#if defined(PARANOIA_HAS_QT_DBUS)
    QDBusInterface iface(kService, kPath, kInterface, QDBusConnection::sessionBus());
    if (!iface.isValid()) {
        m_currentId = 0;
        return;
    }
    iface.call(QStringLiteral("CloseNotification"), m_currentId);
    m_currentId = 0;
#endif
}
