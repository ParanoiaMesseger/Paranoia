import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import ParanoiaUiClient

Rectangle {
    id: root
    color: Theme.bgPrimary

    signal back()
    signal loggedIn()

    property string publicKey:  ""
    property string privateKey: ""
    property bool   generating: false
    property bool   isLoading: false
    property string errorMsg: ""

    function registrationQrPayload() {
        return JSON.stringify({
            type: "paranoia.registration.pubkey.v1",
            pubkey: root.publicKey
        })
    }

    Connections {
        target: Backend
        function onKeyPairGenerated(pub, priv) {
            root.publicKey  = pub
            root.privateKey = priv
            root.generating = false
        }
        function onLoginStateChanged() {
            if (Backend.loggedIn) {
                root.isLoading = false
                root.loggedIn()
            }
        }
        function onLoginError(msg) {
            root.isLoading = false
            root.errorMsg = msg
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

                // ── Публичный ключ ─────────────────────────────
                CopyablePublicKeyBlock {
                    Layout.fillWidth: true
                    Layout.leftMargin: 24
                    Layout.rightMargin: 24
                    visible: !root.generating
                    title: "Передайте ваш публичный ключ администратору сервера"
                    keyText: root.publicKey
                }

                // Clipboard helper (invisible)
                TextEdit {
                    id:      copyClipboard
                    visible: false
                    text:    root.publicKey
                }

                // ── QR для передачи публичного ключа админу ────
                QrCodeBox {
                    Layout.alignment: Qt.AlignHCenter
                    boxSize: Math.min(240, Math.max(180, content.width - 48))
                    payload: root.registrationQrPayload()
                    caption: root.publicKey.length > 0 ? root.publicKey.substring(0, 12) + "..." : ""
                    visible: !root.generating
                }

                Text {
                    Layout.alignment:   Qt.AlignHCenter
                    text:               "Или дайте администратору отсканировать этот QR-код. Ключ сохранён локально и восстановится после перезапуска приложения."
                    color:              Theme.textSecondary
                    font.pixelSize:     Theme.fontXs
                    font.family:        Theme.fontFamily
                    wrapMode:           Text.WordWrap
                    horizontalAlignment: Text.AlignHCenter
                    Layout.fillWidth:   true
                    visible:            !root.generating
                }

                Item { Layout.preferredHeight: 8 }

                ParaInput {
                    id: endpointInput
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                    label: "Адрес сервера"
                    placeholder: "https://example.com"
                    visible: !root.generating
                }

                ParaInput {
                    id: reserveEndpointInput
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                    label: "Резервный адрес сервера"
                    placeholder: "https://cdn.example.com (опционально)"
                    visible: !root.generating
                }

                ParaInput {
                    id: usernameInput
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                    label: "Имя пользователя"
                    placeholder: "username"
                    visible: !root.generating
                }

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: errorText.implicitHeight + 20
                    radius: Theme.radiusSm
                    color: Theme.errorBg
                    visible: root.errorMsg !== ""

                    Text {
                        id: errorText
                        anchors.fill: parent
                        anchors.margins: 10
                        text: root.errorMsg
                        color: Theme.error
                        font.pixelSize: Theme.fontSm
                        font.family: Theme.fontFamily
                        wrapMode: Text.WordWrap
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                ParaButton {
                    Layout.fillWidth: true
                    text:             root.isLoading ? "Вход…" : "Я передал ключ, войти"
                    enabled:          !root.generating && !root.isLoading
                    onClicked: {
                        const server = endpointInput.text.trim()
                        const username = usernameInput.text.trim()
                        if (server === "" || username === "") {
                            root.errorMsg = "Укажите сервер и имя пользователя."
                            return
                        }
                        if (root.privateKey === "") {
                            root.errorMsg = "Ключи ещё не сгенерированы."
                            return
                        }
                        root.errorMsg = ""
                        root.isLoading = true
                        Backend.loginClient(server, reserveEndpointInput.text.trim(), username, root.privateKey)
                    }
                }

                Item { Layout.preferredHeight: 16 }
            }
        }
    }
}
