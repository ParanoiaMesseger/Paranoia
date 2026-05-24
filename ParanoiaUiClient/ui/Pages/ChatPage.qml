import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Dialogs
import QtCore
import ParanoiaUiClient

Rectangle {
    id: root
    color: Theme.bgPrimary
    readonly property bool isMobileOs: (Qt.platform.os === "android" || Qt.platform.os === "ios")
    required property string peer
    property string pendingDownloadId: ""
    property string pendingDownloadName: "attachment.bin"
    property string downloadingAttachmentId: ""
    property bool sendLocked: false
    property string draftSettingsKey: "draft/" + (Backend.activeProfileId || "") + "/" + (root.peer || "")

    signal back()

    // CallPage.qml тянет QtMultimedia — её нет в сборках без VoIP, поэтому
    // компонент создаётся динамически только при VoIPAvailable=true.
    property var callPageComponent: null

    Timer {
        id: sendUnlockTimer
        interval: 700
        onTriggered: root.sendLocked = false
    }

    function formatTime(ts) {
        let d = new Date(ts)
        return d.getHours().toString().padStart(2, '0') + ':'
             + d.getMinutes().toString().padStart(2, '0')
    }

    function deliveryStatusColor(status) {
        if (status === "read") return Theme.messageMetaOutgoing
        if (status === "delivered") return Theme.messageMetaOutgoing
        if (status === "failed") return Theme.error
        return Theme.messageMetaOutgoing
    }

    function markdownText(raw) {
        let text = raw || ""
        text = text.replace(/!\[([^\]]*)\]\([^)]+\)/g, function(match, alt) {
            return alt && alt.length > 0 ? "[" + alt + "]" : "[image]"
        })
        return text.replace(/<\/?[A-Za-z][^>\n]*>/g, function(tag) {
            return tag.replace(/</g, "&lt;").replace(/>/g, "&gt;")
        })
    }

    function replySummary(raw) {
        let text = (raw || "").replace(/\s+/g, " ").trim()
        return text.length > 120 ? text.substring(0, 120) + "…" : text
    }

    function fileNameFor(message) {
        if (message.filename && message.filename.length > 0) return message.filename
        if (message.text && message.text.length > 0) return message.text
        return "attachment.bin"
    }

    function formatFileSize(size) {
        let bytes = Number(size)
        if (!isFinite(bytes) || bytes < 0) return ""
        const units = ["Б", "КБ", "МБ", "ГБ"]
        let unit = 0
        while (bytes >= 1024 && unit < units.length - 1) {
            bytes /= 1024
            ++unit
        }
        return (unit === 0 ? Math.round(bytes).toString() : bytes.toFixed(bytes >= 10 ? 1 : 2)) + " " + units[unit]
    }

    function isImageMessage(kind, mimeType) {
        return kind === "image" || ((mimeType || "").indexOf("image/") === 0)
    }

    function openSaveDialog(messageId, filename) {
        root.pendingDownloadId = messageId
        root.pendingDownloadName = filename && filename.length > 0 ? filename : "attachment.bin"
        Chat.requestFileAccessPermissions()
        saveDialog.open()
    }

    function openPhoto(source, messageId, filename) {
        if (source && source.length > 0) {
            photoViewer.open(source, messageId, filename && filename.length > 0 ? filename : "attachment.bin")
            return
        }
        Chat.ensureImagePreview(messageId)
        errorText.text = "Загрузка превью фото…"
        errorBar.visible = true
        errorTimer.restart()
    }

    function handleBackButton(): bool {
        if (photoViewer.visible) {
            photoViewer.close()
            return true
        }
        if (messageMenu.opened) {
            messageMenu.close()
            return true
        }
        return false
    }

    function openMessageMenu(sender, text, messageId, imageMessage, downloading, filename, seq, bodyToSeq, item, localX, localY) {
        messageMenu.messageSender = sender || ""
        messageMenu.messageText = text || ""
        messageMenu.messageId = messageId || ""
        messageMenu.imageMessage = imageMessage === true
        messageMenu.downloading = downloading === true
        messageMenu.filename = filename && filename.length > 0 ? filename : "attachment.bin"
        messageMenu.messageSeq = Number(seq)
        messageMenu.bodyToSeq = Number(bodyToSeq)

        const point = item.mapToItem(root, localX, localY)
        messageMenu.x = Math.max(8, Math.min(root.width - messageMenu.width - 8, point.x))
        messageMenu.y = Math.max(8, Math.min(root.height - messageMenu.height - 8, point.y))
        messageMenu.open()
    }

    function replyTo(sender, text) {
        msgInput.text = "> **" + sender + ":** " + replySummary(text) + "\n\n" + msgInput.text
        msgInput.forceActiveFocus()
    }

    function copyMessageText(text) {
        copyClipboard.text = text || ""
        copyClipboard.selectAll()
        copyClipboard.copy()
    }

    function saveDraft() {
        if (draftSettingsKey.length === 0) return
        draftStore.setValue(draftSettingsKey, msgInput.text)
    }

    function clearDraft() {
        if (draftSettingsKey.length === 0) return
        draftStore.setValue(draftSettingsKey, "")
    }

    function restoreDraft() {
        const saved = draftStore.value(draftSettingsKey, "")
        if (typeof saved === "string" && saved.length > 0)
            msgInput.text = saved
    }

    function cutSeqForMessage(seq, bodyToSeq) {
        let messageSeq = Number(seq)
        let bodySeq = Number(bodyToSeq)
        return bodySeq > messageSeq ? bodySeq : messageSeq
    }

    Connections {
        target: Chat
        function onMessagesReceived(peer, messages) {
            if (peer !== root.peer) return
            msgModel.clear()
            for (let i = 0; i < messages.length; ++i) {
                let m = messages[i]
                msgModel.append(m)
            }
            listView.positionViewAtEnd()
        }
        function onSendError(msg) {
            errorText.text = msg
            errorBar.visible = true
            errorTimer.restart()
        }
        function onReceiveError(msg) {
            root.downloadingAttachmentId = ""
            errorText.text = msg
            errorBar.visible = true
            errorTimer.restart()
        }
        function onAttachmentSaved(path) {
            root.downloadingAttachmentId = ""
            errorText.text = "Файл сохранён"
            errorBar.visible = true
            errorTimer.restart()
        }
        function onServerHistoryCleared(peer) {
            if (peer !== root.peer) return
            errorText.text = "Сообщения удалены"
            errorBar.visible = true
            errorTimer.restart()
        }
        function onServerHistoryError(msg) {
            errorText.text = msg
            errorBar.visible = true
            errorTimer.restart()
        }
    }

    Component.onCompleted: {
        Chat.openChat(root.peer)
        restoreDraft()
        if (VoIPAvailable) {
            root.callPageComponent = Qt.createComponent(
                Qt.resolvedUrl("CallPage.qml"), Component.PreferSynchronous);
            if (root.callPageComponent.status === Component.Error)
                console.warn("CallPage load error:", root.callPageComponent.errorString());
        }
    }
    Component.onDestruction: Chat.stopChat()

    Settings {
        id: draftStore
        category: "chatDrafts"
    }

    FileDialog {
        id: attachDialog
        title: "Выберите файл"
        fileMode: FileDialog.OpenFile
        onAccepted: Chat.sendFile(selectedFile)
    }

    FolderDialog {
        id: saveDialog
        title: "Выберите папку для сохранения"
        onAccepted: {
            root.downloadingAttachmentId = root.pendingDownloadId
            Chat.saveAttachment(root.pendingDownloadId, selectedFolder)
        }
    }

    TextEdit {
        id: copyClipboard
        visible: false
    }

    Popup {
        id: messageMenu
        width: 274
        height: menuColumn.implicitHeight + topPadding + bottomPadding
        padding: 6
        modal: false
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        z: 900

        property string messageSender: ""
        property string messageText: ""
        property string messageId: ""
        property bool imageMessage: false
        property bool downloading: false
        property string filename: "attachment.bin"
        property real messageSeq: 0
        property real bodyToSeq: 0

        background: Rectangle {
            color: Theme.bgCard
            radius: Theme.radiusMd
            border.width: 1
            border.color: Theme.border
        }

        contentItem: Column {
            id: menuColumn
            width: 284
            spacing: 2

            Rectangle {
                width: menuColumn.width
                height: 42
                radius: Theme.radiusSm
                color: "transparent"
                Row {
                    anchors.centerIn: parent
                    spacing: 6
                    Repeater {
                        model: ["👍", "🔥", "🤡", "💩", "❤️", "😂", "😢"]
                        delegate: Rectangle {
                            required property string modelData
                            width: 30
                            height: 30
                            radius: Theme.radiusSm
                            color: reactionArea.containsMouse ? Theme.bgInput : Theme.bgSecondary
                            border.width: 1
                            border.color: Theme.border
                            Text {
                                anchors.centerIn: parent
                                text: modelData
                                font.pixelSize: 16
                                font.family: Theme.fontFamily
                            }
                            MouseArea {
                                id: reactionArea
                                anchors.fill: parent
                                hoverEnabled: true
                                enabled: messageMenu.messageId.length > 0
                                onClicked: {
                                    messageMenu.close()
                                    Chat.sendReaction(messageMenu.messageId, modelData)
                                }
                            }
                        }
                    }
                }
            }

            Rectangle {
                width: menuColumn.width
                height: 34
                radius: Theme.radiusSm
                color: replyMenuArea.containsMouse ? Theme.bgInput : "transparent"
                Text {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    text: "Ответить"
                    color: Theme.textPrimary
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    elide: Text.ElideRight
                }
                MouseArea {
                    id: replyMenuArea
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: {
                        messageMenu.close()
                        root.replyTo(messageMenu.messageSender, messageMenu.messageText)
                    }
                }
            }

            Rectangle {
                width: menuColumn.width
                height: 34
                radius: Theme.radiusSm
                color: copyMenuArea.containsMouse && copyMenuArea.enabled ? Theme.bgInput : "transparent"
                Text {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    text: "Скопировать"
                    color: messageMenu.messageText.length > 0 ? Theme.textPrimary : Theme.textHint
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    elide: Text.ElideRight
                }
                MouseArea {
                    id: copyMenuArea
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: messageMenu.messageText.length > 0
                    onClicked: {
                        messageMenu.close()
                        root.copyMessageText(messageMenu.messageText)
                    }
                }
            }

            Rectangle {
                width: menuColumn.width
                height: visible ? 34 : 0
                visible: messageMenu.imageMessage
                radius: Theme.radiusSm
                color: savePhotoMenuArea.containsMouse && savePhotoMenuArea.enabled ? Theme.bgInput : "transparent"
                Text {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    text: "Сохранить фото"
                    color: savePhotoMenuArea.enabled ? Theme.accentHover : Theme.textHint
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    elide: Text.ElideRight
                }
                MouseArea {
                    id: savePhotoMenuArea
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: !messageMenu.downloading
                    onClicked: {
                        messageMenu.close()
                        root.openSaveDialog(messageMenu.messageId, messageMenu.filename)
                    }
                }
            }

            Rectangle {
                width: menuColumn.width
                height: 1
                color: Theme.separator
            }

            Rectangle {
                width: menuColumn.width
                height: 34
                radius: Theme.radiusSm
                color: deleteMenuArea.containsMouse && deleteMenuArea.enabled ? Theme.bgInput : "transparent"
                Text {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    text: "Удалить до этого сообщения"
                    color: deleteMenuArea.enabled ? Theme.error : Theme.textHint
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    elide: Text.ElideRight
                }
                MouseArea {
                    id: deleteMenuArea
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: messageMenu.messageSeq > 0
                    onClicked: {
                        messageMenu.close()
                        Chat.deleteMessagesUntil(root.cutSeqForMessage(messageMenu.messageSeq, messageMenu.bodyToSeq))
                    }
                }
            }
        }
    }

    Popup {
        id: inputMenu
        width: 100
        height: inputMenuColumn.implicitHeight + topPadding + bottomPadding
        padding: 6
        modal: false
        focus: false
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        z: 901
        background: Rectangle {
            color: Theme.bgCard
            radius: Theme.radiusMd
            border.width: 1
            border.color: Theme.border
        }
        contentItem: Column {
            id: inputMenuColumn
            width: 188
            spacing: 2
            Repeater {
                model: ["Очистить", "Копировать", "Вставить"]
                delegate: Rectangle {
                    required property int index
                    required property string modelData
                    width: inputMenuColumn.width
                    height: 34
                    radius: Theme.radiusSm
                    color: inputMenuArea.containsMouse ? Theme.bgInput : "transparent"
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: 10
                        text: modelData
                        color: Theme.textPrimary
                        font.pixelSize: Theme.fontSm
                        font.family: Theme.fontFamily
                    }
                    MouseArea {
                        id: inputMenuArea
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: {
                            inputMenu.close()
                            if (index === 0) msgInput.clear()
                            else if (index === 1) {
                                if (msgInput.selectedText.length == 0) msgInput.selectAll()
                                msgInput.copy()
                            }
                            else  msgInput.paste()
                        }
                    }
                }
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ── Header ────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            height: 56
            color: Theme.bgDark

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width; height: 2
                color: Theme.accentDim
            }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 16
                spacing: 8

                // Back button
                Rectangle {
                    width: 40; height: 40
                    radius: Theme.radiusSm
                    color: backArea.containsMouse ? Theme.bgCard : "transparent"
                    border.width: backArea.containsMouse ? 1 : 0
                    border.color: Theme.border

                    Text {
                        anchors.centerIn: parent
                        text: "‹"
                        color: Theme.accentHover
                        font.pixelSize: 24
                    }
                    MouseArea {
                        id: backArea
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: root.back()
                    }
                }

                // Avatar
                Rectangle {
                    width: 36; height: 36
                    radius: Theme.radiusSm
                    color: Theme.bgCard
                    border.width: 1
                    border.color: Theme.accentDim

                    Text {
                        anchors.centerIn: parent
                        text: root.peer.charAt(0).toUpperCase()
                        color: Theme.accentHover
                        font.pixelSize: Theme.fontMd
                        font.weight: Font.Bold
                    }
                }

                Column {
                    Layout.fillWidth: true
                    spacing: 2
                    Text {
                        text: root.peer
                        color: Theme.textPrimary
                        font.pixelSize: Theme.fontMd
                        font.family: Theme.fontFamily
                        font.weight: Font.Medium
                    }
                    Row {
                        spacing: 8
                        Toggle {
                            id: receiptsSwitch
                            width:  40
                            height: 20
                            anchors.verticalCenter: parent.verticalCenter
                            checked: Chat.readReceiptsEnabled
                            palette.text: Theme.controlText
                            onToggled: Chat.setReadReceiptsEnabled(checked)
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Уведомлять о прочтении"
                            color: Theme.success
                            font.pixelSize: Theme.fontXs
                            font.family: Theme.fontFamily
                        }
                    }
                }

                // Кнопка «Позвонить» — видна только если voip собран и есть
                // master_key для диалога.
                Rectangle {
                    id: callBtn
                    visible: VoIPAvailable
                    width: 40; height: 40
                    radius: Theme.radiusSm
                    color: callArea.containsMouse ? Theme.bgCard : "transparent"
                    border.width: callArea.containsMouse ? 1 : 0
                    border.color: Theme.border

                    // SVG-иконка телефона с цветами темы
                    Canvas {
                        id: phoneIcon
                        anchors.centerIn: parent
                        width: 20
                        height: 20

                        onPaint: {
                            var ctx = getContext("2d")
                            ctx.clearRect(0, 0, width, height)
                            ctx.setTransform(1, 0, 0, 1, 0, 0)
                            ctx.fillStyle = callArea.containsMouse
                                ? Theme.accentHover
                                : Theme.accent

                            // Иконка телефона (Lucide-style phone path, 24x24 → масштабируем)
                            ctx.scale(width / 24, height / 24)
                            ctx.beginPath()
                            // Корпус телефона
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
                        }

                        // Перерисовка при смене hover или темы
                        Connections {
                            target: callArea
                            function onContainsMouseChanged() { phoneIcon.requestPaint() }
                        }
                        Connections {
                            target: Theme
                            function onDarkModeChanged() { phoneIcon.requestPaint() }
                        }
                    }

                    MouseArea {
                        id: callArea
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: {
                            if (!VoIPAvailable) return
                            const mk = CallSignaling.masterKeyFor(root.peer)
                            if (mk.length === 0) {
                                console.warn("No master key for peer", root.peer)
                                return
                            }
                            if (!root.callPageComponent || root.callPageComponent.status !== Component.Ready) {
                                console.warn("CallPage component not ready")
                                return
                            }
                            if (!CallControl.startOutgoingCall(root.peer, mk)) {
                                console.warn("startOutgoingCall failed")
                                return
                            }
                            stackView.push(root.callPageComponent, { mode: "outgoing", peerName: root.peer })
                        }
                    }
                }
            }
        }

        // ── Message list ──────────────────────────────────────
        ListView {
            id: listView
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 4

            model: ListModel { id: msgModel }

            ScrollBar.vertical: ScrollBar {}

            delegate: Item {
                width: listView.width
                height: bubble.implicitHeight + 8

                readonly property bool isMe: model.isMe === true
                readonly property string mimeType: model.mime_type || ""
                readonly property bool isImage: root.isImageMessage(model.kind, mimeType)
                readonly property bool hasAttachment: model.kind === "file" || model.kind === "image" || model.kind === "voice" || isImage
                readonly property bool showMessageText: !hasAttachment && (model.text || "").length > 0
                readonly property bool showFileCard: hasAttachment && !isImage
                readonly property string attachmentName: root.fileNameFor(model)
                readonly property string previewSource: model.preview_source || ""
                readonly property bool isDownloading: root.downloadingAttachmentId === model.id
                readonly property var reactions: {
                    const raw = model.reactions_json || ""
                    if (raw.length === 0) return []
                    try { return JSON.parse(raw) } catch (e) { return [] }
                }
                readonly property bool hasReactions: reactions && reactions.length > 0

                Component.onCompleted: {
                    if (isImage && previewSource.length === 0)
                        Chat.ensureImagePreview(model.id)
                }

                Rectangle {
                    id: bubble
                    anchors.right: isMe ? parent.right : undefined
                    anchors.left:  isMe ? undefined     : parent.left
                    anchors.rightMargin: isMe ? 12 : 0
                    anchors.leftMargin:  isMe ? 0  : 12
                    anchors.verticalCenter: parent.verticalCenter

                    width: Math.min(Math.max(showMessageText ? msgText.implicitWidth : 0,
                                             isImage ? imagePreview.implicitWidth : 0,
                                             showFileCard ? fileCard.implicitWidth : 0,
                                             hasReactions ? reactionsFlow.implicitWidth : 0,
                                             metaRow.implicitWidth,
                                             isMe ? 0 : senderLabel.implicitWidth) + 24,
                                      listView.width * 0.72)
                    implicitHeight: (isMe ? 0 : senderLabel.implicitHeight + 2)
                                  + (showMessageText ? msgText.implicitHeight : 0)
                                  + (isImage ? imagePreview.implicitHeight + 6 : 0)
                                  + (showFileCard ? fileCard.implicitHeight + 6 : 0)
                                  + (hasReactions ? reactionsFlow.implicitHeight + 6 : 0)
                                  + metaRow.implicitHeight + 16
                    radius: Theme.radiusMd
                    color: isMe ? Theme.bgButton : Theme.bgSecondary
                    border.width: 1
                    border.color: isMe ? Theme.accentDim : Theme.border

                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        hoverEnabled: false
                        onClicked: function(mouse) {
                            if (mouse.button === Qt.RightButton || mouse.source !== Qt.MouseEventNotSynthesized)
                                root.openMessageMenu(model.sender, model.text, model.id, isImage, isDownloading,
                                                     attachmentName, model.seq, model.body_to_seq, bubble, mouse.x, mouse.y)

                        }
                    }

                    // Sender label (only for incoming)
                    Text {
                        id: senderLabel
                        anchors.top: parent.top
                        anchors.left: parent.left
                        anchors.margins: 10
                        text: isMe ? "" : root.peer
                        color: Theme.accent
                        font.pixelSize: Theme.fontXs
                        font.family: Theme.fontFamily
                        font.weight: Font.Medium
                        visible: !isMe
                    }

                    Text {
                        id: msgText
                        anchors.top: isMe ? parent.top : senderLabel.bottom
                        anchors.topMargin: isMe ? 10 : 2
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        visible: showMessageText
                        text: showMessageText ? root.markdownText(model.text) : ""
                        textFormat: Text.MarkdownText
                        linkColor: Theme.accentHover
                        onLinkActivated: function(link) { Qt.openUrlExternally(link) }
                        color: Theme.textPrimary
                        font.pixelSize: Theme.fontMd
                        font.family: Theme.fontFamily
                        wrapMode: Text.WordWrap
                        lineHeight: 1.3
                    }

                    Rectangle {
                        id: imagePreview
                        anchors.top: showMessageText ? msgText.bottom : (isMe ? parent.top : senderLabel.bottom)
                        anchors.topMargin: isMe && !showMessageText ? 10 : 6
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        height: isImage ? Math.min(220, Math.max(150, width * 0.66)) : 0
                        visible: isImage
                        radius: Theme.radiusMd
                        color: Theme.bgInput
                        border.width: previewSource.length > 0 ? 0 : 1
                        border.color: Theme.border
                        clip: true

                        implicitWidth: 250
                        implicitHeight: height

                        Image {
                            anchors.fill: parent
                            source: previewSource
                            visible: previewSource.length > 0
                            asynchronous: true
                            cache: true
                            fillMode: Image.PreserveAspectCrop
                            sourceSize.width: 640
                            sourceSize.height: 640
                        }

                        Column {
                            anchors.centerIn: parent
                            spacing: 6
                            visible: previewSource.length === 0
                            BusyIndicator {
                                anchors.horizontalCenter: parent.horizontalCenter
                                width: 28
                                height: 28
                                running: visible
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: "Загрузка превью"
                                color: Theme.textSecondary
                                font.pixelSize: Theme.fontSm
                                font.family: Theme.fontFamily
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: root.openPhoto(previewSource, model.id, attachmentName)
                        }

                        Rectangle {
                            width: 34
                            height: 34
                            anchors.top: parent.top
                            anchors.right: parent.right
                            anchors.margins: 8
                            radius: Theme.radiusSm
                            color: previewSaveArea.containsMouse ? Theme.bgCard : "#CC0B0F14"
                            border.width: 1
                            border.color: Theme.border
                            z: 3

                            Text {
                                anchors.centerIn: parent
                                text: "↓"
                                color: Theme.textPrimary
                                font.pixelSize: Theme.fontMd
                                font.family: Theme.fontFamily
                            }

                            MouseArea {
                                id: previewSaveArea
                                anchors.fill: parent
                                hoverEnabled: true
                                enabled: !isDownloading
                                onClicked: root.openSaveDialog(model.id, attachmentName)
                            }
                        }
                    }

                    Rectangle {
                        id: fileCard
                        anchors.top: showMessageText ? msgText.bottom : (isMe ? parent.top : senderLabel.bottom)
                        anchors.topMargin: 6
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        height: showFileCard ? 58 : 0
                        visible: showFileCard
                        radius: Theme.radiusMd
                        color: Theme.bgInput
                        border.width: 1
                        border.color: Theme.border

                        implicitWidth: Math.max(230, fileNameText.implicitWidth + 78)
                        implicitHeight: height

                        Rectangle {
                            id: fileIcon
                            width: 38
                            height: 38
                            anchors.left: parent.left
                            anchors.leftMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            radius: Theme.radiusSm
                            color: fileIconArea.containsMouse ? Theme.bgCard : Theme.bgSecondary
                            border.width: 1
                            border.color: fileIconArea.containsMouse ? Theme.accentDim : Theme.border

                            Canvas {
                                anchors.fill: parent
                                onPaint: {
                                    const ctx = getContext("2d")
                                    ctx.clearRect(0, 0, width, height)
                                    ctx.strokeStyle = Theme.accentHover
                                    ctx.fillStyle = Theme.accentDim
                                    ctx.lineWidth = 1.5
                                    ctx.beginPath()
                                    ctx.moveTo(width * 0.30, height * 0.18)
                                    ctx.lineTo(width * 0.62, height * 0.18)
                                    ctx.lineTo(width * 0.76, height * 0.32)
                                    ctx.lineTo(width * 0.76, height * 0.82)
                                    ctx.lineTo(width * 0.30, height * 0.82)
                                    ctx.closePath()
                                    ctx.fill()
                                    ctx.stroke()
                                    ctx.beginPath()
                                    ctx.moveTo(width * 0.62, height * 0.18)
                                    ctx.lineTo(width * 0.62, height * 0.34)
                                    ctx.lineTo(width * 0.76, height * 0.34)
                                    ctx.stroke()
                                }
                            }

                            MouseArea {
                                id: fileIconArea
                                anchors.fill: parent
                                hoverEnabled: true
                                enabled: !isDownloading
                                onClicked: root.openSaveDialog(model.id, attachmentName)
                            }
                        }

                        Column {
                            anchors.left: fileIcon.right
                            anchors.leftMargin: 10
                            anchors.right: parent.right
                            anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 3

                            Text {
                                id: fileNameText
                                width: parent.width
                                text: attachmentName
                                color: Theme.textPrimary
                                font.pixelSize: Theme.fontSm
                                font.family: Theme.fontFamily
                                elide: Text.ElideRight
                            }
                            Text {
                                width: parent.width
                                text: isDownloading ? "Сохранение…" : root.formatFileSize(model.size)
                                color: Theme.textSecondary
                                font.pixelSize: Theme.fontXs
                                font.family: Theme.fontFamily
                                elide: Text.ElideRight
                            }
                        }
                    }

                    Flow {
                        id: reactionsFlow
                        anchors.top: isImage ? imagePreview.bottom : (showFileCard ? fileCard.bottom : msgText.bottom)
                        anchors.topMargin: 6
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        spacing: 4
                        visible: hasReactions

                        Repeater {
                            model: reactions
                            delegate: Rectangle {
                                required property var modelData
                                readonly property string senderInitial: {
                                    const s = modelData.sender_name || modelData.sender || ""
                                    return s.length > 0 ? s.charAt(0).toUpperCase() : ""
                                }
                                width: reactionRow.implicitWidth + 14
                                height: 28
                                radius: 14
                                color: modelData.mine ? Theme.accentDim : Theme.bgDark
                                border.width: 1
                                border.color: modelData.mine ? Theme.accentHover : Theme.border
                                Row {
                                    id: reactionRow
                                    anchors.centerIn: parent
                                    spacing: 4
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: modelData.emoji
                                        color: Theme.textPrimary
                                        font.pixelSize: 16
                                        font.family: Theme.fontFamily
                                    }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: senderInitial.length > 0
                                        text: senderInitial
                                        color: Theme.textSecondary
                                        font.pixelSize: Theme.fontSm
                                        font.family: Theme.fontFamily
                                        font.weight: Font.DemiBold
                                    }
                                }
                            }
                        }
                    }

                    Row {
                        id: metaRow
                        anchors.top: hasReactions ? reactionsFlow.bottom : (isImage ? imagePreview.bottom : (showFileCard ? fileCard.bottom : msgText.bottom))
                        anchors.topMargin: hasReactions ? 4 : 0
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 4
                        spacing: 4
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.formatTime(model.ts)
                            color: isMe ? root.deliveryStatusColor(model.status) : Theme.messageMetaIncoming
                            font.pixelSize: Theme.fontXs
                            font.family: Theme.fontFamily
                        }
                        DeliveryStatusIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: isMe
                            status: model.status
                            iconColor: root.deliveryStatusColor(model.status)
                        }
                    }
                }
            }

            BusyIndicator {
                id: messagesBusy
                anchors.centerIn: parent
                running: Chat.messagesLoading || msgModel.count === 0
                visible: running
                z: 2
            }

            Text {
                anchors.top: messagesBusy.bottom
                anchors.topMargin: 8
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Загрузка сообщений…"
                color: Theme.textSecondary
                font.pixelSize: Theme.fontSm
                font.family: Theme.fontFamily
                visible: messagesBusy.visible
                z: 2
            }
        }

        // ── Error bar ─────────────────────────────────────────
        Rectangle {
            id: errorBar
            Layout.fillWidth: true
            height: 36
            color: Theme.errorBg
            visible: false

            Timer { id: errorTimer; interval: 3000; onTriggered: errorBar.visible = false }

            Text {
                id: errorText
                anchors.centerIn: parent
                color: Theme.error
                font.pixelSize: Theme.fontSm
                font.family: Theme.fontFamily
            }
        }

        // ── Input bar ─────────────────────────────────────────
        Rectangle {
            id: inputBar
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(Math.max(msgInput.implicitHeight + 32, 60), 142)
            color: Theme.bgDark

            Rectangle {
                anchors.top: parent.top
                width: parent.width; height: 1
                color: Theme.separator
            }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                anchors.topMargin: 8
                anchors.bottomMargin: 8
                spacing: 8

                Rectangle {
                    Layout.preferredWidth: 40
                    Layout.preferredHeight: 40
                    Layout.alignment: Qt.AlignVCenter
                    radius: Theme.radiusSm
                    color: attachArea.containsMouse ? Theme.bgCard : Theme.bgInput
                    border.width: 1
                    border.color: Theme.border

                    Text {
                        anchors.centerIn: parent
                        text: "+"
                        color: Theme.accentHover
                        font.pixelSize: 24
                        font.family: Theme.fontFamily
                    }

                    MouseArea {
                        id: attachArea
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: {
                            Chat.requestFileAccessPermissions()
                            attachDialog.open()
                        }
                    }
                }

                ScrollView {
                    id: msgInputScroll
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(Math.max(msgInput.implicitHeight, 40), 124)
                    Layout.alignment: Qt.AlignVCenter
                    clip: true
                    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                    ScrollBar.vertical.policy: ScrollBar.AsNeeded

                    background: Rectangle {
                        radius: Theme.radiusMd
                        color: Theme.bgInput
                        border.color: Theme.border
                        border.width: 1
                    }

                    TextArea {
                        id: msgInput
                        placeholderText: "Сообщение…"
                        placeholderTextColor: Theme.textHint
                        wrapMode: TextEdit.Wrap
                        selectByMouse: true
                        inputMethodHints: Qt.ImhNoAutoUppercase
                        color: Theme.textPrimary
                        font.pixelSize: Theme.fontMd
                        font.family: Theme.fontFamily
                        topPadding: 8
                        bottomPadding: 8
                        leftPadding: 14
                        rightPadding: 14
                        
                        background: null
                        onTextChanged: {
                            if (text.length > 0) root.sendLocked = false
                            root.saveDraft()
                        }

                        SpellHighlighter {
                            textDocument: msgInput.textDocument
                            enabled: true
                            locale: "ru_RU"
                        }

                        persistentSelection: true
                        // Правая кнопка на десктопе
                        onPressed: function(event) {
                            if (event.button === Qt.RightButton && !isMobileOs) {
                                const p = mapToItem(root, event.x, event.y)
                                inputMenu.x = p.x - inputMenu.width
                                inputMenu.y = p.y - inputMenu.height
                                inputMenu.open()
                                event.accepted = true
                            }
                        }

                        // Длинное нажатие на мобильных
                        onPressAndHold: function(event) {
                            if (!isMobileOs) return
                            const p = mapToItem(root, event.x, event.y)
                            inputMenu.x = p.x - inputMenu.width
                            inputMenu.y = p.y - inputMenu.height
                            inputMenu.open()
                        }

                        onActiveFocusChanged: {
                           if (activeFocus) Qt.inputMethod.show()
                        }

                        Keys.onPressed: function(event) {
                            if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                                    && (event.modifiers & Qt.ControlModifier)) {
                                sendBtn.clicked()
                                event.accepted = true
                            }
                        }
                    }
                }

                // Send button
                Rectangle {
                    Layout.preferredWidth: 40
                    Layout.preferredHeight: 40
                    Layout.alignment: Qt.AlignVCenter
                    radius: Theme.radiusSm
                    color: root.sendLocked || (msgInput.text.trim().length === 0) ? Theme.accentDim : (sendArea.containsMouse ? Theme.accentHover : Theme.accent)

                    Canvas {
                        property bool enabled: msgInput.text.trim().length > 0
                        onEnabledChanged: requestPaint()

                        anchors.fill: parent
                        onPaint: {
                            const ctx = getContext("2d")
                            ctx.clearRect(0, 0, width, height)
                            ctx.fillStyle = (enabled) ? Theme.textPrimary : Theme.textSecondary
                            ctx.beginPath()
                            ctx.moveTo(width * 0.24, height * 0.20)
                            ctx.lineTo(width * 0.78, height * 0.50)
                            ctx.lineTo(width * 0.24, height * 0.80)
                            ctx.lineTo(width * 0.34, height * 0.54)
                            ctx.lineTo(width * 0.58, height * 0.50)
                            ctx.lineTo(width * 0.34, height * 0.46)
                            ctx.closePath()
                            ctx.fill()
                        }
                    }

                    MouseArea {
                        id: sendArea
                        anchors.fill: parent
                        hoverEnabled: true
                        enabled: !root.sendLocked && msgInput.text.trim().length > 0
                        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ForbiddenCursor
                        onClicked: sendBtn.clicked()
                    }
                }

                // Invisible button target for keyboard submit
                Item {
                    id: sendBtn
                    signal clicked()
                    onClicked: {
                        if (root.sendLocked) return
                        Chat.commitInputMethod()
                        let txt = msgInput.text.trim()
                        if (txt.length === 0) return
                        root.sendLocked = true
                        Chat.sendText(txt)
                        msgInput.text = ""
                        root.clearDraft()
                        sendUnlockTimer.restart()
                    }
                }
            }
        }
    }

    Rectangle {
        id: photoViewer
        anchors.fill: parent
        visible: false
        z: 1000
        color: "#EE020103"
        focus: visible

        property string source: ""
        property string messageId: ""
        property string filename: "attachment.bin"
        property real zoom: 1.0
        property real pinchStartZoom: 1.0

        function open(path, id, name) {
            source = path
            messageId = id || ""
            filename = name && name.length > 0 ? name : "attachment.bin"
            zoom = 1.0
            visible = true
            forceActiveFocus()
        }

        function close() {
            visible = false
            source = ""
            messageId = ""
            filename = "attachment.bin"
            zoom = 1.0
        }

        function setZoom(value) {
            zoom = Math.max(1.0, Math.min(5.0, value))
        }

        function toggleZoom() {
            setZoom(zoom > 1.05 ? 1.0 : 2.5)
        }

        Keys.onEscapePressed: close()

        Flickable {
            id: photoFlick
            anchors.fill: parent
            clip: true
            interactive: photoViewer.zoom > 1.0
            boundsBehavior: Flickable.StopAtBounds
            contentWidth: Math.max(width, width * photoViewer.zoom)
            contentHeight: Math.max(height, height * photoViewer.zoom)

            Image {
                id: fullPhoto
                source: photoViewer.source
                asynchronous: true
                cache: true
                fillMode: Image.PreserveAspectFit
                width: photoFlick.width
                height: photoFlick.height
                x: (photoFlick.contentWidth - width) / 2
                y: (photoFlick.contentHeight - height) / 2
                scale: photoViewer.zoom
                transformOrigin: Item.Center
            }

            WheelHandler {
                target: null
                onWheel: function(event) {
                    photoViewer.setZoom(photoViewer.zoom * (event.angleDelta.y > 0 ? 1.12 : 0.88))
                    event.accepted = true
                }
            }
        }

        PinchHandler {
            target: null
            enabled: photoViewer.visible
            minimumPointCount: 2
            maximumPointCount: 2
            onActiveChanged: if (active) photoViewer.pinchStartZoom = photoViewer.zoom
            onActiveScaleChanged: if (active) photoViewer.setZoom(photoViewer.pinchStartZoom * activeScale)
        }

        TapHandler {
            acceptedButtons: Qt.LeftButton
            gesturePolicy: TapHandler.ReleaseWithinBounds
            onDoubleTapped: photoViewer.toggleZoom()
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
                Text {
                    anchors.centerIn: parent
                    text: "↓"
                    color: Theme.textPrimary
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                }
                MouseArea {
                    id: saveViewerArea
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: photoViewer.messageId.length > 0
                    onClicked: root.openSaveDialog(photoViewer.messageId, photoViewer.filename)
                }
            }

            Rectangle {
                width: 38
                height: 38
                radius: Theme.radiusSm
                color: zoomOutArea.containsMouse ? Theme.bgCard : Theme.bgInput
                border.width: 1
                border.color: Theme.border
                Text {
                    anchors.centerIn: parent
                    text: "-"
                    color: Theme.textPrimary
                    font.pixelSize: Theme.fontLg
                    font.family: Theme.fontFamily
                }
                MouseArea {
                    id: zoomOutArea
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: photoViewer.setZoom(photoViewer.zoom / 1.25)
                }
            }

            Rectangle {
                width: 38
                height: 38
                radius: Theme.radiusSm
                color: zoomInArea.containsMouse ? Theme.bgCard : Theme.bgInput
                border.width: 1
                border.color: Theme.border
                Text {
                    anchors.centerIn: parent
                    text: "+"
                    color: Theme.textPrimary
                    font.pixelSize: Theme.fontLg
                    font.family: Theme.fontFamily
                }
                MouseArea {
                    id: zoomInArea
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: photoViewer.setZoom(photoViewer.zoom * 1.25)
                }
            }

            Rectangle {
                width: 38
                height: 38
                radius: Theme.radiusSm
                color: closeViewerArea.containsMouse ? Theme.bgCard : Theme.bgInput
                border.width: 1
                border.color: Theme.border
                Text {
                    anchors.centerIn: parent
                    text: "x"
                    color: Theme.textPrimary
                    font.pixelSize: Theme.fontLg
                    font.family: Theme.fontFamily
                }
                MouseArea {
                    id: closeViewerArea
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: photoViewer.close()
                }
            }
        }
    }
}
