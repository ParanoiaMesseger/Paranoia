// Toggle.qml
import QtQuick
import ParanoiaUiClient

Item {
    id: root

    // ── Public API ────────────────────────────────────────
    property bool checked: false
    property bool enabled: true

    // Размеры задаются снаружи, компонент адаптируется
    width:  56
    height: 28

    signal toggled(bool checked)

    // ── Вычисляемые внутренние размеры ────────────────────
    readonly property real _trackRadius: height / 2
    readonly property real _thumbPad:    height * 0.1
    readonly property real _thumbSize:   height - _thumbPad * 2
    readonly property real _thumbOffMin: _thumbPad
    readonly property real _thumbOffMax: width - _thumbSize - _thumbPad

    // ── Track ─────────────────────────────────────────────
    Rectangle {
        id: track
        anchors.fill: parent
        radius: root._trackRadius

        color: root.checked ? Theme.accent : Theme.bgDark
        opacity: root.enabled ? 1.0 : 0.4
        border.width: 1
        border.color: root.checked ? Theme.accentDark : Theme.border

        Behavior on color {
            ColorAnimation { duration: 180; easing.type: Easing.OutCubic }
        }
    }

    // ── Thumb ─────────────────────────────────────────────
    Rectangle {
        id: thumb
        y:      root._thumbPad
        width:  root._thumbSize
        height: root._thumbSize
        radius: root._thumbSize / 2

        color: root.enabled
               ? (root.checked ? Theme.textPrimary : Theme.textSecondary)
               : Theme.textHint

        // Горизонтальный сдвиг
        x: root.checked ? root._thumbOffMax : root._thumbOffMin

        Behavior on x {
            NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
        }
        Behavior on color {
            ColorAnimation { duration: 180; easing.type: Easing.OutCubic }
        }

        // Лёгкое масштабирование при нажатии
        scale: mouseArea.pressed ? 0.88 : 1.0
        Behavior on scale {
            NumberAnimation { duration: 100; easing.type: Easing.OutCubic }
        }
    }

    // ── Interaction ───────────────────────────────────────
    MouseArea {
        id: mouseArea
        anchors.fill: parent
        enabled: root.enabled
        cursorShape: Qt.PointingHandCursor

        onClicked: {
            root.checked = !root.checked
            root.toggled(root.checked)
        }
    }

    // ── Focus / Accessibility ─────────────────────────────
    activeFocusOnTab: true
    Keys.onSpacePressed:  { checked = !checked; toggled(checked) }
    Keys.onReturnPressed: { checked = !checked; toggled(checked) }

    // Обводка фокуса — видна только при навигации с клавиатуры
    Rectangle {
        anchors.fill: parent
        anchors.margins: -3
        radius: root._trackRadius + 3
        color: "transparent"
        border.width: 2
        border.color: Theme.accent
        opacity: root.activeFocus ? 0.7 : 0.0
        Behavior on opacity {
            NumberAnimation { duration: 150 }
        }
    }
}