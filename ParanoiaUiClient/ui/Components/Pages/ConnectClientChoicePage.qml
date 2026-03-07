import QtQuick
import QtQuick.Layouts
import ParanoiaUiClient

Rectangle {
    color: Theme.bgPrimary

    signal back()
    signal register_()
    signal login()

    ColumnLayout {
        anchors.fill: parent
        spacing:      0

        ParaHeader {
            Layout.fillWidth: true
            title:            "Клиент"
            onBackClicked:    back()
        }

        Item { Layout.fillHeight: true }

        ColumnLayout {
            Layout.alignment:   Qt.AlignHCenter
            Layout.margins:     24
            width:              320
            spacing:            12

            ParaButton {
                Layout.fillWidth: true
                text:             "Регистрация"
                onClicked:        register_()
            }

            ParaButton {
                Layout.fillWidth: true
                text:             "Вход"
                secondary:        true
                onClicked:        login()
            }
        }

        Item { Layout.fillHeight: true }
    }
}
