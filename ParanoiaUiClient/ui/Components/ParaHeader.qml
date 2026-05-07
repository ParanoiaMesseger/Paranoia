import QtQuick
import QtQuick.Layouts
import ParanoiaUiClient
Rectangle {
    id: root
    height:      56
    color:       Theme.bgDark

    property string title: ""
    property bool   showBack: true

    signal backClicked()

    Rectangle {
        anchors.bottom: parent.bottom
        width:  parent.width
        height: 2
        color:  Theme.accentDim
    }

    Rectangle {
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        width:  root.width * .28
        height: 2
        color:  Theme.accent
    }

    RowLayout {
        anchors.fill:        parent
        anchors.leftMargin:  8
        anchors.rightMargin: 16
        spacing:             4

        // Кнопка «Назад»
        Item {
            width:   40
            height:  40
            visible: root.showBack

            Rectangle {
                anchors.centerIn: parent
                width:  36; height: 36
                radius: Theme.radiusSm
                color:  backArea.containsMouse ? Theme.bgCard : "transparent"
                border.width: backArea.containsMouse ? 1 : 0
                border.color: Theme.border
                Behavior on color { ColorAnimation { duration: 120 } }

                Text {
                    anchors.centerIn: parent
                    text:             "←"
                    color:            Theme.accentHover
                    font.pixelSize:   Theme.fontLg
                }

                MouseArea {
                    id:           backArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape:  Qt.PointingHandCursor
                    onClicked:    root.backClicked()
                }
            }
        }

        Text {
            Layout.fillWidth: true
            text:             root.title
            color:            Theme.textPrimary
            font.pixelSize:   Theme.fontLg
            font.family:      Theme.fontFamily
            font.weight:      Font.DemiBold
            elide:            Text.ElideRight
        }
    }
}
