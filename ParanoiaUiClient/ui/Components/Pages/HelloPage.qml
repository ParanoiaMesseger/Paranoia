import QtQuick
import QtQuick.Layouts
import ParanoiaUiClient
import QtQuick.VectorImage

Rectangle {
    id: root
    color: Theme.bgPrimary

    signal importProfile()
    signal registerClient()
    signal installServer()

    ColumnLayout {
        anchors.centerIn: parent
        width:            Math.min(360, parent.width - 40)
        anchors.margins: 20
        spacing: 0

        VectorImage {
            Layout.alignment: Qt.AlignHCenter
            Layout.fillWidth: true
            Layout.preferredHeight: 104

            source: "qrc:/logo_lockup_animated.svg"
            fillMode: VectorImage.PreserveAspectFit
            preferredRendererType: VectorImage.CurveRenderer

            animations.loops: Animation.Infinite
            assumeTrustedSource: true
        }

        Item { Layout.preferredHeight: 18 }

        Text {
            Layout.alignment:   Qt.AlignHCenter
            text:               "PRIVATE MEMORY WIPE"
            color:              Theme.accentHover
            font.pixelSize:     Theme.fontSm
            font.family:        Theme.fontFamily
            font.weight:        Font.DemiBold
        }

        Item { Layout.preferredHeight: 8 }

        Text {
            Layout.alignment:   Qt.AlignHCenter
            text:               "Мессенджер, который ничего о тебе не помнит"
            color:              Theme.textSecondary
            font.pixelSize:     Theme.fontSm
            font.family:        Theme.fontFamily
            horizontalAlignment: Text.AlignHCenter
            wrapMode:           Text.WordWrap
            Layout.fillWidth:   true
        }

        Item { Layout.preferredHeight: 48 }

        // ── Кнопки выбора ────────────────────────────────────
        
        ParaButton {
            Layout.fillWidth: true
            text:             "Регистрация"
            onClicked:        root.registerClient()
        }
        
        Item { Layout.preferredHeight: 12 }

        ParaButton {
            Layout.fillWidth: true
            secondary:        true
            text:             "Импорт"
            onClicked:        root.importProfile()
        }

        Item { Layout.preferredHeight: 12 }

        ParaButton {
            Layout.fillWidth: true
            text:             "Установить свой сервер"
            secondary:        true
            onClicked:        root.installServer()
        }

    }
    Text {
        anchors {
            left: parent.left
            right: parent.right
            bottom: parent.bottom
            margins: 20
        }
        text:               "Version: " + Qt.application.version
        color: Theme.textSecondary
        font.pixelSize: Theme.fontSm
        font.family: Theme.fontFamily
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
    }
}
