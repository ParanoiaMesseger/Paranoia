import QtQuick
import QtQuick.Layouts
import ParanoiaUiClient

// Сегментированный переключатель (pill-style segmented button).
// options: [{code, label, icon, description}] — code обязателен (уникальный
// идентификатор), label/icon/description опциональны (пустые не рендерятся).
// Активный сегмент подсвечен Theme.accent, неактивные — Theme.bgSecondary.
RowLayout {
    id: root

    property string currentCode: ""
    property var options: []  // [{code, label, description}]

    signal selected(string code)

    Layout.fillWidth: true
    Layout.preferredHeight: 56
    spacing: 4

    // Левый отступ 6px
    Item { Layout.preferredWidth: 6; Layout.fillHeight: true }

    Repeater {
        model: root.options

        delegate: Rectangle {
            required property var modelData
            Layout.fillWidth: true
            Layout.preferredHeight: 56
            radius: height / 2
            color: modelData.code === root.currentCode
                ? Theme.accent
                : (segArea.containsMouse ? Theme.bgCard : Theme.bgSecondary)
            border.width: 1
            border.color: modelData.code === root.currentCode ? Theme.accentDark : Theme.border
            Behavior on color { ColorAnimation { duration: 120 } }

            Column {
                anchors.centerIn: parent
                spacing: 2

                AppIcon {
                    visible: (modelData.icon || "").length > 0
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 18
                    height: 18
                    name: modelData.icon
                    iconColor: modelData.code === root.currentCode ? Theme.bgDark : Theme.textHint
                    strokeWidth: 2
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    // NBSP-заглушка вместо скрытия: строка подписи резервируется
                    // всегда, иначе глиф сегмента без подписи (✕) центрируется
                    // ниже соседних и ряд иконок выглядит несимметрично.
                    text: (modelData.label || "").length > 0 ? modelData.label : " "
                    color: modelData.code === root.currentCode ? Theme.bgDark : Theme.textPrimary
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    font.weight: modelData.code === root.currentCode ? Font.DemiBold : Font.Normal
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: modelData.description || ""
                    visible: (modelData.description || "").length > 0
                    color: modelData.code === root.currentCode ? Theme.bgDark : Theme.textHint
                    font.pixelSize: Theme.fontXs
                    font.family: Theme.fontFamily
                    opacity: modelData.code === root.currentCode ? 0.7 : 1.0
                }
            }

            MouseArea {
                id: segArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.selected(modelData.code)
            }
        }
    }

    // Правый отступ 6px
    Item { Layout.preferredWidth: 6; Layout.fillHeight: true }
}
