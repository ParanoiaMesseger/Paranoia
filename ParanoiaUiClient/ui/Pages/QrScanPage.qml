import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import ParanoiaUiClient

Rectangle {
    id: root
    color: Theme.bgPrimary

    property string title: "Сканировать QR"
    property string instructions: "Наведите камеру на QR-код. Сканирование завершится автоматически."

    signal back()
    signal qrScanned(string text)

    QrCameraScanner {
        id: scanner
        onDecoded: function (text) {
            root.qrScanned(text)
        }
    }

    Component.onCompleted: scanner.start()
    Component.onDestruction: scanner.stop()

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        ParaHeader {
            Layout.fillWidth: true
            title: root.title
            onBackClicked: root.back()
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true

            Rectangle {
                anchors.fill: parent
                color: "black"
            }

            Image {
                anchors.fill: parent
                source: scanner.previewFrame
                fillMode: Image.PreserveAspectCrop
                visible: scanner.previewFrame.length > 0
                asynchronous: true
            }

            Rectangle {
                anchors.centerIn: parent
                width: Math.min(parent.width - 72, 280)
                height: width
                color: "transparent"
                border.width: 3
                border.color: scanner.error.length > 0 ? Theme.error : Theme.accent
                radius: Theme.radiusMd
            }

            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: statusCol.implicitHeight + 28
                color: Theme.bgDark
                opacity: 0.94

                ColumnLayout {
                    id: statusCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 20
                    anchors.rightMargin: 20
                    spacing: 10

                    Text {
                        Layout.fillWidth: true
                        text: scanner.error.length > 0 ? scanner.error : root.instructions
                        color: scanner.error.length > 0 ? Theme.error : Theme.textPrimary
                        font.pixelSize: Theme.fontSm
                        font.family: Theme.fontFamily
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                    }

                    Text {
                        Layout.fillWidth: true
                        text: scanner.supported ? "Идёт сканирование…" : "Камера недоступна в этой сборке или на устройстве."
                        color: Theme.textSecondary
                        font.pixelSize: Theme.fontXs
                        font.family: Theme.fontFamily
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                        visible: scanner.error.length === 0 || !scanner.supported
                    }

                    ParaButton {
                        Layout.fillWidth: true
                        text: "Отмена"
                        secondary: true
                        onClicked: root.back()
                    }
                }
            }
        }
    }
}
