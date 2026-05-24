#include "NetUtil.hpp"

#include <QNetworkInterface>
#include <algorithm>

namespace paranoia::voip
{

    namespace
    {

        bool isAcceptable(const QHostAddress &addr)
        {
            if (addr.isNull()) return false;
            if (addr.isLoopback()) return false;

            switch (addr.protocol()) {
                case QAbstractSocket::IPv4Protocol: {
                    // 169.254.0.0/16 — link-local IPv4, в большинстве сценариев бесполезно.
                    const quint32 ip        = addr.toIPv4Address();
                    const quint32 linkLocal = QHostAddress(QStringLiteral("169.254.0.0")).toIPv4Address();
                    if ((ip & 0xFFFF0000u) == linkLocal) return false;
                    return true;
                }
                case QAbstractSocket::IPv6Protocol: {
                    // CallEngine binds an IPv4 socket (`0.0.0.0:0`). Advertising IPv6
                    // addresses makes the peer select an endpoint this socket cannot
                    // send to, so keep candidates aligned with the actual bind family.
                    return false;
                }
                default: return false;
            }
        }

        bool isVirtualInterface(const QNetworkInterface &iface)
        {
            // Виртуальные мосты (docker, libvirt, vmware и т. п.) выдают приватные
            // IPv4 адреса, которые недостижимы извне хоста. Если такой адрес попадёт
            // в Offer/Answer первым, удалённая сторона выберет именно его и звонок
            // повиснет. Имя интерфейса — самый надёжный способ их отсеять кросс-платформно.
            static const QStringList kVirtualPrefixes = {
                QStringLiteral("docker"), QStringLiteral("br-"),     QStringLiteral("virbr"), QStringLiteral("vnet"),
                QStringLiteral("vmnet"),  QStringLiteral("vboxnet"), QStringLiteral("veth"),  QStringLiteral("lxc"),
                QStringLiteral("lxd"),    QStringLiteral("kube"),    QStringLiteral("cni"),   QStringLiteral("flannel"),
                QStringLiteral("zt"), // ZeroTier
            };
            const QString name = iface.name();
            for (const QString &p : kVirtualPrefixes) {
                if (name.startsWith(p, Qt::CaseInsensitive)) return true;
            }
            return false;
        }

        // Преференс host candidate'а: чем меньше число, тем «лучше» (т. е. раньше в
        // списке). Peer выбирает первый — поэтому ставим вперёд адреса, которые с
        // большей вероятностью маршрутизируются между обычными домашними/офисными
        // сетями.
        int candidateRank(const QHostAddress &addr)
        {
            if (addr.protocol() != QAbstractSocket::IPv4Protocol) return 100;
            const quint32 ip = addr.toIPv4Address();
            // 192.168.0.0/16 — типичные домашние Wi-Fi сети.
            if ((ip & 0xFFFF0000u) == (192u << 24 | 168u << 16)) return 0;
            // 10.0.0.0/8 — корпоративные / VPN сети.
            if ((ip & 0xFF000000u) == (10u << 24)) return 1;
            // 172.16.0.0/12 — часто docker/libvirt; но не всегда, поэтому не отсекаем,
            // а откладываем в конец.
            if ((ip & 0xFFF00000u) == (172u << 24 | 16u << 16)) return 3;
            // Прочие (публичные) IPv4 — между внутренними сетями и docker'ом.
            return 2;
        }

        QString formatEndpoint(const QHostAddress &addr, quint16 port)
        {
            if (addr.protocol() == QAbstractSocket::IPv6Protocol) {
                return QStringLiteral("[%1]:%2").arg(addr.toString()).arg(port);
            }
            return QStringLiteral("%1:%2").arg(addr.toString()).arg(port);
        }

    } // namespace

    QStringList NetUtil::localCandidates(quint16 port)
    {
        struct Entry {
            QHostAddress addr;
            QString endpoint;
        };
        QList<Entry> entries;
        const auto interfaces = QNetworkInterface::allInterfaces();
        for (const auto &iface : interfaces) {
            const auto flags = iface.flags();
            if (!(flags & QNetworkInterface::IsUp)) continue;
            if (!(flags & QNetworkInterface::IsRunning)) continue;
            if (flags & QNetworkInterface::IsLoopBack) continue;
            if (isVirtualInterface(iface)) continue;

            const auto addrs = iface.addressEntries();
            for (const auto &entry : addrs) {
                const QHostAddress addr = entry.ip();
                if (!isAcceptable(addr)) continue;
                const QString cand = formatEndpoint(addr, port);
                bool seen          = false;
                for (const auto &e : entries) {
                    if (e.endpoint == cand) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) entries.append({addr, cand});
            }
        }
        std::stable_sort(entries.begin(), entries.end(),
                         [](const Entry &a, const Entry &b) { return candidateRank(a.addr) < candidateRank(b.addr); });
        QStringList result;
        result.reserve(entries.size());
        for (const auto &e : entries) result.append(e.endpoint);
        return result;
    }

} // namespace paranoia::voip
