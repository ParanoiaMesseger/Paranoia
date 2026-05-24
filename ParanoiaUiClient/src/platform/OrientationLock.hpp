#pragma once

#include <QObject>

namespace paranoia::platform
{

    /// Утилита блокировки ориентации экрана на время видеозвонка. На Android
    /// дергает Activity.setRequestedOrientation; на iOS — переключает
    /// UIInterfaceOrientationMask через AppDelegate-категорию (см.
    /// IosOrientationLock.mm). На десктопе — no-op.
    class OrientationLock : public QObject
    {
        Q_OBJECT
    public:
        explicit OrientationLock(QObject *parent = nullptr);

        /// Заблокировать portrait-ориентацию.
        Q_INVOKABLE void lockPortrait();

        /// Снять блокировку — окно/Activity снова реагирует на ориентацию устройства.
        Q_INVOKABLE void unlock();
    };

} // namespace paranoia::platform
