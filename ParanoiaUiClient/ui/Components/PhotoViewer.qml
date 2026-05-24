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

    signal saveRequested(string messageId, string filename)

    function open(path, id, name) {
        zoomTransition.stop()
        source = path
        messageId = id || ""
        filename = name && name.length > 0 ? name : "attachment.bin"
        zoom = 1.0
        photoFlick.contentX = 0
        photoFlick.contentY = 0
        visible = true
        forceActiveFocus()
    }

    function close() {
        zoomTransition.stop()
        visible = false
        source = ""
        messageId = ""
        filename = "attachment.bin"
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
