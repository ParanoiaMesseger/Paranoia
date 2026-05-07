import QtQuick
import QtQuick.Layouts
import ParanoiaUiClient

Rectangle {
    id: root

    property string payload: ""
    property string caption: ""
    property int boxSize: 220

    readonly property string qrSource: payload.length > 0
        ? QrCodeUtils.pngDataUrl(payload, 768)
        : ""

    implicitWidth: boxSize
    implicitHeight: boxSize + (caption.length > 0 ? 28 : 0)
    radius: Theme.radiusMd
    color: Theme.bgCard
    border.width: 1
    border.color: Theme.accentDim
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

    }
}
