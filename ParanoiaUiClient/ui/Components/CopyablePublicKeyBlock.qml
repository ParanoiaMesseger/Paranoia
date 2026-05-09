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

    signal copied(string keyText)

    implicitHeight: keyLayout.implicitHeight + root.topPadding + root.bottomPadding
    color: root.backgroundColor
    radius: Theme.radiusSm
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
                elide: root.keyElide
            }

            Rectangle {
                implicitWidth: root.copyButtonWidth
                implicitHeight: root.copyButtonHeight
                width: root.copyButtonWidth
                height: root.copyButtonHeight
                radius: Theme.radiusSm
                color: copyArea.containsMouse && root.keyText.length > 0 ? Theme.bgButton : "transparent"
                opacity: root.keyText.length > 0 ? 1 : 0.5

                Canvas {
                    anchors.centerIn: parent
                    width: 20
                    height: 20
                    antialiasing: true

                    property bool hovered: copyArea.containsMouse
                    onHoveredChanged: requestPaint()

                    onPaint: {
                        const ctx = getContext("2d");
                        ctx.clearRect(0, 0, width, height);
                        ctx.lineWidth = 1.5;
                        ctx.lineJoin = "round";

                        // --- Задний лист (смещён вправо-вниз) ---
                        ctx.strokeStyle = Theme.accentHover;
                        ctx.fillStyle = hovered ? Theme.bgButton : "transparent";
                        ctx.beginPath();
                        ctx.moveTo(width * 0.36, height * 0.28);
                        ctx.lineTo(width * 0.72, height * 0.28);
                        ctx.lineTo(width * 0.86, height * 0.44);
                        ctx.lineTo(width * 0.86, height * 0.92);
                        ctx.lineTo(width * 0.36, height * 0.92);
                        ctx.closePath();
                        ctx.fill();
                        ctx.stroke();
                        // загнутый уголок заднего листа
                        ctx.beginPath();
                        ctx.moveTo(width * 0.72, height * 0.28);
                        ctx.lineTo(width * 0.72, height * 0.44);
                        ctx.lineTo(width * 0.86, height * 0.44);
                        ctx.stroke();

                        // --- Передний лист (смещён влево-вверх) ---
                        ctx.strokeStyle = Theme.accentHover;
                        ctx.fillStyle = Theme.bgBase;   // фон мессенджера — перекрывает задний лист
                        ctx.beginPath();
                        ctx.moveTo(width * 0.14, height * 0.08);
                        ctx.lineTo(width * 0.58, height * 0.08);
                        ctx.lineTo(width * 0.72, height * 0.24);
                        ctx.lineTo(width * 0.72, height * 0.72);
                        ctx.lineTo(width * 0.14, height * 0.72);
                        ctx.closePath();
                        ctx.fill();
                        ctx.stroke();
                        // загнутый уголок переднего листа
                        ctx.beginPath();
                        ctx.moveTo(width * 0.58, height * 0.08);
                        ctx.lineTo(width * 0.58, height * 0.24);
                        ctx.lineTo(width * 0.72, height * 0.24);
                        ctx.stroke();
                    }
                }

                MouseArea {
                    id: copyArea
                    anchors.fill: parent
                    enabled: root.keyText.length > 0
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        copyHelper.text = root.keyText;
                        copyHelper.selectAll();
                        copyHelper.copy();
                        root.copied(root.keyText);
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
