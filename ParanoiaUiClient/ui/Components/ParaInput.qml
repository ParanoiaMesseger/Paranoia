import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import ParanoiaUiClient

Column {
    id: root
    spacing: 6

    property alias text: field.text
    property alias placeholder: field.placeholderText
    property alias echoMode: field.echoMode
    property string label: ""
    property bool hasError: false
    property string errorText: ""
    property int pasteButtonWidth: 28
    property int pasteButtonHeight: 20

    signal accepted

    width: 320

    Text {
        text: root.label
        color: field.activeFocus ? Theme.accentHover : Theme.textSecondary
        font.pixelSize: Theme.fontSm
        font.family: Theme.fontFamily
        visible: root.label !== ""
        Behavior on color {
            ColorAnimation {
                duration: 100
            }
        }
    }

    Rectangle {
        width: parent.width
        height: 44
        radius: Theme.radiusMd
        color: Theme.bgInput
        border.color: root.hasError ? Theme.error : field.activeFocus ? Theme.accent : Theme.border
        border.width: 1

        Behavior on border.color {
            ColorAnimation {
                duration: 100
            }
        }

        Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            width: field.activeFocus ? parent.width * .42 : 24
            height: 2
            color: root.hasError ? Theme.error : Theme.accent
            opacity: root.hasError || field.activeFocus ? 1 : .35
            Behavior on width {
                NumberAnimation {
                    duration: 120
                }
            }
            Behavior on opacity {
                NumberAnimation {
                    duration: 120
                }
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
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: Theme.textPrimary
                font.pixelSize: Theme.fontMd
                font.family: Theme.fontFamily
                placeholderTextColor: Theme.textHint
                inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase
                background: null
                onAccepted: root.accepted()

                // ── Убираем системное выделение ──
                selectionColor: Theme.accentDark
                selectedTextColor: Theme.textPrimary

                // ── Фикс Android Material: сбрасываем паддинги под floating label ──
                topPadding: 0
                bottomPadding: 0
                leftPadding: 0
                rightPadding: 0
            }

            Rectangle {
                implicitWidth: root.pasteButtonWidth
                implicitHeight: root.pasteButtonHeight
                width: root.pasteButtonWidth
                height: root.pasteButtonHeight
                radius: Theme.radiusSm
                color: pasteArea.containsMouse ? Theme.bgButton : "transparent"

                Canvas {
                    id: pasteIcon
                    anchors.centerIn: parent
                    width: 14
                    height: 14
                    antialiasing: true

                    property bool hovered: pasteArea.containsMouse
                    onHoveredChanged: requestPaint()

                    onPaint: {
                        const ctx = getContext("2d");
                        ctx.clearRect(0, 0, width, height);
                        ctx.lineWidth = 1.5;
                        ctx.lineJoin = "round";
                        ctx.lineCap = "round";
                        ctx.strokeStyle = Theme.accentHover;

                        // --- Основной прямоугольник буфера ---
                        ctx.fillStyle = hovered ? Theme.bgButton : "transparent";
                        ctx.beginPath();
                        ctx.moveTo(width * 0.22, height * 0.22);
                        ctx.lineTo(width * 0.22, height * 0.92);
                        ctx.lineTo(width * 0.78, height * 0.92);
                        ctx.lineTo(width * 0.78, height * 0.22);
                        ctx.lineTo(width * 0.64, height * 0.22);
                        // вырез под ушко (правая сторона)
                        ctx.lineTo(width * 0.64, height * 0.14);
                        ctx.lineTo(width * 0.36, height * 0.14);
                        ctx.lineTo(width * 0.36, height * 0.22);
                        ctx.closePath();
                        ctx.fill();
                        ctx.stroke();

                        // --- Ушко (клипборд-таб) сверху ---
                        ctx.fillStyle = Theme.bgBase;
                        ctx.beginPath();
                        ctx.moveTo(width * 0.38, height * 0.08);
                        ctx.lineTo(width * 0.62, height * 0.08);
                        ctx.lineTo(width * 0.62, height * 0.28);
                        ctx.lineTo(width * 0.38, height * 0.28);
                        ctx.closePath();
                        ctx.fill();
                        ctx.stroke();

                        // --- Линии-строки внутри (имитация текста) ---
                        ctx.beginPath();
                        ctx.moveTo(width * 0.34, height * 0.50);
                        ctx.lineTo(width * 0.66, height * 0.50);
                        ctx.stroke();

                        ctx.beginPath();
                        ctx.moveTo(width * 0.34, height * 0.65);
                        ctx.lineTo(width * 0.66, height * 0.65);
                        ctx.stroke();

                        ctx.beginPath();
                        ctx.moveTo(width * 0.34, height * 0.80);
                        ctx.lineTo(width * 0.54, height * 0.80);
                        ctx.stroke();
                    }
                }

                MouseArea {
                    id: pasteArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        copyHelper.text = "";
                        copyHelper.paste();
                        field.text = copyHelper.text;
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
