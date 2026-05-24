import QtQuick
import ParanoiaUiClient

Rectangle {
    id: root
    width: 40
    height: 40
    radius: Theme.radiusSm
    color: callArea.pressed ? Theme.accentDim : (callArea.containsMouse ? Theme.bgCard : "transparent")
    border.width: callArea.containsMouse || callArea.pressed ? 1 : 0
    border.color: callArea.pressed ? Theme.accentHover : Theme.border
    scale: callArea.pressed ? 0.90 : 1.0
    transformOrigin: Item.Center

    signal clicked()

    Behavior on scale {
        NumberAnimation {
            duration: 110
            easing.type: Easing.OutCubic
        }
    }

    Behavior on color {
        ColorAnimation { duration: 110 }
    }

    AppIcon {
        id: phoneIcon
        anchors.centerIn: parent
        width: 20
        height: 20
        name: "phone"
        iconColor: callArea.containsMouse || callArea.pressed ? Theme.accentHover : Theme.accent
        scale: callArea.pressed ? 0.92 : 1.0

        Behavior on scale {
            NumberAnimation {
                duration: 110
                easing.type: Easing.OutCubic
            }
        }
    }

    MouseArea {
        id: callArea
        anchors.fill: parent
        hoverEnabled: true
        onClicked: root.clicked()
    }
}
