import QtQuick
import QtQuick.Controls
import ParanoiaUiClient

// Тонкий overlay-скроллбар в стиле приложения. Переопределяем contentItem и
// background → нативный стиль платформы (на Windows — системный скроллбар,
// который выбивается из дизайна) НЕ рисуется. Единый вид на всех платформах.
//
// Использование: вместо `ScrollBar {}` писать `AppScrollBar {}` (наследует все
// свойства ScrollBar — policy/orientation и пр. работают как обычно).
ScrollBar {
    id: control

    policy: ScrollBar.AsNeeded
    padding: 2
    minimumSize: 0.08

    contentItem: Rectangle {
        implicitWidth: 6
        implicitHeight: 6
        radius: Math.min(width, height) / 2
        color: control.pressed ? Theme.accent
             : control.hovered ? Theme.textSecondary
                               : Theme.textHint
        opacity: (control.active || control.pressed || control.hovered) ? 0.85 : 0.0
        Behavior on opacity { NumberAnimation { duration: 180 } }
        Behavior on color { ColorAnimation { duration: 120 } }
    }

    background: Rectangle { color: "transparent" }
}
