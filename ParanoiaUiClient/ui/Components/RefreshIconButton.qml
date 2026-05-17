import QtQuick
import ParanoiaUiClient

Rectangle {
    id: root

    signal clicked()

    implicitWidth: 40
    implicitHeight: 40
    radius: Theme.radiusMd
    color: refreshArea.containsMouse && root.enabled ? Theme.bgCard : Theme.bgSecondary
    border.width: 1
    border.color: Theme.border

    Canvas {
        id: refreshCanvas
        anchors.centerIn: parent
        width: 18
        height: 18
        antialiasing: true

        property color iconColor: root.enabled ? Theme.textPrimary : Theme.textHint
        onIconColorChanged: requestPaint()

        onPaint: {
            const ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            ctx.strokeStyle = iconColor
            ctx.lineWidth = 1.8
            ctx.lineCap = "round"
            ctx.lineJoin = "round"

            ctx.beginPath()
            ctx.arc(width * 0.5, height * 0.5, width * 0.33, Math.PI * 0.2, Math.PI * 1.7, false)
            ctx.stroke()

            ctx.beginPath()
            ctx.moveTo(width * 0.607, height * 0.076)
            ctx.lineTo(width * 0.694, height * 0.233)
            ctx.lineTo(width * 0.537, height * 0.320)
            ctx.stroke()
        }

        RotationAnimator {
            id: spinAnim
            target: refreshCanvas
            from: 0
            to: 360
            duration: 1000
            easing.type: Easing.OutCubic
        }
    }

    MouseArea {
        id: refreshArea
        anchors.fill: parent
        enabled: root.enabled
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            root.clicked()
            spinAnim.restart()
        }
    }
}
