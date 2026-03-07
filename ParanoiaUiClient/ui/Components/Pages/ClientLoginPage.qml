import QtQuick
import QtQuick.Layouts
import ParanoiaUiClient

Rectangle {
    id: root
    color: Theme.bgPrimary

    signal back()
    signal loggedIn()

    property bool   isLoading:   false
    property string errorMsg:    ""
    property string autoFillKey: ""   // заполняется после регистрации

    onAutoFillKeyChanged: if (autoFillKey !== "") privKeyInput.text = autoFillKey

    ColumnLayout {
        anchors.fill: parent
        spacing:      0

        ParaHeader {
            Layout.fillWidth: true
            title:            "Вход клиента"
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
                label:           "Приватный ключ (USER_PRIV)"
                placeholder:     "Вставьте ваш ключ…"
                echoMode:        TextInput.Password
            }

            // Блок ошибки
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

            Item { Layout.preferredHeight: 4 }

            ParaButton {
                Layout.fillWidth: true
                text:             root.isLoading ? "Вход…" : "Войти"
                enabled:          !root.isLoading
                onClicked: {
                    root.isLoading = true
                    root.errorMsg  = ""
                    // backend.loginClient(endpointInput.text, privKeyInput.text)
                    // при ошибке "Bad sig encoding":
                    // root.errorMsg = "Клиент не зарегистрирован на этом сервере"
                    // root.isLoading = false
                }
            }
        }

        Item { Layout.fillHeight: true }
    }
}
