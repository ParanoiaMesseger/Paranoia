import QtQuick
import QtQuick.Layouts
import ParanoiaUiClient

Rectangle {
    id: root

    property string title: ""
    property string keyText: ""
    property string emptyText: "—"
    property color backgroundColor: Theme.bgSecondary
    property color borderColor: Theme.border
    property color titleColor: Theme.textSecondary
    property color keyColor: Theme.textPrimary
    property string keyFontFamily: Theme.monoFamily
    property int titleFontSize: Theme.fontXs
    property int keyFontSize: 10
    property int keyElide: Text.ElideMiddle
    property int leftPadding: 12
    property int rightPadding: 8
    property int topPadding: 8
    property int bottomPadding: 8
    property int contentSpacing: 4
    property int copyButtonWidth: 28
    property int copyButtonHeight: 20
    property int lineCount: 1
    property string copyText: ""

    signal copied(string keyText)

    implicitHeight: keyLayout.implicitHeight + root.topPadding + root.bottomPadding
    color: root.backgroundColor
    radius: 16          // скруглённый блок (в едином стиле)
    border.color: root.borderColor
    clip: true

    ColumnLayout {
        id: keyLayout
        anchors.fill: parent
        anchors.leftMargin: root.leftPadding
        anchors.rightMargin: root.rightPadding
        anchors.topMargin: root.topPadding
        anchors.bottomMargin: root.bottomPadding
        spacing: root.contentSpacing

        Text {
            Layout.fillWidth: true
            text: root.title
            color: root.titleColor
            font.pixelSize: root.titleFontSize
            font.family: Theme.fontFamily
            wrapMode: Text.WordWrap
            visible: text.length > 0
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 6

            Text {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                text: root.keyText || root.emptyText
                color: root.keyColor
                font.pixelSize: root.keyFontSize
                font.family: root.keyFontFamily
                elide: root.lineCount <= 1 ? root.keyElide : Text.ElideNone
                wrapMode: root.lineCount > 1 ? Text.WrapAnywhere : Text.NoWrap
                maximumLineCount: root.lineCount
            }

            Rectangle {
                id: copyBtn
                implicitWidth: root.copyButtonWidth
                implicitHeight: root.copyButtonHeight
                width: root.copyButtonWidth
                height: root.copyButtonHeight
                radius: height / 2
                color: "transparent"
                opacity: root.keyText.length > 0 ? 1 : 0.5

                property bool copied: false
                property bool showCheck: false

                AppIcon {
                    id: copyCanvas
                    anchors.centerIn: parent
                    width: 20
                    height: 20
                    name: "copy"
                    iconColor: Theme.accentHover
                    fillColor: hovered ? Theme.bgButton : "transparent"
                    secondaryColor: Theme.bgPrimary
                    strokeWidth: 1.5

                    property bool hovered: copyArea.containsMouse

                    visible: !copyBtn.showCheck

                    transform: Rotation {
                        id: copyIconRotation
                        origin.x: copyCanvas.width / 2
                        origin.y: copyCanvas.height / 2
                        axis { x: 0; y: 1; z: 0 }
                        angle: 0
                    }
                }

                CheckMark {
                    id: copyCheckIcon
                    anchors.centerIn: parent
                    width: 20
                    height: 20
                    visible: copyBtn.showCheck
                }

                // Анимация: первый полуоборот (иконка копирования уходит)
                SequentialAnimation {
                    id: forwardRotation

                    NumberAnimation {
                        target: copyIconRotation
                        property: "angle"
                        from: 0
                        to: 90
                        duration: 150
                        easing.type: Easing.InCubic
                    }
                    ScriptAction {
                        script: {
                            copyBtn.showCheck = true;
                            copyCheckIcon.rotY = -90;
                            resetTimer.start();
                        }
                    }
                    NumberAnimation {
                        target: copyCheckIcon
                        property: "rotY"
                        from: -90
                        to: 0
                        duration: 150
                        easing.type: Easing.OutCubic
                    }
                }

                // Анимация: возврат к иконке копирования
                SequentialAnimation {
                    id: returnRotation

                    NumberAnimation {
                        target: copyCheckIcon
                        property: "rotY"
                        from: 0
                        to: 90
                        duration: 150
                        easing.type: Easing.InCubic
                    }
                    ScriptAction {
                        script: {
                            copyBtn.showCheck = false;
                            copyIconRotation.angle = -90;
                        }
                    }
                    NumberAnimation {
                        target: copyIconRotation
                        property: "angle"
                        from: -90
                        to: 0
                        duration: 150
                        easing.type: Easing.OutCubic
                    }
                    onStopped: {
                        copyBtn.copied = false;
                        copyCanvas.requestPaint();
                    }
                }

                // Пауза перед обратным полуоборотом
                Timer {
                    id: resetTimer
                    interval: 1200
                    onTriggered: returnRotation.start()
                }

                MouseArea {
                    id: copyArea
                    anchors.fill: parent
                    enabled: root.keyText.length > 0
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (copyBtn.copied) return;

                        const toCopy = root.copyText.length > 0 ? root.copyText : root.keyText;
                        copyHelper.text = toCopy;
                        copyHelper.selectAll();
                        copyHelper.copy();
                        root.copied(toCopy);

                        copyBtn.copied = true;
                        forwardRotation.start();
                    }
                }
            }
        }
    }

    TextEdit {
        id: copyHelper
        visible: false
    }
}
