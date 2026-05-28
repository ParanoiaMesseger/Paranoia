import QtQuick

Canvas {
    id: root
    width: 24
    height: 24
    antialiasing: true

    property string name: ""
    property color iconColor: "white"
    property real strokeWidth: 1.8

    onNameChanged: requestPaint()
    onIconColorChanged: requestPaint()
    onStrokeWidthChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    onPaint: {
        const ctx = getContext("2d")
        ctx.setTransform(1, 0, 0, 1, 0, 0)
        ctx.clearRect(0, 0, width, height)
        ctx.scale(width / 24, height / 24)
        ctx.strokeStyle = iconColor
        ctx.fillStyle = iconColor
        ctx.lineWidth = strokeWidth
        ctx.lineCap = "round"
        ctx.lineJoin = "round"

        if (name === "shift") {
            ctx.beginPath()
            ctx.moveTo(12, 4)
            ctx.lineTo(4.5, 12)
            ctx.lineTo(8.5, 12)
            ctx.lineTo(8.5, 20)
            ctx.lineTo(15.5, 20)
            ctx.lineTo(15.5, 12)
            ctx.lineTo(19.5, 12)
            ctx.closePath()
            ctx.stroke()
            return
        }

        if (name === "backspace") {
            ctx.beginPath()
            ctx.moveTo(3, 12)
            ctx.lineTo(8, 6)
            ctx.lineTo(21, 6)
            ctx.lineTo(21, 18)
            ctx.lineTo(8, 18)
            ctx.closePath()
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(12, 9)
            ctx.lineTo(17, 14)
            ctx.moveTo(17, 9)
            ctx.lineTo(12, 14)
            ctx.stroke()
            return
        }

        if (name === "enter") {
            ctx.beginPath()
            ctx.moveTo(19, 5)
            ctx.lineTo(19, 12)
            ctx.lineTo(6, 12)
            ctx.moveTo(10, 8)
            ctx.lineTo(6, 12)
            ctx.lineTo(10, 16)
            ctx.stroke()
            return
        }

        if (name === "keyboardHide") {
            ctx.beginPath()
            ctx.moveTo(5, 7)
            ctx.lineTo(19, 7)
            ctx.lineTo(19, 15)
            ctx.lineTo(5, 15)
            ctx.closePath()
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(8, 19)
            ctx.lineTo(12, 22)
            ctx.lineTo(16, 19)
            ctx.stroke()
            return
        }
    }
}
