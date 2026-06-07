import QtQuick
import ParanoiaUiClient

// Панель навигации/редактирования над виртуальной клавиатурой.
// Кнопки шлют синтетические клавиши в активное текстовое поле через KeyInjector
// (C++), не перехватывая фокус — поэтому фокус остаётся на поле ввода.
Rectangle {
    id: bar
    height: 46
    color: Theme.bgSecondary

    // Верхняя разделительная линия — отделяет панель от контента над клавиатурой.
    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 1
        color: Theme.border
    }

    // Набор действий в порядке: в начало, выделить всё, на строку вверх,
    // влево на символ, вправо на символ, на строку вниз, копировать, вставить,
    // в конец строки.
    readonly property var actions: [
        { icon: "goToStart", key: Qt.Key_Home,  mod: 0 },
        { icon: "selectAll", key: Qt.Key_A,     mod: Qt.ControlModifier },
        { icon: "lineUp",    key: Qt.Key_Up,    mod: 0 },
        { icon: "charLeft",  key: Qt.Key_Left,  mod: 0 },
        { icon: "charRight", key: Qt.Key_Right, mod: 0 },
        { icon: "lineDown",  key: Qt.Key_Down,  mod: 0 },
        { icon: "copy",      key: Qt.Key_C,     mod: Qt.ControlModifier },
        { icon: "paste",     key: Qt.Key_V,     mod: Qt.ControlModifier },
        { icon: "endOfLine", key: Qt.Key_End,   mod: 0 }
    ]

    Row {
        anchors.fill: parent

        Repeater {
            model: bar.actions

            Item {
                id: cell
                required property var modelData
                width: bar.width / bar.actions.length
                height: bar.height

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 3
                    radius: Theme.radiusSm
                    color: keyArea.pressed ? Theme.accentDim : "transparent"
                    Behavior on color { ColorAnimation { duration: 100 } }
                }

                AppIcon {
                    anchors.centerIn: parent
                    width: 22
                    height: 22
                    name: cell.modelData.icon
                    iconColor: Theme.textPrimary
                    fillColor: Theme.bgSecondary
                    secondaryColor: Theme.bgInput
                    strokeWidth: 1.8
                }

                MouseArea {
                    id: keyArea
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    // acceptedButtons по умолчанию LeftButton; клик не забирает
                    // активный фокус у текстового поля.
                    onClicked: KeyInjector.sendKey(cell.modelData.key, cell.modelData.mod)
                }
            }
        }
    }
}
