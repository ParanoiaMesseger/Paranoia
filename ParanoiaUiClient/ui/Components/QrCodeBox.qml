import QtQuick
import QtQuick.Layouts
import ParanoiaUiClient

Rectangle {
    id: root

    property string payload: ""
    property string caption: ""
    property int boxSize: 220

    readonly property string qrSource: payload.length > 0
        ? Backend.qrCodePngDataUrl(payload, 768)
        : ""

    implicitWidth: boxSize
    implicitHeight: boxSize + (caption.length > 0 ? 28 : 0)
    radius: Theme.radiusMd
    color: "#FFFFFF"
    border.color: Theme.border
    clip: true

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 10
        spacing: 6

        Image {
            Layout.alignment: Qt.AlignHCenter
            Layout.fillWidth: true
            Layout.fillHeight: true
            source: root.qrSource
            fillMode: Image.PreserveAspectFit
            smooth: false
            mipmap: false
            visible: root.qrSource.length > 0
        }

        Text {
            Layout.fillWidth: true
            text: root.qrSource.length > 0 ? root.caption : "QR недоступен"
            color: root.qrSource.length > 0 ? "#444444" : "#993333"
            font.pixelSize: Theme.fontXs
            font.family: Theme.fontFamily
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            visible: text.length > 0
        }
    }
}
