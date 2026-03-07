import QtQuick
import QtQuick.Layouts
import ParanoiaUiClient

Rectangle {
    id: root
    color: Theme.bgPrimary

    signal back()
    signal connected()

    property bool isConnecting: false
    property string errorMsg:   ""

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
            Layout.margins:     24
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
                height:           36
                radius:           Theme.radiusSm
                color:            "#2A1A1C"
                visible:          root.errorMsg !== ""

                Text {
                    anchors.centerIn: parent
                    text:             root.errorMsg
                    color:            Theme.error
                    font.pixelSize:   Theme.fontSm
                    font.family:      Theme.fontFamily
                }
            }

            Item { Layout.preferredHeight: 8 }

            ParaButton {
                Layout.fillWidth: true
                text:             root.isConnecting ? "Подключение…" : "Войти"
                enabled:          !root.isConnecting
                onClicked: {
                    root.isConnecting = true
                    root.errorMsg = ""
                    // backend.connectAdmin(endpointInput.text, privKeyInput.text)
                }
            }
        }

        Item { Layout.fillHeight: true }
    }

    function onConnectError(msg) {
        isConnecting = false
        errorMsg = msg
    }
}
