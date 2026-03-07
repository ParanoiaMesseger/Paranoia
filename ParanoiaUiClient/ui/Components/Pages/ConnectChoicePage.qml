import QtQuick
import QtQuick.Layouts
import ParanoiaUiClient

Rectangle {
    color: Theme.bgPrimary

    signal back()
    signal asAdmin()
    signal asClient()

    ColumnLayout {
        anchors.fill:    parent
        spacing:         0

        ParaHeader {
            Layout.fillWidth: true
            title:            "Подключиться к серверу"
            onBackClicked:    back()
        }

        Item { Layout.fillHeight: true }

        ColumnLayout {
            Layout.alignment:    Qt.AlignHCenter
            Layout.leftMargin:   24
            Layout.rightMargin:  24
            width:               320
            spacing:             12

            Text {
                Layout.alignment:   Qt.AlignHCenter
                text:               "Войти как"
                color:              Theme.textSecondary
                font.pixelSize:     Theme.fontMd
                font.family:        Theme.fontFamily
            }

            Item { Layout.preferredHeight: 8 }

            ParaButton {
                Layout.fillWidth: true
                text:             "Администратор"
                onClicked:        asAdmin()
            }

            ParaButton {
                Layout.fillWidth: true
                text:             "Клиент"
                secondary:        true
                onClicked:        asClient()
            }
        }

        Item { Layout.fillHeight: true }
    }
}
