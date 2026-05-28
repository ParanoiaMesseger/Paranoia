import QtQuick
import ParanoiaUiClient

// Мнемосхема пути звонка. Показывает ДВЕ линии — tx (исходящая) и rx
// (входящая) — потому что media-пути могут быть асимметричными:
// одна сторона может слать direct, другая через TURN. Цвет каждой
// линии независим: зелёный для LAN, голубой для P2P direct,
// жёлтый/оранжевый для TURN, серый пунктир когда путь не определён.
// Бегущие точки = активный media-flow в данном направлении.
//
// API (свойства):
//   txPath:      int       — что мы шлём peer'у (0..4 по CallPath)
//   rxPath:      int       — что мы получаем от peer'а
//   pathLabel:   string    — человекочитаемая подпись для tx
//   turnServer:  string    — имя TURN-сервера (если применимо)
//   active:      bool      — идёт ли media (для анимации точек)

Item {
    id: root
    implicitWidth: 280
    implicitHeight: 90

    property int txPath: 0
    property int rxPath: 0
    property string pathLabel: ""
    property string turnServer: ""
    property bool active: false

    function pathColor(p) {
        if (p === 1) return Theme.success    // LAN — зелёный
        if (p === 2) return "#4FC3F7"         // STUN P2P — голубой
        if (p === 3) return "#FFB74D"         // OurTurn — жёлтый
        if (p === 4) return "#FF8A65"         // BackupTurn — оранжевый
        return Theme.textHint                  // None — серый
    }
    function hasCloud(p) { return p === 3 || p === 4 }

    readonly property color txColor: pathColor(txPath)
    readonly property color rxColor: pathColor(rxPath)
    // Подпись пути формируется из обеих сторон если они отличаются.
    readonly property string composedLabel: {
        if (txPath === 0 && rxPath === 0) return qsTr("Подключение…")
        if (txPath === rxPath) return root.pathLabel
        // Асимметрия — показываем оба.
        const tx = pathName(txPath)
        const rx = pathName(rxPath)
        return qsTr("Tx: %1, Rx: %2").arg(tx).arg(rx)
    }
    function pathName(p) {
        if (p === 0) return qsTr("—")
        if (p === 1) return qsTr("LAN")
        if (p === 2) return qsTr("Direct")
        if (p === 3) return qsTr("TURN")
        if (p === 4) return qsTr("Backup TURN")
        return "?"
    }

    Canvas {
        id: canvas
        anchors.fill: parent
        anchors.bottomMargin: 20
        antialiasing: true

        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()

        function drawPhone(ctx, x, y, w, h, color) {
            ctx.strokeStyle = color
            ctx.fillStyle = Theme.bgPrimary
            ctx.lineWidth = 1.6
            const r = 3.5
            ctx.beginPath()
            ctx.moveTo(x + r, y)
            ctx.lineTo(x + w - r, y)
            ctx.quadraticCurveTo(x + w, y, x + w, y + r)
            ctx.lineTo(x + w, y + h - r)
            ctx.quadraticCurveTo(x + w, y + h, x + w - r, y + h)
            ctx.lineTo(x + r, y + h)
            ctx.quadraticCurveTo(x, y + h, x, y + h - r)
            ctx.lineTo(x, y + r)
            ctx.quadraticCurveTo(x, y, x + r, y)
            ctx.closePath()
            ctx.fill()
            ctx.stroke()
            ctx.fillStyle = color
            ctx.globalAlpha = 0.15
            ctx.fillRect(x + 2.5, y + 4, w - 5, h - 8)
            ctx.globalAlpha = 1.0
            ctx.fillRect(x + w / 2 - 3, y + 2, 6, 1)
            ctx.beginPath()
            ctx.arc(x + w / 2, y + h - 2.5, 1, 0, Math.PI * 2)
            ctx.fill()
        }

        function drawCloud(ctx, cx, cy, color) {
            ctx.fillStyle = color
            ctx.strokeStyle = color
            ctx.lineWidth = 1
            ctx.beginPath()
            ctx.arc(cx - 5, cy - 1, 4, Math.PI, 0, false)
            ctx.arc(cx, cy - 3.5, 5, Math.PI, 0, false)
            ctx.arc(cx + 5, cy - 1, 4, Math.PI, 0, false)
            ctx.lineTo(cx - 9, cy + 3)
            ctx.closePath()
            ctx.fill()
        }

        function drawArrowLine(ctx, fromX, fromY, toX, toY, color, dashed, hasCloud) {
            ctx.strokeStyle = color
            ctx.lineWidth = 2.5
            ctx.lineCap = "round"
            ctx.setLineDash(dashed ? [4, 4] : [])
            ctx.beginPath()
            ctx.moveTo(fromX, fromY)
            if (hasCloud) {
                const cx = (fromX + toX) / 2
                const dx = toX > fromX ? 1 : -1
                ctx.lineTo(cx - 10 * dx, fromY)
                ctx.moveTo(cx + 10 * dx, toY)
                ctx.lineTo(toX, toY)
            } else {
                ctx.lineTo(toX, toY)
            }
            ctx.stroke()
            ctx.setLineDash([])
            // Стрелочный наконечник (всегда у destination'а).
            ctx.beginPath()
            const ang = Math.atan2(toY - fromY, toX - fromX)
            const ah = 6
            ctx.moveTo(toX, toY)
            ctx.lineTo(toX - ah * Math.cos(ang - Math.PI / 6), toY - ah * Math.sin(ang - Math.PI / 6))
            ctx.moveTo(toX, toY)
            ctx.lineTo(toX - ah * Math.cos(ang + Math.PI / 6), toY - ah * Math.sin(ang + Math.PI / 6))
            ctx.stroke()
            if (hasCloud) {
                drawCloud(ctx, (fromX + toX) / 2, (fromY + toY) / 2, color)
            }
        }

        onPaint: {
            const ctx = getContext("2d")
            ctx.reset()
            const W = width
            const H = height
            const phoneW = 22
            const phoneH = 34
            // Две горизонтальные линии: tx сверху, rx снизу.
            const yTx = H / 2 - 9
            const yRx = H / 2 + 9
            const leftX = 4
            const rightX = W - phoneW - 4
            const lineLeft = leftX + phoneW + 6
            const lineRight = rightX - 6

            // Tx: слева (me) → справа (peer)
            drawArrowLine(ctx, lineLeft, yTx, lineRight, yTx,
                          root.txColor, root.txPath === 0, hasCloud(root.txPath))
            // Rx: справа (peer) → слева (me)
            drawArrowLine(ctx, lineRight, yRx, lineLeft, yRx,
                          root.rxColor, root.rxPath === 0, hasCloud(root.rxPath))

            // Смартфоны центрируем по вертикали ниже обеих линий
            drawPhone(ctx, leftX, H / 2 - phoneH / 2, phoneW, phoneH, Theme.textPrimary)
            drawPhone(ctx, rightX, H / 2 - phoneH / 2, phoneW, phoneH, Theme.textPrimary)
        }
    }

    // Tx бегущие точки — слева направо
    Item {
        id: txDots
        anchors.fill: canvas
        visible: root.txPath !== 0 && root.active

        readonly property real lineLeft: 4 + 22 + 6
        readonly property real lineRight: width - 22 - 4 - 6
        readonly property real yTx: height / 2 - 9

        Repeater {
            model: 3
            delegate: Rectangle {
                width: 4
                height: 4
                radius: 2
                color: root.txColor
                y: txDots.yTx - height / 2
                SequentialAnimation on x {
                    loops: Animation.Infinite
                    running: txDots.visible
                    PauseAnimation { duration: 600 * index }
                    NumberAnimation {
                        from: txDots.lineLeft
                        to: txDots.lineRight - 8
                        duration: 1800
                        easing.type: Easing.Linear
                    }
                }
            }
        }
    }

    // Rx бегущие точки — справа налево
    Item {
        id: rxDots
        anchors.fill: canvas
        visible: root.rxPath !== 0 && root.active

        readonly property real lineLeft: 4 + 22 + 6
        readonly property real lineRight: width - 22 - 4 - 6
        readonly property real yRx: height / 2 + 9

        Repeater {
            model: 3
            delegate: Rectangle {
                width: 4
                height: 4
                radius: 2
                color: root.rxColor
                y: rxDots.yRx - height / 2
                SequentialAnimation on x {
                    loops: Animation.Infinite
                    running: rxDots.visible
                    PauseAnimation { duration: 600 * index }
                    NumberAnimation {
                        from: rxDots.lineRight - 4
                        to: rxDots.lineLeft + 4
                        duration: 1800
                        easing.type: Easing.Linear
                    }
                }
            }
        }
    }

    Text {
        anchors.top: canvas.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: root.composedLabel
        color: root.txPath === root.rxPath ? root.txColor : Theme.textPrimary
        font.pixelSize: Theme.fontSm
        font.family: Theme.fontFamily
        font.weight: Font.DemiBold
        elide: Text.ElideRight
    }

    onTxPathChanged: canvas.requestPaint()
    onRxPathChanged: canvas.requestPaint()
}
