import QtQuick
import ParanoiaUiClient


Canvas {
    id: root

    implicitWidth: 20
    implicitHeight: 20
    antialiasing: true

    property color color: "#e05c5c"
    property real strokeWidth: 2
    property alias rotY: _rot.angle

    onColorChanged: requestPaint()
    onStrokeWidthChanged: requestPaint()
    onVisibleChanged: if (visible) requestPaint()

    transform: Rotation {
        id: _rot
        origin.x: root.width / 2
        origin.y: root.height / 2
        axis { x: 0; y: 1; z: 0 }
        angle: 0
    }

    onPaint: {
        const ctx = getContext("2d")
        ctx.clearRect(0, 0, width, height)
        ctx.lineWidth = root.strokeWidth
        ctx.lineJoin = "round"
        ctx.lineCap = "round"
        ctx.strokeStyle = root.color
        ctx.beginPath()
        ctx.moveTo(width * 0.15, height * 0.52)
        ctx.lineTo(width * 0.42, height * 0.78)
        ctx.lineTo(width * 0.85, height * 0.25)
        ctx.stroke()
    }
}