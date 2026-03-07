import QtQuick 2.15
import QtQuick.Layouts 1.15
import QtQuick.Controls 2.15
import ParanoiaUiClient

Rectangle {
    id: root
    color: Theme.bgPrimary

    signal back()
    signal proceedToLogin(string privateKey)

    property string publicKey:  ""
    property string privateKey: ""

    Component.onCompleted: generateKeys()

    function generateKeys() {
        // backend.generateKeyPair() → onKeysGenerated(pub, priv)
        // Заглушка для UI:
        publicKey  = "DEMO_PUBLIC_KEY_ABCDEF1234567890"
        privateKey = "DEMO_PRIVATE_KEY_FEDCBA0987654321"
    }

    ColumnLayout {
        anchors.fill: parent
        spacing:      0

        ParaHeader {
            Layout.fillWidth: true
            title:            "Регистрация"
            onBackClicked:    root.back()
        }

        Flickable {
            Layout.fillWidth:  true
            Layout.fillHeight: true
            contentHeight:     content.implicitHeight + 32
            clip:              true

            ColumnLayout {
                id:             content
                width:          parent.width
                anchors.margins: 24
                anchors.left:   parent.left
                anchors.right:  parent.right
                spacing:        20

                Item { Layout.preferredHeight: 8 }

                Text {
                    Layout.fillWidth: true
                    text:   "Ваш публичный ключ сгенерирован. Передайте его администратору сервера, чтобы он вас зарегистрировал."
                    color:  Theme.textSecondary
                    font.pixelSize: Theme.fontSm
                    font.family:    Theme.fontFamily
                    wrapMode:       Text.WordWrap
                    lineHeight:     1.4
                }

                // ── Публичный ключ ─────────────────────────────
                Rectangle {
                    Layout.fillWidth: true
                    height:     80
                    radius:     Theme.radiusMd
                    color:      Theme.bgInput
                    border.color: Theme.border

                    ScrollView {
                        anchors.fill:    parent
                        anchors.margins: 12

                        TextArea {
                            text:            root.publicKey
                            color:           Theme.accent
                            font.pixelSize:  Theme.fontSm
                            font.family:     "Courier New"
                            readOnly:        true
                            wrapMode:        Text.WrapAnywhere
                            background:      null
                            selectedTextColor: "#FFFFFF"
                            selectionColor:  Theme.accentDark
                        }
                    }
                }

                // ── Кнопка копирования ─────────────────────────
                ParaButton {
                    Layout.fillWidth: true
                    text:             "Скопировать публичный ключ"
                    secondary:        true
                    onClicked: {
                        // Clipboard.text = root.publicKey
                    }
                }

                // ── QR-код ────────────────────────────────────
                Rectangle {
                    Layout.alignment: Qt.AlignHCenter
                    width:  200; height: 200
                    radius: Theme.radiusMd
                    color:  "#FFFFFF"

                    // QR-код генерируется через QML-плагин или C++:
                    // QrCodeItem { data: root.publicKey; anchors.fill: parent }
                    Column {
                        anchors.centerIn: parent
                        spacing:          8
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text:  "[ QR код ]"
                            color: "#333333"
                            font.pixelSize: Theme.fontMd
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text:  "Требует плагин"
                            color: "#888888"
                            font.pixelSize: Theme.fontXs
                        }
                    }
                }

                Text {
                    Layout.alignment:   Qt.AlignHCenter
                    text:               "Публичный ключ для администратора"
                    color:              Theme.textSecondary
                    font.pixelSize:     Theme.fontXs
                    font.family:        Theme.fontFamily
                }

                Item { Layout.preferredHeight: 8 }

                ParaButton {
                    Layout.fillWidth: true
                    text:             "Я передал ключ → Войти"
                    onClicked:        root.proceedToLogin(root.privateKey)
                }

                Item { Layout.preferredHeight: 16 }
            }
        }
    }
}
