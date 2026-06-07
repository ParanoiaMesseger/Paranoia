import QtQuick
import QtQuick.Layouts
import ParanoiaUiClient

Rectangle {
    id: root
    radius: Theme.radiusMd
    color: outgoing ? Qt.darker(Theme.bgButton, 1.18) : Theme.bgCard
    border.width: 1
    border.color: outgoing ? Qt.darker(Theme.bgButton, 1.35) : Theme.border
    clip: true

    property string author: ""
    property string previewText: ""
    property bool outgoing: false
    property bool closeVisible: false
    property bool interactive: false
    property color authorColor: outgoing
                                ? (Theme.darkMode ? Theme.accentHover : Qt.lighter(Theme.accentHover, 1.15))
                                : Theme.accentHover
    property color previewColor: outgoing ? Theme.messageMetaOutgoing : Theme.textSecondary

    signal closeClicked()
    signal clicked()

    implicitWidth: Math.max(180, Math.max(authorLabel.implicitWidth, previewLabel.implicitWidth)
                                  + 30 + (closeVisible ? 34 : 0))
    implicitHeight: Math.max(44, replyColumn.implicitHeight + 12)

    Rectangle {
        anchors.left: parent.left
        anchors.leftMargin: 1
        anchors.top: parent.top
        anchors.topMargin: 4
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 4
        width: 3
        radius: 1.5
        color: Theme.accentHover
    }

    Column {
        id: replyColumn
        anchors.left: parent.left
        anchors.leftMargin: 12
        anchors.right: closeVisible ? closeButton.left : parent.right
        anchors.rightMargin: closeVisible ? 6 : 10
        anchors.verticalCenter: parent.verticalCenter
        spacing: 2

        Text {
            id: authorLabel
            width: replyColumn.width
            text: root.author.length > 0 ? root.author : qsTr("Сообщение")
            color: root.authorColor
            font.pixelSize: Theme.fontXs
            font.family: Theme.fontFamily
            font.weight: Font.DemiBold
            elide: Text.ElideRight
            maximumLineCount: 1
        }

        Text {
            id: previewLabel
            width: replyColumn.width
            text: root.previewText.length > 0 ? root.previewText : qsTr("Сообщение недоступно")
            color: root.previewColor
            font.pixelSize: Theme.fontSm
            font.family: Theme.fontFamily
            elide: Text.ElideRight
            maximumLineCount: 1
            wrapMode: Text.NoWrap
        }
    }

    MouseArea {
        id: clickArea
        anchors.fill: parent
        hoverEnabled: root.interactive
        enabled: root.interactive
        cursorShape: root.interactive ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: root.clicked()
    }

    Rectangle {
        id: closeButton
        anchors.right: parent.right
        anchors.rightMargin: 6
        anchors.verticalCenter: parent.verticalCenter
        width: 28
        height: 28
        radius: Theme.radiusSm
        visible: root.closeVisible
        color: closeArea.containsMouse ? Theme.bgInput : "transparent"

        AppIcon {
            anchors.centerIn: parent
            width: 14
            height: 14
            name: "close"
            iconColor: Theme.textSecondary
            strokeWidth: 2.2
        }

        MouseArea {
            id: closeArea
            anchors.fill: parent
            hoverEnabled: true
            onClicked: root.closeClicked()
        }
    }
}
