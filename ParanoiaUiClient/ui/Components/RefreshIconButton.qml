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

    AppIcon {
        id: refreshCanvas
        anchors.centerIn: parent
        width: 18
        height: 18
        name: "refresh"
        iconColor: root.enabled ? Theme.textPrimary : Theme.textHint
        strokeWidth: 1.8

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
