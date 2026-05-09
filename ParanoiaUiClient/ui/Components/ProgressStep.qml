import QtQuick
import ParanoiaUiClient

Row {
    spacing: 12
    property string stepText: ""
    property int    status:   0   // 0=pending, 1=running, 2=done, 3=error

    Rectangle {
        width:  20; height: 20
        radius: Theme.radiusSm
        color: {
            if (status === 2) return Theme.success
            if (status === 3) return Theme.error
            if (status === 1) return Theme.accent
            return Theme.bgInput
        }
        border.width: 1
        border.color: status === 0 ? Theme.border : Theme.accentHover
        Behavior on color { ColorAnimation { duration: 200 } }

        Text {
            anchors.centerIn: parent
            text: {
                if (status === 2) return "OK"
                if (status === 3) return "X"
                if (status === 1) return ".."
                return ""
            }
            color:          Theme.textPrimary
            font.pixelSize: 8
            font.family:    Theme.monoFamily
        }
    }

    Text {
        text:           stepText
        color:          status === 0 ? Theme.textHint : Theme.textPrimary
        font.pixelSize: Theme.fontSm
        font.family:    Theme.fontFamily
        anchors.verticalCenter: parent.children[0].verticalCenter
        Behavior on color { ColorAnimation { duration: 200 } }
    }
}
