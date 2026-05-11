import QtQuick
import QtQuick.VirtualKeyboard

InputPanel {
    id: panel
    x: 0
    y: active ? parent.height - height : parent.height
    width: parent.width
    visible: active || y < parent.height

    Behavior on y {
        NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }
}