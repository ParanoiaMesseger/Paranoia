import QtQuick
import QtQuick.Layouts
import ParanoiaUiClient

Rectangle {
    id: root
    color: Theme.bgPrimary

    signal back()
    signal connected()

    property bool   isConnecting: false
    property string errorMsg:     ""

    Connections {
        target: Backend
        function onAdminConnected() {
            root.isConnecting = false
            root.connected()
        }
        function onConnectError(msg) {
            root.isConnecting = false
            root.errorMsg     = msg
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing:      0

        ParaHeader {
            Layout.fillWidth: true
            title:            "Вход администратора"
            onBackClicked:    root.back()
        }

        Item { Layout.fillHeight: true }

        ColumnLayout {
            Layout.alignment:   Qt.AlignHCenter
            Layout.leftMargin:  24
            Layout.rightMargin: 24
            width:              320
            spacing:            16

            ParaInput {
                id:              endpointInput
                Layout.fillWidth: true
                label:           "Адрес сервера"
                placeholder:     "example.com:1455"
            }

            ParaInput {
                id:              privKeyInput
                Layout.fillWidth: true
                label:           "Приватный ключ администратора"
                placeholder:     "Вставьте admin_priv…"
                echoMode:        TextInput.Password
            }

            // Ошибка
            Rectangle {
                Layout.fillWidth: true
                height:           42
                radius:           Theme.radiusSm
                color:            "#2A1A1C"
                visible:          root.errorMsg !== ""

                Text {
                    anchors.centerIn: parent
                    anchors.margins:  12
                    text:             root.errorMsg
                    color:            Theme.error
                    font.pixelSize:   Theme.fontSm
                    font.family:      Theme.fontFamily
                    wrapMode:         Text.WordWrap
                    width:            parent.width - 24
                    horizontalAlignment: Text.AlignHCenter
                }
            }

            Item { Layout.preferredHeight: 8 }

            ParaButton {
                Layout.fillWidth: true
                text:             root.isConnecting ? "Подключение…" : "Войти"
                enabled:          !root.isConnecting
                onClicked: {
                    let srv = endpointInput.text.trim()
                    let key = privKeyInput.text.trim()
                    if (srv === "" || key === "") {
                        root.errorMsg = "Заполните все поля."
                        return
                    }
                    root.isConnecting = true
                    root.errorMsg     = ""
                    Backend.connectAdmin(srv, key)
                }
            }
        }

        Item { Layout.fillHeight: true }
    }
}
