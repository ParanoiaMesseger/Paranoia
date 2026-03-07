import QtQuick
import QtQuick.Layouts
import ParanoiaUiClient
Rectangle {
    id: root
    height:      56
    color:       Theme.bgSecondary

    property string title: ""
    property bool   showBack: true

    signal backClicked()

    // нижняя линия-разделитель
    Rectangle {
        anchors.bottom: parent.bottom
        width:  parent.width
        height: 1
        color:  Theme.separator
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
                radius: 18
                color:  backArea.containsMouse ? Theme.bgInput : "transparent"
                Behavior on color { ColorAnimation { duration: 120 } }

                Text {
                    anchors.centerIn: parent
                    text:             "←"
                    color:            Theme.accent
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
            font.weight:      Font.Medium
            elide:            Text.ElideRight
        }
    }
}
