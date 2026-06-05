import QtQuick
import ParanoiaUiClient

Rectangle {
    id: root
    visible: false
    z: 1000
    color: "#EE020103"
    focus: visible

    property string source: ""
    property string messageId: ""
    property string filename: "attachment.bin"
    property real zoom: 1.0
    property real pinchStartZoom: 1.0
    readonly property real minZoom: 1.0
    readonly property real maxZoom: 5.0
    readonly property real doubleTapZoom: 2.5

    // Галерея фото-вложений диалога: массив объектов {source, id, filename}
    // и индекс текущего. Листание возможно, когда элементов больше одного.
    property var items: []
    property int index: -1
    readonly property bool hasPrev: index > 0
    readonly property bool hasNext: index >= 0 && index < items.length - 1
    readonly property bool canSwipe: items.length > 1 && zoom <= 1.0001

    signal saveRequested(string messageId, string filename)

    // Одиночное фото (обратная совместимость) — оборачиваем в галерею из 1 кадра.
    function open(path, id, name) {
        openGallery([{ source: path,
                       id: id || "",
                       filename: name && name.length > 0 ? name : "attachment.bin" }], 0)
    }

    // Открыть галерею: list — массив {source, id, filename}, idx — стартовый кадр.
    function openGallery(list, idx) {
        items = list || []
        visible = true
        applyIndex(idx)
        forceActiveFocus()
    }

    function applyIndex(idx) {
        zoomTransition.stop()
        index = items.length > 0 ? Math.max(0, Math.min(items.length - 1, idx)) : -1
        const it = (index >= 0) ? items[index] : null
        source = it ? (it.source || "") : ""
        messageId = it ? (it.id || "") : ""
        filename = (it && it.filename && it.filename.length > 0) ? it.filename : "attachment.bin"
        zoom = 1.0
        photoFlick.contentX = 0
        photoFlick.contentY = 0
    }

    function showNext() { if (hasNext) applyIndex(index + 1) }
    function showPrev() { if (hasPrev) applyIndex(index - 1) }

    function close() {
        zoomTransition.stop()
        visible = false
        source = ""
        messageId = ""
        filename = "attachment.bin"
        items = []
        index = -1
        zoom = 1.0
        photoFlick.contentX = 0
        photoFlick.contentY = 0
    }

    function clampedZoom(value) {
        return Math.max(minZoom, Math.min(maxZoom, value))
    }

    function contentWidthForZoom(value) {
        return Math.max(photoFlick.width, photoFlick.width * value)
    }

    function contentHeightForZoom(value) {
        return Math.max(photoFlick.height, photoFlick.height * value)
    }

    function clampedFocalX(value) {
        const x = Number(value)
        return isFinite(x) ? Math.max(0, Math.min(photoFlick.width, x)) : photoFlick.width / 2
    }

    function clampedFocalY(value) {
        const y = Number(value)
        return isFinite(y) ? Math.max(0, Math.min(photoFlick.height, y)) : photoFlick.height / 2
    }

    function zoomTarget(value, focalX, focalY) {
        const targetZoom = clampedZoom(value)
        const x = clampedFocalX(focalX)
        const y = clampedFocalY(focalY)
        const oldWidth = contentWidthForZoom(zoom)
        const oldHeight = contentHeightForZoom(zoom)
        const ratioX = oldWidth > 0 ? (photoFlick.contentX + x) / oldWidth : 0.5
        const ratioY = oldHeight > 0 ? (photoFlick.contentY + y) / oldHeight : 0.5
        const newWidth = contentWidthForZoom(targetZoom)
        const newHeight = contentHeightForZoom(targetZoom)
        const maxContentX = Math.max(0, newWidth - photoFlick.width)
        const maxContentY = Math.max(0, newHeight - photoFlick.height)
        return {
            zoom: targetZoom,
            contentX: Math.max(0, Math.min(maxContentX, ratioX * newWidth - x)),
            contentY: Math.max(0, Math.min(maxContentY, ratioY * newHeight - y))
        }
    }

    function setZoomAt(value, focalX, focalY) {
        zoomTransition.stop()
        const target = zoomTarget(value, focalX, focalY)
        zoom = target.zoom
        photoFlick.contentX = target.contentX
        photoFlick.contentY = target.contentY
    }

    function setZoom(value) {
        setZoomAt(value, photoFlick.width / 2, photoFlick.height / 2)
    }

    function animateZoomAt(value, focalX, focalY) {
        const target = zoomTarget(value, focalX, focalY)
        zoomTransition.stop()
        zoomAnimation.from = zoom
        zoomAnimation.to = target.zoom
        contentXAnimation.from = photoFlick.contentX
        contentXAnimation.to = target.contentX
        contentYAnimation.from = photoFlick.contentY
        contentYAnimation.to = target.contentY
        zoomTransition.start()
    }

    function toggleZoomAt(focalX, focalY) {
        animateZoomAt(zoom > 1.05 ? minZoom : doubleTapZoom, focalX, focalY)
    }

    function toggleZoom() {
        toggleZoomAt(photoFlick.width / 2, photoFlick.height / 2)
    }

    Keys.onEscapePressed: close()
    Keys.onLeftPressed: showPrev()
    Keys.onRightPressed: showNext()

    ParallelAnimation {
        id: zoomTransition
        NumberAnimation {
            id: zoomAnimation
            target: root
            property: "zoom"
            duration: 180
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            id: contentXAnimation
            target: photoFlick
            property: "contentX"
            duration: 180
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            id: contentYAnimation
            target: photoFlick
            property: "contentY"
            duration: 180
            easing.type: Easing.OutCubic
        }
    }

    Flickable {
        id: photoFlick
        anchors.fill: parent
        clip: true
        interactive: root.zoom > 1.0
        boundsBehavior: Flickable.StopAtBounds
        contentWidth: Math.max(width, width * root.zoom)
        contentHeight: Math.max(height, height * root.zoom)

        Image {
            source: root.source
            asynchronous: true
            // cache=false: расшифрованные байты идут через
            // EncryptedImageProvider, дисковый/in-memory кэш Qt мы не используем.
            cache: false
            fillMode: Image.PreserveAspectFit
            width: photoFlick.width
            height: photoFlick.height
            x: (photoFlick.contentWidth - width) / 2
            y: (photoFlick.contentHeight - height) / 2
            scale: root.zoom
            transformOrigin: Item.Center
        }

        WheelHandler {
            target: null
            onWheel: function(event) {
                const focalX = event.position ? event.position.x : event.x
                const focalY = event.position ? event.position.y : event.y
                root.setZoomAt(root.zoom * (event.angleDelta.y > 0 ? 1.12 : 0.88), focalX, focalY)
                event.accepted = true
            }
        }
    }

    PinchHandler {
        target: null
        enabled: root.visible
        minimumPointCount: 2
        maximumPointCount: 2
        onActiveChanged: if (active) {
            zoomTransition.stop()
            root.pinchStartZoom = root.zoom
        }
        onActiveScaleChanged: if (active)
            root.setZoomAt(root.pinchStartZoom * activeScale, centroid.position.x, centroid.position.y)
    }

    TapHandler {
        acceptedButtons: Qt.LeftButton
        gesturePolicy: TapHandler.ReleaseWithinBounds
        onDoubleTapped: function(eventPoint) {
            root.toggleZoomAt(eventPoint.position.x, eventPoint.position.y)
        }
    }

    // Горизонтальный свайп — листание галереи. Активен только без зума (когда
    // photoFlick не перехватывает одно касание для панорамирования).
    DragHandler {
        target: null
        enabled: root.canSwipe
        xAxis.enabled: true
        yAxis.enabled: false
        onActiveChanged: {
            if (!active) {
                if (activeTranslation.x <= -60) root.showNext()
                else if (activeTranslation.x >= 60) root.showPrev()
            }
        }
    }

    // ── Стрелки листания (десктоп/тач) ───────────────────────────────────
    Rectangle {
        id: prevButton
        visible: root.hasPrev
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: 14
        width: 44; height: 44; radius: 22
        color: prevArea.containsMouse ? Theme.bgCard : Theme.bgInput
        opacity: 0.92
        border.width: 1; border.color: Theme.border
        AppIcon {
            anchors.centerIn: parent; width: 20; height: 20
            name: "chevronLeft"; iconColor: Theme.textPrimary; strokeWidth: 2.2
        }
        MouseArea {
            id: prevArea; anchors.fill: parent; hoverEnabled: true
            onClicked: root.showPrev()
        }
    }

    Rectangle {
        id: nextButton
        visible: root.hasNext
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.rightMargin: 14
        width: 44; height: 44; radius: 22
        color: nextArea.containsMouse ? Theme.bgCard : Theme.bgInput
        opacity: 0.92
        border.width: 1; border.color: Theme.border
        AppIcon {
            anchors.centerIn: parent; width: 20; height: 20
            name: "chevronRight"; iconColor: Theme.textPrimary; strokeWidth: 2.2
        }
        MouseArea {
            id: nextArea; anchors.fill: parent; hoverEnabled: true
            onClicked: root.showNext()
        }
    }

    // Счётчик «i / n».
    Rectangle {
        visible: root.items.length > 1
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottomMargin: 18
        width: counterText.implicitWidth + 24; height: 30; radius: 15
        color: Theme.bgInput; opacity: 0.92
        border.width: 1; border.color: Theme.border
        Text {
            id: counterText
            anchors.centerIn: parent
            text: (root.index + 1) + " / " + root.items.length
            color: Theme.textPrimary; font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSm
        }
    }

    Row {
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: 14
        spacing: 8

        Rectangle {
            width: 38
            height: 38
            radius: Theme.radiusSm
            color: saveViewerArea.containsMouse ? Theme.bgCard : Theme.bgInput
            border.width: 1
            border.color: Theme.border
            AppIcon {
                anchors.centerIn: parent
                width: 18
                height: 18
                name: "download"
                iconColor: Theme.textPrimary
                strokeWidth: 2
            }
            MouseArea {
                id: saveViewerArea
                anchors.fill: parent
                hoverEnabled: true
                enabled: root.messageId.length > 0
                onClicked: root.saveRequested(root.messageId, root.filename)
            }
        }

        Rectangle {
            width: 38
            height: 38
            radius: Theme.radiusSm
            color: zoomOutArea.containsMouse ? Theme.bgCard : Theme.bgInput
            border.width: 1
            border.color: Theme.border
            AppIcon {
                anchors.centerIn: parent
                width: 18
                height: 18
                name: "minus"
                iconColor: Theme.textPrimary
                strokeWidth: 2.2
            }
            MouseArea {
                id: zoomOutArea
                anchors.fill: parent
                hoverEnabled: true
                onClicked: root.setZoom(root.zoom / 1.25)
            }
        }

        Rectangle {
            width: 38
            height: 38
            radius: Theme.radiusSm
            color: zoomInArea.containsMouse ? Theme.bgCard : Theme.bgInput
            border.width: 1
            border.color: Theme.border
            AppIcon {
                anchors.centerIn: parent
                width: 18
                height: 18
                name: "plus"
                iconColor: Theme.textPrimary
                strokeWidth: 2.2
            }
            MouseArea {
                id: zoomInArea
                anchors.fill: parent
                hoverEnabled: true
                onClicked: root.setZoom(root.zoom * 1.25)
            }
        }

        Rectangle {
            width: 38
            height: 38
            radius: Theme.radiusSm
            color: closeViewerArea.containsMouse ? Theme.bgCard : Theme.bgInput
            border.width: 1
            border.color: Theme.border
            AppIcon {
                anchors.centerIn: parent
                width: 18
                height: 18
                name: "close"
                iconColor: Theme.textPrimary
                strokeWidth: 2.2
            }
            MouseArea {
                id: closeViewerArea
                anchors.fill: parent
                hoverEnabled: true
                onClicked: root.close()
            }
        }
    }
}
