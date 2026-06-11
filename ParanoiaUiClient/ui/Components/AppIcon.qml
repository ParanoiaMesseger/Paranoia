import QtQuick
import ParanoiaUiClient

Canvas {
    id: root
    width: 20
    height: 20
    antialiasing: true

    property string name: ""
    property color iconColor: Theme.textPrimary
    property color fillColor: "transparent"
    property color secondaryColor: "transparent"
    property real strokeWidth: 1.6

    onNameChanged: requestPaint()
    onIconColorChanged: requestPaint()
    onFillColorChanged: requestPaint()
    onSecondaryColorChanged: requestPaint()
    onStrokeWidthChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    onPaint: {
        const ctx = getContext("2d")
        ctx.setTransform(1, 0, 0, 1, 0, 0)
        ctx.clearRect(0, 0, width, height)
        ctx.lineWidth = strokeWidth
        ctx.lineCap = "round"
        ctx.lineJoin = "round"
        ctx.strokeStyle = iconColor
        ctx.fillStyle = iconColor
        ctx.scale(width / 24, height / 24)

        if (name === "phone") {
            ctx.beginPath()
            ctx.moveTo(6.6, 10.8)
            ctx.bezierCurveTo(7.8, 13.2, 9.8, 15.2, 12.2, 16.4)
            ctx.lineTo(14.0, 14.6)
            ctx.bezierCurveTo(14.3, 14.3, 14.7, 14.2, 15.0, 14.4)
            ctx.bezierCurveTo(16.1, 14.8, 17.3, 15.0, 18.5, 15.0)
            ctx.bezierCurveTo(19.3, 15.0, 20.0, 15.7, 20.0, 16.5)
            ctx.lineTo(20.0, 19.5)
            ctx.bezierCurveTo(20.0, 20.3, 19.3, 21.0, 18.5, 21.0)
            ctx.bezierCurveTo(9.9, 21.0, 3.0, 14.1, 3.0, 5.5)
            ctx.bezierCurveTo(3.0, 4.7, 3.7, 4.0, 4.5, 4.0)
            ctx.lineTo(7.5, 4.0)
            ctx.bezierCurveTo(8.3, 4.0, 9.0, 4.7, 9.0, 5.5)
            ctx.bezierCurveTo(9.0, 6.7, 9.2, 7.9, 9.6, 9.0)
            ctx.bezierCurveTo(9.8, 9.3, 9.7, 9.7, 9.4, 10.0)
            ctx.closePath()
            ctx.fill()
            return
        }

        if (name === "send") {
            ctx.beginPath()
            ctx.moveTo(5.8, 4.8)
            ctx.lineTo(18.7, 12.0)
            ctx.lineTo(5.8, 19.2)
            ctx.lineTo(8.2, 13.0)
            ctx.lineTo(13.9, 12.0)
            ctx.lineTo(8.2, 11.0)
            ctx.closePath()
            ctx.fill()
            return
        }

        if (name === "file") {
            ctx.lineWidth = strokeWidth
            ctx.strokeStyle = iconColor
            ctx.fillStyle = fillColor
            ctx.beginPath()
            ctx.moveTo(7.2, 4.3)
            ctx.lineTo(14.9, 4.3)
            ctx.lineTo(18.2, 7.7)
            ctx.lineTo(18.2, 19.7)
            ctx.lineTo(7.2, 19.7)
            ctx.closePath()
            ctx.fill()
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(14.9, 4.3)
            ctx.lineTo(14.9, 8.2)
            ctx.lineTo(18.2, 8.2)
            ctx.stroke()
            return
        }

        if (name === "copy") {
            ctx.lineWidth = strokeWidth
            ctx.strokeStyle = iconColor
            ctx.fillStyle = fillColor
            ctx.beginPath()
            ctx.moveTo(8.6, 6.7)
            ctx.lineTo(17.3, 6.7)
            ctx.lineTo(20.6, 10.6)
            ctx.lineTo(20.6, 22.1)
            ctx.lineTo(8.6, 22.1)
            ctx.closePath()
            ctx.fill()
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(17.3, 6.7)
            ctx.lineTo(17.3, 10.6)
            ctx.lineTo(20.6, 10.6)
            ctx.stroke()

            ctx.fillStyle = secondaryColor
            ctx.beginPath()
            ctx.moveTo(3.4, 1.9)
            ctx.lineTo(13.9, 1.9)
            ctx.lineTo(17.3, 5.8)
            ctx.lineTo(17.3, 17.3)
            ctx.lineTo(3.4, 17.3)
            ctx.closePath()
            ctx.fill()
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(13.9, 1.9)
            ctx.lineTo(13.9, 5.8)
            ctx.lineTo(17.3, 5.8)
            ctx.stroke()
            return
        }

        if (name === "paste") {
            ctx.lineWidth = strokeWidth
            ctx.strokeStyle = iconColor
            ctx.fillStyle = fillColor
            ctx.beginPath()
            ctx.moveTo(5.3, 5.3)
            ctx.lineTo(5.3, 22.1)
            ctx.lineTo(18.7, 22.1)
            ctx.lineTo(18.7, 5.3)
            ctx.lineTo(15.4, 5.3)
            ctx.lineTo(15.4, 3.4)
            ctx.lineTo(8.6, 3.4)
            ctx.lineTo(8.6, 5.3)
            ctx.closePath()
            ctx.fill()
            ctx.stroke()

            ctx.fillStyle = secondaryColor
            ctx.beginPath()
            ctx.moveTo(9.1, 1.9)
            ctx.lineTo(14.9, 1.9)
            ctx.lineTo(14.9, 6.7)
            ctx.lineTo(9.1, 6.7)
            ctx.closePath()
            ctx.fill()
            ctx.stroke()

            ctx.beginPath()
            ctx.moveTo(8.2, 12.0)
            ctx.lineTo(15.8, 12.0)
            ctx.moveTo(8.2, 15.6)
            ctx.lineTo(15.8, 15.6)
            ctx.moveTo(8.2, 19.2)
            ctx.lineTo(13.0, 19.2)
            ctx.stroke()
            return
        }

        if (name === "download") {
            ctx.beginPath()
            ctx.moveTo(12, 4)
            ctx.lineTo(12, 15)
            ctx.moveTo(7, 10)
            ctx.lineTo(12, 15)
            ctx.lineTo(17, 10)
            ctx.moveTo(5, 20)
            ctx.lineTo(19, 20)
            ctx.stroke()
            return
        }

        if (name === "plus") {
            ctx.beginPath()
            ctx.moveTo(12, 5)
            ctx.lineTo(12, 19)
            ctx.moveTo(5, 12)
            ctx.lineTo(19, 12)
            ctx.stroke()
            return
        }

        if (name === "minus") {
            ctx.beginPath()
            ctx.moveTo(5, 12)
            ctx.lineTo(19, 12)
            ctx.stroke()
            return
        }

        if (name === "close") {
            ctx.beginPath()
            ctx.moveTo(6.5, 6.5)
            ctx.lineTo(17.5, 17.5)
            ctx.moveTo(17.5, 6.5)
            ctx.lineTo(6.5, 17.5)
            ctx.stroke()
            return
        }

        if (name === "chevronLeft") {
            ctx.beginPath()
            ctx.moveTo(15.5, 5)
            ctx.lineTo(8.5, 12)
            ctx.lineTo(15.5, 19)
            ctx.stroke()
            return
        }

        if (name === "chevronRight") {
            ctx.beginPath()
            ctx.moveTo(8.5, 5)
            ctx.lineTo(15.5, 12)
            ctx.lineTo(8.5, 19)
            ctx.stroke()
            return
        }

        if (name === "arrowLeft") {
            ctx.beginPath()
            ctx.moveTo(19, 12)
            ctx.lineTo(5, 12)
            ctx.moveTo(12, 5)
            ctx.lineTo(5, 12)
            ctx.lineTo(12, 19)
            ctx.stroke()
            return
        }

        if (name === "moreVertical") {
            ctx.fillStyle = iconColor
            for (let i = 0; i < 3; ++i) {
                ctx.beginPath()
                ctx.arc(12, 5 + i * 7, 1.8, 0, Math.PI * 2)
                ctx.fill()
            }
            return
        }

        if (name === "importExport") {
            ctx.beginPath()
            ctx.moveTo(5, 8)
            ctx.lineTo(18, 8)
            ctx.moveTo(15, 5)
            ctx.lineTo(18, 8)
            ctx.lineTo(15, 11)

            ctx.moveTo(19, 16)
            ctx.lineTo(6, 16)
            ctx.moveTo(9, 13)
            ctx.lineTo(6, 16)
            ctx.lineTo(9, 19)
            ctx.stroke()
            return
        }

        if (name === "refresh") {
            ctx.beginPath()
            ctx.arc(12, 12, 7.9, Math.PI * 0.2, Math.PI * 1.7, false)
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(14.6, 1.8)
            ctx.lineTo(16.7, 5.6)
            ctx.lineTo(12.9, 7.7)
            ctx.stroke()
            return
        }

        if (name === "image") {
            ctx.lineWidth = strokeWidth
            ctx.strokeStyle = iconColor
            ctx.fillStyle = fillColor
            ctx.beginPath()
            ctx.moveTo(4, 5)
            ctx.lineTo(20, 5)
            ctx.lineTo(20, 19)
            ctx.lineTo(4, 19)
            ctx.closePath()
            ctx.fill()
            ctx.stroke()
            ctx.fillStyle = iconColor
            ctx.beginPath()
            ctx.arc(9, 10, 1.4, 0, Math.PI * 2)
            ctx.fill()
            ctx.beginPath()
            ctx.moveTo(4, 17)
            ctx.lineTo(10, 12)
            ctx.lineTo(14, 15)
            ctx.lineTo(17, 12)
            ctx.lineTo(20, 15)
            ctx.lineTo(20, 19)
            ctx.lineTo(4, 19)
            ctx.closePath()
            ctx.fill()
            return
        }

        if (name === "video") {
            ctx.lineWidth = strokeWidth
            ctx.strokeStyle = iconColor
            ctx.fillStyle = fillColor
            ctx.beginPath()
            ctx.moveTo(3, 7)
            ctx.lineTo(15, 7)
            ctx.lineTo(15, 17)
            ctx.lineTo(3, 17)
            ctx.closePath()
            ctx.fill()
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(15, 11)
            ctx.lineTo(21, 7)
            ctx.lineTo(21, 17)
            ctx.lineTo(15, 13)
            ctx.closePath()
            ctx.fill()
            ctx.stroke()
            return
        }

        if (name === "search") {
            ctx.beginPath()
            ctx.arc(11, 11, 6, 0, Math.PI * 2)
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(15.5, 15.5)
            ctx.lineTo(20, 20)
            ctx.stroke()
            return
        }

        if (name === "trash") {
            // Корзина: крышка + ручка сверху, ведро со стенками и тремя
            // вертикальными линиями внутри.
            ctx.beginPath()
            ctx.moveTo(4, 6.5)
            ctx.lineTo(20, 6.5)
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(9, 6.5)
            ctx.lineTo(9, 4)
            ctx.lineTo(15, 4)
            ctx.lineTo(15, 6.5)
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(5.5, 6.5)
            ctx.lineTo(7, 20.5)
            ctx.lineTo(17, 20.5)
            ctx.lineTo(18.5, 6.5)
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(10, 10)
            ctx.lineTo(10, 17.5)
            ctx.moveTo(12, 10)
            ctx.lineTo(12, 17.5)
            ctx.moveTo(14, 10)
            ctx.lineTo(14, 17.5)
            ctx.stroke()
            return
        }

        if (name === "x") {
            ctx.beginPath()
            ctx.moveTo(6, 6)
            ctx.lineTo(18, 18)
            ctx.moveTo(18, 6)
            ctx.lineTo(6, 18)
            ctx.stroke()
            return
        }

        if (name === "check") {
            ctx.beginPath()
            ctx.moveTo(5, 12.5)
            ctx.lineTo(10, 17.5)
            ctx.lineTo(19, 7)
            ctx.stroke()
            return
        }

        if (name === "mic") {
            ctx.beginPath()
            ctx.moveTo(12, 4)
            ctx.bezierCurveTo(10.3, 4, 9, 5.3, 9, 7)
            ctx.lineTo(9, 12)
            ctx.bezierCurveTo(9, 13.7, 10.3, 15, 12, 15)
            ctx.bezierCurveTo(13.7, 15, 15, 13.7, 15, 12)
            ctx.lineTo(15, 7)
            ctx.bezierCurveTo(15, 5.3, 13.7, 4, 12, 4)
            ctx.closePath()
            ctx.fill()
            ctx.beginPath()
            ctx.moveTo(6, 11)
            ctx.lineTo(6, 12)
            ctx.bezierCurveTo(6, 15.3, 8.7, 18, 12, 18)
            ctx.bezierCurveTo(15.3, 18, 18, 15.3, 18, 12)
            ctx.lineTo(18, 11)
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(12, 18)
            ctx.lineTo(12, 21)
            ctx.moveTo(9, 21)
            ctx.lineTo(15, 21)
            ctx.stroke()
            return
        }

        if (name === "micOff") {
            // Тот же микрофон, но с диагональной перечёркивающей линией.
            ctx.beginPath()
            ctx.moveTo(12, 4)
            ctx.bezierCurveTo(10.3, 4, 9, 5.3, 9, 7)
            ctx.lineTo(9, 12)
            ctx.bezierCurveTo(9, 13.7, 10.3, 15, 12, 15)
            ctx.bezierCurveTo(13.7, 15, 15, 13.7, 15, 12)
            ctx.lineTo(15, 7)
            ctx.bezierCurveTo(15, 5.3, 13.7, 4, 12, 4)
            ctx.closePath()
            ctx.fill()
            ctx.beginPath()
            ctx.moveTo(6, 11)
            ctx.lineTo(6, 12)
            ctx.bezierCurveTo(6, 15.3, 8.7, 18, 12, 18)
            ctx.bezierCurveTo(15.3, 18, 18, 15.3, 18, 12)
            ctx.lineTo(18, 11)
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(12, 18)
            ctx.lineTo(12, 21)
            ctx.moveTo(9, 21)
            ctx.lineTo(15, 21)
            ctx.stroke()
            // Перечёркивание — рисуем чуть толще, и с белым контуром снизу,
            // чтобы линия читалась поверх микрофона.
            ctx.save()
            ctx.lineWidth = strokeWidth + 1.5
            ctx.strokeStyle = fillColor
            ctx.beginPath()
            ctx.moveTo(4, 4)
            ctx.lineTo(20, 20)
            ctx.stroke()
            ctx.restore()
            ctx.lineWidth = strokeWidth
            ctx.strokeStyle = iconColor
            ctx.beginPath()
            ctx.moveTo(4, 4)
            ctx.lineTo(20, 20)
            ctx.stroke()
            return
        }

        if (name === "videoOff") {
            // То же, что "video", но с диагональным перечёркиванием.
            ctx.lineWidth = strokeWidth
            ctx.strokeStyle = iconColor
            ctx.fillStyle = fillColor
            ctx.beginPath()
            ctx.moveTo(3, 7)
            ctx.lineTo(15, 7)
            ctx.lineTo(15, 17)
            ctx.lineTo(3, 17)
            ctx.closePath()
            ctx.fill()
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(15, 11)
            ctx.lineTo(21, 7)
            ctx.lineTo(21, 17)
            ctx.lineTo(15, 13)
            ctx.closePath()
            ctx.fill()
            ctx.stroke()
            ctx.save()
            ctx.lineWidth = strokeWidth + 1.5
            ctx.strokeStyle = fillColor
            ctx.beginPath()
            ctx.moveTo(3, 5)
            ctx.lineTo(21, 19)
            ctx.stroke()
            ctx.restore()
            ctx.lineWidth = strokeWidth
            ctx.strokeStyle = iconColor
            ctx.beginPath()
            ctx.moveTo(3, 5)
            ctx.lineTo(21, 19)
            ctx.stroke()
            return
        }

        if (name === "cameraSwitch") {
            // Камера-«мыльница» сверху, две стрелки внутри по кругу — switch
            // между фронт/тыл.
            ctx.lineWidth = strokeWidth
            ctx.strokeStyle = iconColor
            ctx.fillStyle = fillColor
            ctx.beginPath()
            ctx.moveTo(4, 8)
            ctx.lineTo(8, 8)
            ctx.lineTo(9.5, 6)
            ctx.lineTo(14.5, 6)
            ctx.lineTo(16, 8)
            ctx.lineTo(20, 8)
            ctx.lineTo(20, 19)
            ctx.lineTo(4, 19)
            ctx.closePath()
            ctx.fill()
            ctx.stroke()
            ctx.fillStyle = iconColor
            // Две круговые стрелки.
            ctx.beginPath()
            ctx.arc(12, 13.5, 3.2, Math.PI * 1.1, Math.PI * 0.3, false)
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(15.2, 13.5)
            ctx.lineTo(14, 11.7)
            ctx.lineTo(15.7, 11.1)
            ctx.closePath()
            ctx.fill()
            ctx.beginPath()
            ctx.arc(12, 13.5, 3.2, Math.PI * 0.1, Math.PI * 1.3, true)
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(8.8, 13.5)
            ctx.lineTo(10, 15.3)
            ctx.lineTo(8.3, 15.9)
            ctx.closePath()
            ctx.fill()
            return
        }

        if (name === "phoneHangup") {
            // Трубка перевёрнута; короткая линия снизу — «брошено».
            ctx.save()
            ctx.translate(12, 14)
            ctx.rotate(135 * Math.PI / 180)
            ctx.translate(-12, -12)
            ctx.beginPath()
            ctx.moveTo(6.6, 10.8)
            ctx.bezierCurveTo(7.8, 13.2, 9.8, 15.2, 12.2, 16.4)
            ctx.lineTo(14.0, 14.6)
            ctx.bezierCurveTo(14.3, 14.3, 14.7, 14.2, 15.0, 14.4)
            ctx.bezierCurveTo(16.1, 14.8, 17.3, 15.0, 18.5, 15.0)
            ctx.bezierCurveTo(19.3, 15.0, 20.0, 15.7, 20.0, 16.5)
            ctx.lineTo(20.0, 19.5)
            ctx.bezierCurveTo(20.0, 20.3, 19.3, 21.0, 18.5, 21.0)
            ctx.bezierCurveTo(9.9, 21.0, 3.0, 14.1, 3.0, 5.5)
            ctx.bezierCurveTo(3.0, 4.7, 3.7, 4.0, 4.5, 4.0)
            ctx.lineTo(7.5, 4.0)
            ctx.bezierCurveTo(8.3, 4.0, 9.0, 4.7, 9.0, 5.5)
            ctx.bezierCurveTo(9.0, 6.7, 9.2, 7.9, 9.6, 9.0)
            ctx.bezierCurveTo(9.8, 9.3, 9.7, 9.7, 9.4, 10.0)
            ctx.closePath()
            ctx.fill()
            ctx.restore()
            return
        }

        if (name === "backspace") {
            ctx.beginPath()
            ctx.moveTo(3, 12)
            ctx.lineTo(8, 6)
            ctx.lineTo(21, 6)
            ctx.lineTo(21, 18)
            ctx.lineTo(8, 18)
            ctx.closePath()
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(12, 9)
            ctx.lineTo(17, 14)
            ctx.moveTo(17, 9)
            ctx.lineTo(12, 14)
            ctx.stroke()
            return
        }

        // --- Иконки навигации по тексту (панель над клавиатурой) ---

        if (name === "charLeft") {
            // Стрелка влево на символ.
            ctx.beginPath()
            ctx.moveTo(19, 12)
            ctx.lineTo(6, 12)
            ctx.moveTo(11, 7)
            ctx.lineTo(6, 12)
            ctx.lineTo(11, 17)
            ctx.stroke()
            return
        }

        if (name === "charRight") {
            // Стрелка вправо на символ.
            ctx.beginPath()
            ctx.moveTo(5, 12)
            ctx.lineTo(18, 12)
            ctx.moveTo(13, 7)
            ctx.lineTo(18, 12)
            ctx.lineTo(13, 17)
            ctx.stroke()
            return
        }

        if (name === "lineUp") {
            // Стрелка на строку вверх.
            ctx.beginPath()
            ctx.moveTo(12, 19)
            ctx.lineTo(12, 6)
            ctx.moveTo(7, 11)
            ctx.lineTo(12, 6)
            ctx.lineTo(17, 11)
            ctx.stroke()
            return
        }

        if (name === "lineDown") {
            // Стрелка на строку вниз.
            ctx.beginPath()
            ctx.moveTo(12, 5)
            ctx.lineTo(12, 18)
            ctx.moveTo(7, 13)
            ctx.lineTo(12, 18)
            ctx.lineTo(17, 13)
            ctx.stroke()
            return
        }

        if (name === "goToStart") {
            // В начало: вертикальная черта слева + стрелка к ней.
            ctx.beginPath()
            ctx.moveTo(5, 5)
            ctx.lineTo(5, 19)
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(21, 12)
            ctx.lineTo(9, 12)
            ctx.moveTo(14, 7)
            ctx.lineTo(9, 12)
            ctx.lineTo(14, 17)
            ctx.stroke()
            return
        }

        if (name === "endOfLine") {
            // В конец строки: стрелка вправо + вертикальная черта справа.
            ctx.beginPath()
            ctx.moveTo(19, 5)
            ctx.lineTo(19, 19)
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(3, 12)
            ctx.lineTo(15, 12)
            ctx.moveTo(10, 7)
            ctx.lineTo(15, 12)
            ctx.lineTo(10, 17)
            ctx.stroke()
            return
        }

        if (name === "selectAll") {
            // Выделить всё: уголки рамки выделения + две строки текста.
            ctx.beginPath()
            ctx.moveTo(4, 8)
            ctx.lineTo(4, 5)
            ctx.lineTo(7, 5)
            ctx.moveTo(17, 5)
            ctx.lineTo(20, 5)
            ctx.lineTo(20, 8)
            ctx.moveTo(20, 16)
            ctx.lineTo(20, 19)
            ctx.lineTo(17, 19)
            ctx.moveTo(7, 19)
            ctx.lineTo(4, 19)
            ctx.lineTo(4, 16)
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(8, 10.5)
            ctx.lineTo(16, 10.5)
            ctx.moveTo(8, 13.5)
            ctx.lineTo(16, 13.5)
            ctx.stroke()
            return
        }

        if (name === "smile") {
            // Смайлик: окружность + два глаза + дуга-улыбка.
            ctx.lineWidth = strokeWidth
            ctx.strokeStyle = iconColor
            ctx.fillStyle = iconColor
            ctx.beginPath()
            ctx.arc(12, 12, 8.2, 0, Math.PI * 2)
            ctx.stroke()
            ctx.beginPath()
            ctx.arc(9, 10, 1.0, 0, Math.PI * 2)
            ctx.fill()
            ctx.beginPath()
            ctx.arc(15, 10, 1.0, 0, Math.PI * 2)
            ctx.fill()
            ctx.beginPath()
            ctx.arc(12, 12, 4.2, Math.PI * 0.15, Math.PI * 0.85, false)
            ctx.stroke()
            return
        }

        if (name === "keyboard") {
            // Клавиатура: корпус + точки-клавиши + пробел.
            ctx.lineWidth = strokeWidth
            ctx.strokeStyle = iconColor
            ctx.fillStyle = iconColor
            ctx.beginPath()
            ctx.moveTo(4, 7)
            ctx.lineTo(20, 7)
            ctx.lineTo(20, 17)
            ctx.lineTo(4, 17)
            ctx.closePath()
            ctx.stroke()
            const kbX = [7, 10, 13, 16]
            for (let r = 0; r < 2; ++r)
                for (let i = 0; i < kbX.length; ++i) {
                    ctx.beginPath()
                    ctx.arc(kbX[i], 10.5 + r * 2.6, 0.7, 0, Math.PI * 2)
                    ctx.fill()
                }
            ctx.beginPath()
            ctx.moveTo(9, 15)
            ctx.lineTo(15, 15)
            ctx.stroke()
            return
        }

        if (name === "chevronDown") {
            // Шеврон вниз — «скрыть» панель (на ПК нет клавиатуры).
            ctx.beginPath()
            ctx.moveTo(5, 9)
            ctx.lineTo(12, 16)
            ctx.lineTo(19, 9)
            ctx.stroke()
            return
        }
    }
}
