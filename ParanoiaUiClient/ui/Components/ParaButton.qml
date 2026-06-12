import QtQuick
import QtQuick.Controls
import ParanoiaUiClient
Button {
    id: root

    property bool secondary: false
    property bool destructive: false

    implicitHeight: 46
    implicitWidth: 200

    background: Rectangle {
        radius: 20          // скруглённая пилюля (в едином стиле)
        color: {
            if (!root.enabled)     return Theme.bgCard
            if (root.destructive)  return root.hovered ? Theme.error : Theme.errorBg
            if (root.secondary)    return root.hovered ? Theme.bgCard : Theme.bgSecondary
            return root.hovered ? Theme.accentHover : Theme.accent
        }
        border.width: root.secondary || root.destructive ? 1 : 0
        border.color: root.destructive ? Theme.error : root.hovered ? Theme.accent : Theme.border
        Behavior on color { ColorAnimation { duration: 120 } }

        // Угловые акценты-чёрточки утоплены от краёв на радиус скругления и со
        // скруглёнными концами — чтобы не торчать за углы пилюли.
        Rectangle {
            width: parent.width * .34
            height: 2
            radius: 1
            anchors.left: parent.left
            anchors.leftMargin: 20
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 1
            color: root.secondary ? Theme.accentDim : Theme.bgDark
            opacity: root.enabled ? .9 : .25
        }

        Rectangle {
            width: 18
            height: 2
            radius: 1
            anchors.right: parent.right
            anchors.rightMargin: 20
            anchors.top: parent.top
            anchors.topMargin: 1
            color: root.destructive ? Theme.error : Theme.accentHover
            opacity: root.hovered && root.enabled ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 90 } }
        }
    }

    contentItem: Text {
        text:                 root.text
        color:                !root.enabled ? Theme.textHint : root.secondary ? Theme.textSecondary : Theme.textPrimary
        font.pixelSize:       Theme.fontMd
        font.family:          Theme.fontFamily
        font.weight:          Font.DemiBold
        horizontalAlignment:  Text.AlignHCenter
        verticalAlignment:    Text.AlignVCenter
    }

    MouseArea {
        anchors.fill: parent
        cursorShape:  Qt.PointingHandCursor
        enabled:      root.enabled
        onClicked:    root.clicked()
    }
}
