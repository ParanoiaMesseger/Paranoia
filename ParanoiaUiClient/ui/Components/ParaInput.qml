import QtQuick
import QtQuick.Controls
import ParanoiaUiClient
Column {
    id: root
    spacing: 6

    property alias text:        field.text
    property alias placeholder: field.placeholderText
    property alias echoMode:    field.echoMode
    property string label:      ""
    property bool   hasError:   false
    property string errorText:  ""

    signal accepted()

    width: 320

    Text {
        text:           root.label
        color:          field.activeFocus ? Theme.accentHover : Theme.textSecondary
        font.pixelSize: Theme.fontSm
        font.family:    Theme.fontFamily
        visible:        root.label !== ""
        Behavior on color { ColorAnimation { duration: 100 } }
    }

    Rectangle {
        width:  parent.width
        height: 44
        radius: Theme.radiusMd
        color:  Theme.bgInput
        border.color: root.hasError
                      ? Theme.error
                      : field.activeFocus ? Theme.accent : Theme.border
        border.width: 1

        Behavior on border.color { ColorAnimation { duration: 100 } }

        Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            width: field.activeFocus ? parent.width * .42 : 24
            height: 2
            color: root.hasError ? Theme.error : Theme.accent
            opacity: root.hasError || field.activeFocus ? 1 : .35
            Behavior on width { NumberAnimation { duration: 120 } }
            Behavior on opacity { NumberAnimation { duration: 120 } }
        }

        TextField {
            id:                  field
            anchors.fill:        parent
            anchors.margins:     8
            color:               Theme.textPrimary
            font.pixelSize:      Theme.fontMd
            font.family:         Theme.fontFamily
            placeholderTextColor: Theme.textHint
            background:          null
            onAccepted:          root.accepted()

            // ── Убираем системное выделение ──
            selectionColor:      Theme.accentDark
            selectedTextColor:   Theme.textPrimary
        }
    }

    Text {
        text:           root.errorText
        color:          Theme.error
        font.pixelSize: Theme.fontXs
        font.family:    Theme.fontFamily
        visible:        root.hasError && root.errorText !== ""
    }
}
