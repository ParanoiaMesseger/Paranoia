import QtQuick
import QtQuick.Controls
import ParanoiaUiClient
Button {
    id: root

    property bool secondary: false
    property bool destructive: false

    implicitHeight: 44
    implicitWidth: 200

    background: Rectangle {
        radius: Theme.radiusMd
        color: {
            if (root.destructive) return root.hovered ? "#B55A5F" : Theme.error
            if (root.secondary)   return root.hovered ? Theme.border : Theme.bgSecondary
            return root.hovered ? Theme.accentHover : Theme.accent
        }
        Behavior on color { ColorAnimation { duration: 120 } }
    }

    contentItem: Text {
        text:                 root.text
        color:                root.secondary ? Theme.textSecondary : "#FFFFFF"
        font.pixelSize:       Theme.fontMd
        font.family:          Theme.fontFamily
        font.weight:          Font.Medium
        horizontalAlignment:  Text.AlignHCenter
        verticalAlignment:    Text.AlignVCenter
    }

    MouseArea {
        anchors.fill: parent
        cursorShape:  Qt.PointingHandCursor
        onClicked:    root.clicked()
    }
}
