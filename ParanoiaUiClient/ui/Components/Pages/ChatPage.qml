import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Dialogs
import ParanoiaUiClient

Rectangle {
    id: root
    color: Theme.bgPrimary

    required property string peer
    property string pendingDownloadId: ""
    property string pendingDownloadName: "attachment.bin"
    property string downloadingAttachmentId: ""
    property bool sendLocked: false

    signal back()

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
        Backend.requestFileAccessPermissions()
        saveDialog.open()
    }

    function openPhoto(source, messageId, filename) {
        if (source && source.length > 0) {
            photoViewer.open(source, messageId, filename && filename.length > 0 ? filename : "attachment.bin")
            return
        }
        Backend.ensureImagePreview(messageId)
        errorText.text = "Загрузка превью фото…"
        errorBar.visible = true
        errorTimer.restart()
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

    function cutSeqForMessage(seq, bodyToSeq) {
        let messageSeq = Number(seq)
        let bodySeq = Number(bodyToSeq)
        return bodySeq > messageSeq ? bodySeq : messageSeq
    }

    Connections {
        target: Backend
        function onMessagesReceived(peer, messages) {
            if (peer !== root.peer) return
            msgModel.clear()
            for (let i = 0; i < messages.length; ++i) {
                let m = messages[i]
                if (m.text && m.text.length > 0)
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

    Component.onCompleted: Backend.openChat(root.peer)
    Component.onDestruction: Backend.stopChat()

    FileDialog {
        id: attachDialog
        title: "Выберите файл"
        fileMode: FileDialog.OpenFile
        onAccepted: Backend.sendFile(selectedFile)
    }

    FolderDialog {
        id: saveDialog
        title: "Выберите папку для сохранения"
        onAccepted: {
            root.downloadingAttachmentId = root.pendingDownloadId
            Backend.saveAttachment(root.pendingDownloadId, selectedFolder)
        }
    }

    TextEdit {
        id: copyClipboard
        visible: false
    }

    Popup {
        id: messageMenu
        width: 236
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
            width: 224
            spacing: 2

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
                        Backend.deleteMessagesUntil(root.cutSeqForMessage(messageMenu.messageSeq, messageMenu.bodyToSeq))
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
                    Text {
                        text: "E2E"
                        color: Theme.success
                        font.pixelSize: Theme.fontXs
                        font.family: Theme.fontFamily
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
                readonly property bool showMessageText: !hasAttachment
                readonly property bool showFileCard: hasAttachment && !isImage
                readonly property string attachmentName: root.fileNameFor(model)
                readonly property string previewSource: model.preview_source || ""
                readonly property bool isDownloading: root.downloadingAttachmentId === model.id

                Component.onCompleted: {
                    if (isImage && previewSource.length === 0)
                        Backend.ensureImagePreview(model.id)
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
                                             tsText.implicitWidth,
                                             isMe ? 0 : senderLabel.implicitWidth) + 24,
                                      listView.width * 0.72)
                    implicitHeight: (isMe ? 0 : senderLabel.implicitHeight + 2)
                                  + (showMessageText ? msgText.implicitHeight : 0)
                                  + (isImage ? imagePreview.implicitHeight + 6 : 0)
                                  + (showFileCard ? fileCard.implicitHeight + 6 : 0)
                                  + tsText.implicitHeight + 16
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
                        text: isMe ? "" : model.sender
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

                    Text {
                        id: tsText
                        anchors.top: isImage ? imagePreview.bottom : (showFileCard ? fileCard.bottom : msgText.bottom)
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 4
                        text: root.formatTime(model.ts)
                        color: Theme.textSecondary
                        font.pixelSize: Theme.fontXs
                        font.family: Theme.fontFamily
                        verticalAlignment: Text.AlignBottom
                    }
                }
            }

            BusyIndicator {
                id: messagesBusy
                anchors.centerIn: parent
                running: Backend.messagesLoading && msgModel.count === 0
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
            Layout.preferredHeight: Math.min(Math.max(msgInput.implicitHeight + 18, 60), 142)
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
                            Backend.requestFileAccessPermissions()
                            attachDialog.open()
                        }
                    }
                }

                TextArea {
                    id: msgInput
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(Math.max(implicitHeight, 40), 124)
                    Layout.alignment: Qt.AlignVCenter
                    placeholderText: ""
                    wrapMode: TextEdit.Wrap
                    selectByMouse: true
                    inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase
                    color: Theme.textPrimary
                    font.pixelSize: Theme.fontMd
                    font.family: Theme.fontFamily
                    topPadding: 8
                    bottomPadding: 8
                    leftPadding: 14
                    rightPadding: 14
                    onTextChanged: if (text.length > 0) root.sendLocked = false

                    background: Rectangle {
                        radius: Theme.radiusMd
                        color: Theme.bgInput
                        border.color: Theme.border
                        border.width: 1
                    }

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: msgInput.leftPadding
                        anchors.top: parent.top
                        anchors.topMargin: msgInput.topPadding
                        text: "Сообщение…"
                        color: Theme.textHint
                        font.pixelSize: Theme.fontMd
                        font.family: Theme.fontFamily
                        visible: !msgInput.activeFocus && msgInput.text.length === 0
                        z: 1
                    }

                    Keys.onPressed: function(event) {
                        if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                                && (event.modifiers & Qt.ControlModifier)) {
                            sendBtn.clicked()
                            event.accepted = true
                        }
                    }
                }

                // Send button
                Rectangle {
                    Layout.preferredWidth: 40
                    Layout.preferredHeight: 40
                    Layout.alignment: Qt.AlignVCenter
                    radius: Theme.radiusSm
                    color: root.sendLocked ? Theme.accentDim : (sendArea.containsMouse ? Theme.accentHover : Theme.accent)
                    visible: msgInput.text.trim().length > 0

                    Canvas {
                        anchors.fill: parent
                        onPaint: {
                            const ctx = getContext("2d")
                            ctx.clearRect(0, 0, width, height)
                            ctx.fillStyle = Theme.textPrimary
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
                        enabled: !root.sendLocked
                        onClicked: sendBtn.clicked()
                    }
                }

                // Invisible button target for keyboard submit
                Item {
                    id: sendBtn
                    signal clicked()
                    onClicked: {
                        if (root.sendLocked) return
                        Backend.commitInputMethod()
                        let txt = msgInput.text.trim()
                        if (txt.length === 0) return
                        root.sendLocked = true
                        Backend.sendText(txt)
                        msgInput.text = ""
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
