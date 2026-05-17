#pragma once

#include <QStringList>

namespace paranoia::voip
{

    /// Сбор локальных сетевых кандидатов для VoIP-сигналинга (host candidates).
    ///
    /// Принципы:
    /// - Только UP-интерфейсы (`QNetworkInterface::IsUp`).
    /// - Loopback (127.0.0.0/8, ::1) и интерфейсы с флагом IsLoopBack — отбрасываем.
    /// - IPv6 пока отбрасываем: media-сокет сейчас биндится к IPv4 `0.0.0.0:0`,
    ///   а IPv6 candidate с таким сокетом нерабочий.
    /// - IPv4 без интерфейсов и автомата — отбрасываем (например 169.254.x — пока
    ///   тоже игнорируем).
    class NetUtil
    {
    public:
        /// Вернуть список строк "ip:port" — по одному на каждый подходящий IPv4
        /// адрес.
        static QStringList localCandidates(quint16 port);
    };

} // namespace paranoia::voip
