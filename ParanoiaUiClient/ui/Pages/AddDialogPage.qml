import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import ParanoiaUiClient

Rectangle {
    id: root
    color: Theme.bgPrimary

    signal back
    signal openQrExchange(string peer, bool updateExisting)

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        ParaHeader {
            Layout.fillWidth: true
            title: qsTr("Добавить собеседника")
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

                ParaInput {
                    id: newPeerInput
                    Layout.fillWidth: true
                    label: qsTr("Имя собеседника (локальная метка)")
                    placeholder: "username"
                }

                Text {
                    id: addDialogError
                    Layout.fillWidth: true
                    color: Theme.error
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    visible: text.length > 0
                }

                ParaButton {
                    Layout.fillWidth: true
                    text: qsTr("Обменяться ключом через QR/JSON")
                    onClicked: {
                        let peer = newPeerInput.text.trim()
                        if (peer === "") {
                            addDialogError.text = qsTr("Введите имя собеседника.")
                            return
                        }
                        addDialogError.text = ""
                        root.openQrExchange(peer, false)
                    }
                }

                Item {
                    Layout.preferredHeight: 16
                }
            }
        }
    }
}
