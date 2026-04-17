import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import ParanoiaUiClient

Rectangle {
    id: root
    color: Theme.bgPrimary

    signal back()
    signal proceedToLogin(string privateKey)

    property string publicKey:  ""
    property string privateKey: ""
    property bool   generating: false

    Connections {
        target: Backend
        function onKeyPairGenerated(pub, priv) {
            root.publicKey  = pub
            root.privateKey = priv
            root.generating = false
        }
    }

    Component.onCompleted: {
        generating = true
        Backend.generateKeyPair()
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

                // Generating indicator
                Rectangle {
                    Layout.fillWidth: true
                    height: 44
                    radius: Theme.radiusMd
                    color:  Theme.bgSecondary
                    visible: root.generating

                    Text {
                        anchors.centerIn: parent
                        text:  "Генерация ключей…"
                        color: Theme.textSecondary
                        font.pixelSize: Theme.fontSm
                        font.family:    Theme.fontFamily
                    }
                }

                Text {
                    Layout.fillWidth: true
                    visible: !root.generating
                    text:   "Ваш публичный ключ сгенерирован. Передайте его администратору сервера."
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
                    visible: !root.generating

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
                    visible:          !root.generating
                    onClicked: {
                        copyClipboard.text = root.publicKey
                        copyClipboard.selectAll()
                        copyClipboard.copy()
                        text = "Скопировано ✓"
                    }
                }

                // Clipboard helper (invisible)
                TextEdit {
                    id:      copyClipboard
                    visible: false
                    text:    root.publicKey
                }

                // ── QR placeholder ────────────────────────────
                Rectangle {
                    Layout.alignment: Qt.AlignHCenter
                    width:  180; height: 180
                    radius: Theme.radiusMd
                    color:  "#FFFFFF"
                    visible: !root.generating

                    Column {
                        anchors.centerIn: parent
                        spacing: 8
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text:  "[ QR код ]"
                            color: "#333333"
                            font.pixelSize: Theme.fontMd
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text:  root.publicKey.length > 0
                                   ? root.publicKey.substring(0, 12) + "…"
                                   : ""
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
                    visible:            !root.generating
                }

                Item { Layout.preferredHeight: 8 }

                ParaButton {
                    Layout.fillWidth: true
                    text:             "Я передал ключ → Войти"
                    enabled:          !root.generating
                    onClicked:        root.proceedToLogin(root.privateKey)
                }

                Item { Layout.preferredHeight: 16 }
            }
        }
    }
}
