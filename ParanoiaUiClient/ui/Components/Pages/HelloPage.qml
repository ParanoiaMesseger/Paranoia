import QtQuick
import QtQuick.Layouts
import ParanoiaUiClient

Rectangle {
    id: root
    color: Theme.bgPrimary

    signal importProfile()
    signal registerClient()
    signal installServer()

    ColumnLayout {
        anchors.centerIn: parent
        width:            320
        spacing:          0

        // ── Логотип / иконка ──────────────────────────────────
        Rectangle {
            Layout.alignment: Qt.AlignHCenter
            width:  80; height: 80
            radius: 40
            color:  Theme.accent

            Text {
                anchors.centerIn: parent
                text:  "🔒"
                font.pixelSize: 36
            }
        }

        Item { Layout.preferredHeight: 24 }

        Text {
            Layout.alignment:   Qt.AlignHCenter
            text:               "Paranoia"
            color:              Theme.textPrimary
            font.pixelSize:     Theme.fontXl
            font.family:        Theme.fontFamily
            font.weight:        Font.Bold
        }

        Item { Layout.preferredHeight: 8 }

        Text {
            Layout.alignment:   Qt.AlignHCenter
            text:               "Безопасный мессенджер"
            color:              Theme.textSecondary
            font.pixelSize:     Theme.fontSm
            font.family:        Theme.fontFamily
        }

        Item { Layout.preferredHeight: 48 }

        // ── Кнопки выбора ────────────────────────────────────
        ParaButton {
            Layout.fillWidth: true
            text:             "Импорт профиля"
            onClicked:        root.importProfile()
        }

        Item { Layout.preferredHeight: 12 }

        ParaButton {
            Layout.fillWidth: true
            text:             "Регистрация клиентом"
            secondary:        true
            onClicked:        root.registerClient()
        }

        Item { Layout.preferredHeight: 12 }

        ParaButton {
            Layout.fillWidth: true
            text:             "Установить свой сервер"
            secondary:        true
            onClicked:        root.installServer()
        }
    }
}
