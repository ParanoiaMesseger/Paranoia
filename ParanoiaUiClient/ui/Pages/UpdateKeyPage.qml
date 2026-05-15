import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import ParanoiaUiClient

Rectangle {
    id: root
    color: Theme.bgPrimary

    required property string peer

    signal back()
    signal openQrExchange(string peer, bool updateExisting)

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        ParaHeader {
            Layout.fillWidth: true
            title: "Обновить ключ диалога"
            onBackClicked: root.back()
        }

        Flickable {
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentHeight: contentCol.implicitHeight
            clip: true

            ColumnLayout {
                id: contentCol
                width: parent.width
                spacing: 16
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 20

                Text {
                    Layout.fillWidth: true
                    text: root.peer
                    color: Theme.textSecondary
                    font.pixelSize: Theme.fontSm
                    font.family:    Theme.fontFamily
                }

                Text {
                    Layout.fillWidth: true
                    text: "Ручной ввод ключа отключён. Обновление ключа диалога выполняется только через защищённый обмен JSON/QR."
                    color: Theme.textSecondary
                    font.pixelSize: Theme.fontSm
                    font.family:    Theme.fontFamily
                    wrapMode: Text.WordWrap
                }

                ParaButton {
                    Layout.fillWidth: true
                    text: "Начать обмен через QR/JSON"
                    onClicked: root.openQrExchange(root.peer, true)
                }

                ParaButton {
                    Layout.fillWidth: true
                    text: "Отмена"
                    secondary: true
                    onClicked: root.back()
                }

                Item { Layout.preferredHeight: 16 }
            }
        }
    }
}
