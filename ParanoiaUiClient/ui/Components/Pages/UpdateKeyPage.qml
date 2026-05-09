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
                    text: "Введите новый общий секрет. Обе стороны должны ввести одинаковое значение."
                    color: Theme.textSecondary
                    font.pixelSize: Theme.fontSm
                    font.family:    Theme.fontFamily
                    wrapMode: Text.WordWrap
                }

                ParaInput {
                    id: newKeyInput
                    Layout.fillWidth: true
                    label:       "Новый общий секрет"
                    placeholder: "секретная фраза…"
                    echoMode:    TextInput.Password
                }

                ParaButton {
                    Layout.fillWidth: true
                    text: "Обменяться ключом через QR/JSON"
                    secondary: true
                    onClicked: root.openQrExchange(root.peer, true)
                }

                Text {
                    id: updateKeyError
                    Layout.fillWidth: true
                    color: Theme.error
                    font.pixelSize: Theme.fontSm
                    font.family:    Theme.fontFamily
                    wrapMode: Text.WordWrap
                    visible: text.length > 0
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12

                    ParaButton {
                        Layout.fillWidth: true
                        text: "Обновить"
                        onClicked: {
                            let secret = newKeyInput.text
                            if (secret.length < 4) {
                                updateKeyError.text = "Секрет слишком короткий (минимум 4 символа)."
                                return
                            }
                            Backend.updateDialogKey(root.peer, secret)
                            root.back()
                        }
                    }

                    ParaButton {
                        Layout.fillWidth: true
                        text: "Отмена"
                        secondary: true
                        onClicked: root.back()
                    }
                }

                Item { Layout.preferredHeight: 16 }
            }
        }
    }
}
