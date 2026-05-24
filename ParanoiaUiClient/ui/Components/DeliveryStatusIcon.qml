import QtQuick
import ParanoiaUiClient

Canvas {
    id: root
    width: status === "read" ? 18 : 12
    height: 10

    property string status: "pending"
    property color iconColor: Theme.messageMetaOutgoing

    onStatusChanged: requestPaint()
    onIconColorChanged: requestPaint()

    onPaint: {
        const ctx = getContext("2d")
        ctx.clearRect(0, 0, width, height)
        ctx.strokeStyle = iconColor
        ctx.fillStyle = iconColor
        ctx.lineWidth = 1.6
        ctx.lineCap = "round"
        ctx.lineJoin = "round"

        if (status === "failed") {
            ctx.beginPath()
            ctx.moveTo(2, 2)
            ctx.lineTo(width - 2, height - 2)
            ctx.moveTo(width - 2, 2)
            ctx.lineTo(2, height - 2)
            ctx.stroke()
            return
        }

        if (status === "delivered" || status === "read") {
            function check(offset) {
                ctx.beginPath()
                ctx.moveTo(offset + 1, height * 0.55)
                ctx.lineTo(offset + 4, height - 2)
                ctx.lineTo(offset + 10, 2)
                ctx.stroke()
            }
            if (status === "read") {
                check(0)
                check(6)
            } else {
                check(0)
            }
            return
        }

        for (let i = 0; i < 3; ++i) {
            ctx.beginPath()
            ctx.arc(2 + i * 4, height / 2, 1.15, 0, Math.PI * 2)
            ctx.fill()
        }
    }
}
