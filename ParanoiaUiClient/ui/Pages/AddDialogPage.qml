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
            title: "Добавить собеседника"
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

                ParaInput {
                    id: newPeerInput
                    Layout.fillWidth: true
                    label: "Имя собеседника (локальная метка)"
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
                    text: "Обменяться ключом через QR/JSON"
                    onClicked: {
                        let peer = newPeerInput.text.trim()
                        if (peer === "") {
                            addDialogError.text = "Введите имя собеседника."
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
