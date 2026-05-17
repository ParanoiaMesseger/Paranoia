import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import ParanoiaUiClient


Column {
    id: root
    spacing: 6

    property string text: ""
    property string placeholder: ""
    property alias echoMode: field.echoMode
    property string label: ""
    property bool hasError: false
    property string errorText: ""
    property int pasteButtonWidth: 28
    property int pasteButtonHeight: 20
    property int lineCount: 1
    property bool predictiveText: false
    property int inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoAutoUppercase | (predictiveText ? 0 : Qt.ImhNoPredictiveText)
    property bool showPasteButton: true

    onTextChanged: {
        if (field.text !== root.text) field.text = root.text
        if (multiField.text !== root.text) multiField.text = root.text
    }

    signal accepted

    width: 320

    readonly property bool _anyFocus: field.activeFocus || multiField.activeFocus

    function selectInputText(input) {
        input.forceActiveFocus()
        Qt.callLater(function() { input.selectAll() })
    }

    Text {
        text: root.label
        color: root._anyFocus ? Theme.accentHover : Theme.textSecondary
        font.pixelSize: Theme.fontSm
        font.family: Theme.fontFamily
        visible: root.label !== ""
        Behavior on color {
            ColorAnimation { duration: 100 }
        }
    }

    Rectangle {
        width: parent.width
        height: root.lineCount <= 1 ? 44 : root.lineCount * 22 + 16
        radius: Theme.radiusMd
        color: Theme.bgInput
        border.color: root.hasError ? Theme.error : root._anyFocus ? Theme.accent : Theme.border
        border.width: 1

        Behavior on border.color {
            ColorAnimation { duration: 100 }
        }

        Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            width: root._anyFocus ? parent.width * .42 : 24
            height: 2
            color: root.hasError ? Theme.error : Theme.accent
            opacity: root.hasError || root._anyFocus ? 1 : .35
            Behavior on width {
                NumberAnimation { duration: 120 }
            }
            Behavior on opacity {
                NumberAnimation { duration: 120 }
            }
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            anchors.topMargin: 8
            anchors.bottomMargin: 8
            spacing: 6

            TextField {
                id: field
                visible: root.lineCount <= 1
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: Theme.textPrimary
                font.pixelSize: Theme.fontMd
                font.family: Theme.fontFamily
                placeholderText: root.placeholder
                placeholderTextColor: Theme.textHint
                inputMethodHints: root.inputMethodHints
                background: null
                selectionColor: Theme.accentDark
                selectedTextColor: Theme.textPrimary
                topPadding: 0
                bottomPadding: 0
                leftPadding: 0
                rightPadding: 0
                onAccepted: root.accepted()
                onTextChanged: if (root.lineCount <= 1 && root.text !== text) root.text = text

                // Долгое нажатие/двойной клик — выделить весь текст
                TapHandler {
                    property bool selectAllOnRelease: false

                    gesturePolicy: TapHandler.DragThreshold
                    longPressThreshold: 0.4

                    onLongPressed: {
                        selectAllOnRelease = true
                        root.selectInputText(field)
                    }
                    onDoubleTapped: root.selectInputText(field)
                    onPressedChanged: if (!pressed && selectAllOnRelease) {
                        selectAllOnRelease = false
                        root.selectInputText(field)
                    }
                }
            }

            TextArea {
                id: multiField
                visible: root.lineCount > 1
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: Theme.textPrimary
                font.pixelSize: Theme.fontMd
                font.family: Theme.fontFamily
                placeholderText: root.placeholder
                placeholderTextColor: Theme.textHint
                inputMethodHints: root.inputMethodHints
                wrapMode: TextEdit.Wrap
                background: null
                selectionColor: Theme.accentDark
                selectedTextColor: Theme.textPrimary
                topPadding: 0
                bottomPadding: 0
                leftPadding: 0
                rightPadding: 0
                onTextChanged: if (root.lineCount > 1 && root.text !== text) root.text = text

                // Долгое нажатие/двойной клик — выделить весь текст
                TapHandler {
                    property bool selectAllOnRelease: false

                    gesturePolicy: TapHandler.DragThreshold
                    longPressThreshold: 0.6

                    onLongPressed: {
                        selectAllOnRelease = true
                        root.selectInputText(multiField)
                    }
                    onDoubleTapped: root.selectInputText(multiField)
                    onPressedChanged: if (!pressed && selectAllOnRelease) {
                        selectAllOnRelease = false
                        root.selectInputText(multiField)
                    }
                }
            }

            // Кнопка вставки с 3D-анимацией
            Item {
                visible: root.showPasteButton
                implicitWidth: root.showPasteButton ? root.pasteButtonWidth : 0
                implicitHeight: root.showPasteButton ? root.pasteButtonHeight : 0
                Layout.preferredWidth: implicitWidth
                Layout.preferredHeight: implicitHeight
                Layout.alignment: Qt.AlignTop

                // --- Состояния анимации ---
                property bool animating: false
                property bool showCheck: false

                // Таймер: скрыть галочку через 1.2с и вернуть иконку
                Timer {
                    id: resetTimer
                    interval: 1200
                    repeat: false
                    onTriggered: {
                        // Второй полуоборот — возврат иконки
                        returnRotation.start()
                    }
                }

                // Фон кнопки
                Rectangle {
                    anchors.fill: parent
                    radius: Theme.radiusSm
                    color: pasteArea.containsMouse ? Theme.bgButton : "transparent"
                    Behavior on color { ColorAnimation { duration: 100 } }
                }

                // Иконка вставки (Canvas)
                Canvas {
                    id: pasteIcon
                    anchors.centerIn: parent
                    width: 20
                    height: 20
                    antialiasing: true
                    visible: !parent.showCheck

                    property bool hovered: pasteArea.containsMouse
                    onHoveredChanged: requestPaint()

                    transform: Rotation {
                        id: pasteIconRotation
                        origin.x: pasteIcon.width / 2
                        origin.y: pasteIcon.height / 2
                        axis { x: 0; y: 1; z: 0 }
                        angle: 0
                    }

                    onPaint: {
                        const ctx = getContext("2d")
                        ctx.clearRect(0, 0, width, height)
                        ctx.lineWidth = 1.5
                        ctx.lineJoin = "round"
                        ctx.lineCap = "round"
                        ctx.strokeStyle = Theme.accentHover

                        ctx.fillStyle = hovered ? Theme.bgButton : "transparent"
                        ctx.beginPath()
                        ctx.moveTo(width * 0.22, height * 0.22)
                        ctx.lineTo(width * 0.22, height * 0.92)
                        ctx.lineTo(width * 0.78, height * 0.92)
                        ctx.lineTo(width * 0.78, height * 0.22)
                        ctx.lineTo(width * 0.64, height * 0.22)
                        ctx.lineTo(width * 0.64, height * 0.14)
                        ctx.lineTo(width * 0.36, height * 0.14)
                        ctx.lineTo(width * 0.36, height * 0.22)
                        ctx.closePath()
                        ctx.fill()
                        ctx.stroke()

                        ctx.fillStyle = Theme.bgInput
                        ctx.beginPath()
                        ctx.moveTo(width * 0.38, height * 0.08)
                        ctx.lineTo(width * 0.62, height * 0.08)
                        ctx.lineTo(width * 0.62, height * 0.28)
                        ctx.lineTo(width * 0.38, height * 0.28)
                        ctx.closePath()
                        ctx.fill()
                        ctx.stroke()

                        ctx.beginPath()
                        ctx.moveTo(width * 0.34, height * 0.50)
                        ctx.lineTo(width * 0.66, height * 0.50)
                        ctx.stroke()

                        ctx.beginPath()
                        ctx.moveTo(width * 0.34, height * 0.65)
                        ctx.lineTo(width * 0.66, height * 0.65)
                        ctx.stroke()

                        ctx.beginPath()
                        ctx.moveTo(width * 0.34, height * 0.80)
                        ctx.lineTo(width * 0.54, height * 0.80)
                        ctx.stroke()
                    }
                }

                CheckMark {
                    id: checkIcon
                    anchors.centerIn: parent
                    visible: parent.showCheck
                }

                // Анимация: первый полуоборот (иконка уходит)
                SequentialAnimation {
                    id: forwardRotation

                    NumberAnimation {
                        target: pasteIconRotation
                        property: "angle"
                        from: 0
                        to: 90
                        duration: 150
                        easing.type: Easing.InCubic
                    }
                    ScriptAction {
                        script: {
                            // Переключаем на галочку в момент "перпендикулярно"
                            pasteIcon.parent.showCheck = true
                            checkIcon.rotY = -90
                            resetTimer.start()
                        }
                    }
                    NumberAnimation {
                        target: checkIcon
                        property: "rotY"
                        from: -90; to: 0
                        duration: 150
                        easing.type: Easing.OutCubic
                    }
                }

                // Анимация: возврат к иконке
                SequentialAnimation {
                    id: returnRotation

                    NumberAnimation {
                        target: checkIcon
                        property: "rotY"
                        from: 0;to: 90
                        duration: 150
                        easing.type: Easing.InCubic
                    }
                    ScriptAction {
                        script: {
                            pasteIcon.parent.showCheck = false
                            pasteIconRotation.angle = -90
                        }
                    }
                    NumberAnimation {
                        target: pasteIconRotation
                        property: "angle"
                        from: -90
                        to: 0
                        duration: 150
                        easing.type: Easing.OutCubic
                    }
                    onStopped: pasteIcon.parent.animating = false
                }

                MouseArea {
                    id: pasteArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (parent.animating) return

                        // Вставка из буфера обмена
                        copyHelper.text = ""
                        copyHelper.paste()
                        const pasted = copyHelper.text
                        if (root.lineCount > 1) multiField.text = pasted
                        else field.text = pasted

                        // Запустить анимацию
                        parent.animating = true
                        forwardRotation.start()
                    }
                }
            }
        }

        TextEdit {
            id: copyHelper
            visible: false
        }
    }

    Text {
        text: root.errorText
        color: Theme.error
        font.pixelSize: Theme.fontXs
        font.family: Theme.fontFamily
        visible: root.hasError && root.errorText !== ""
    }
}
