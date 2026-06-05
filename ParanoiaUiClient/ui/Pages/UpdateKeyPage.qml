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
            id: formFlick
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentHeight: Math.max(formFlick.height, contentCol.implicitHeight + 40)
            clip: true

            ColumnLayout {
                id: contentCol
                // По горизонтали — по центру с ограничением ширины; по вертикали —
                // по центру вьюпорта (ручной ввод не должен липнуть к верху).
                // Контент выше экрана — от верха со скроллом.
                width: Math.min(parent.width - 40, 460)
                spacing: 16
                anchors.horizontalCenter: parent.horizontalCenter
                y: Math.max(20, (formFlick.height - implicitHeight) / 2)

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
