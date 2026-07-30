#include "LinuxNotifier.hpp"

#if defined(PARANOIA_HAS_QT_DBUS)
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusPendingCall>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
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
    // Раньше здесь конструировался QDBusInterface — а его конструктор делает
    // СИНХРОННУЮ интроспекцию удалённого объекта по шине (блокировка на старте, 01#17).
    // Достаточно факта живой сессионной шины: если демона нет, async-Notify просто
    // тихо не выполнится (watcher получит invalid reply), без фриза.
    m_available = QDBusConnection::sessionBus().isConnected();
#endif
}

bool LinuxNotifier::isAvailable() const { return m_available; }

bool LinuxNotifier::showMessageCount(quint64 count)
{
    if (!m_available || count == 0) return false;
#if defined(PARANOIA_HAS_QT_DBUS)
    // createMethodCall не интроспектирует; asyncCall не блокирует GUI (раньше
    // iface.call() ждал ответ демона до 25 с — при зависшем демоне фриз UI, 01#17).
    // replaces_id = m_currentId → daemon обновляет карточку, шторка не пухнет.
    QDBusMessage msg = QDBusMessage::createMethodCall(kService, kPath, kInterface, QStringLiteral("Notify"));
    msg << QStringLiteral("Paranoia")                          // app_name
        << static_cast<uint>(m_currentId)                      // replaces_id
        << QStringLiteral("app.paranoia.client")               // app_icon
        << QStringLiteral("Paranoia")                          // summary
        << LinuxNotifier::tr("Новых сообщений: %1").arg(count) // body
        << QStringList()                                       // actions
        << QVariantMap()                                       // hints
        << 5000;                                               // expire_timeout (мс)
    QDBusPendingCall pending = QDBusConnection::sessionBus().asyncCall(msg);
    auto *watcher            = new QDBusPendingCallWatcher(pending, this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
        const QDBusPendingReply<uint> reply = *w;
        if (reply.isValid()) m_currentId = reply.value(); // запомнить id для следующего replaces_id
        w->deleteLater();
    });
    return true; // отправлено; фактический id придёт асинхронно
#else
    return false;
#endif
}

void LinuxNotifier::closeCurrent()
{
    if (!m_available || m_currentId == 0) return;
#if defined(PARANOIA_HAS_QT_DBUS)
    // send() = fire-and-forget (NoBlock): ответ не нужен, а closeCurrent зовётся при
    // выходе приложения на передний план — блокировать GUI тут нельзя (01#17).
    QDBusMessage msg = QDBusMessage::createMethodCall(kService, kPath, kInterface, QStringLiteral("CloseNotification"));
    msg << m_currentId;
    QDBusConnection::sessionBus().send(msg);
    m_currentId = 0;
#endif
}
