import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import ParanoiaUiClient

Rectangle {
    id: root
    color: Theme.bgPrimary

    required property string peer

    signal back()

    function formatTime(ts) {
        let d = new Date(ts)
        return d.getHours().toString().padStart(2, '0') + ':'
             + d.getMinutes().toString().padStart(2, '0')
    }

    Connections {
        target: Backend
        function onMessagesReceived(messages) {
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
            errorText.text = msg
            errorBar.visible = true
            errorTimer.restart()
        }
    }

    Component.onCompleted: Backend.openChat(root.peer)
    Component.onDestruction: Backend.stopChat()

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ── Header ────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            height: 56
            color: Theme.bgSecondary

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width; height: 1
                color: Theme.separator
            }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 16
                spacing: 8

                // Back button
                Rectangle {
                    width: 40; height: 40
                    radius: 20
                    color: backArea.containsMouse ? Theme.bgButton : "transparent"

                    Text {
                        anchors.centerIn: parent
                        text: "‹"
                        color: Theme.accent
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
                    radius: 18
                    color: Theme.bgButton

                    Text {
                        anchors.centerIn: parent
                        text: root.peer.charAt(0).toUpperCase()
                        color: "#FFFFFF"
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
                        text: "E2E зашифровано"
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

                Rectangle {
                    id: bubble
                    anchors.right: isMe ? parent.right : undefined
                    anchors.left:  isMe ? undefined     : parent.left
                    anchors.rightMargin: isMe ? 12 : 0
                    anchors.leftMargin:  isMe ? 0  : 12
                    anchors.verticalCenter: parent.verticalCenter

                    width: Math.min(msgText.implicitWidth + 24, listView.width * 0.72)
                    implicitHeight: msgText.implicitHeight + tsText.implicitHeight + 16
                    radius: 14
                    color: isMe ? Theme.bgButton : Theme.bgSecondary

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
                        text: model.text
                        color: Theme.textPrimary
                        font.pixelSize: Theme.fontMd
                        font.family: Theme.fontFamily
                        wrapMode: Text.WordWrap
                        lineHeight: 1.3
                    }

                    Text {
                        id: tsText
                        anchors.top: msgText.bottom
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
        }

        // ── Error bar ─────────────────────────────────────────
        Rectangle {
            id: errorBar
            Layout.fillWidth: true
            height: 36
            color: "#2A1A1C"
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
            Layout.fillWidth: true
            height: 60
            color: Theme.bgSecondary

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
                    Layout.fillWidth: true
                    height: 40
                    radius: 20
                    color: Theme.bgInput
                    border.color: Theme.border

                    TextInput {
                        id: msgInput
                        anchors.fill: parent
                        anchors.leftMargin: 16
                        anchors.rightMargin: 16
                        verticalAlignment: TextInput.AlignVCenter
                        color: Theme.textPrimary
                        font.pixelSize: Theme.fontMd
                        font.family: Theme.fontFamily
                        clip: true

                        Text {
                            anchors.fill: parent
                            verticalAlignment: Text.AlignVCenter
                            text: "Сообщение…"
                            color: Theme.textHint
                            font.pixelSize: Theme.fontMd
                            font.family: Theme.fontFamily
                            visible: parent.text.length === 0
                        }

                        Keys.onReturnPressed: sendBtn.clicked()
                        Keys.onEnterPressed:  sendBtn.clicked()
                    }
                }

                // Send button
                Rectangle {
                    width: 40; height: 40
                    radius: 20
                    color: sendArea.containsMouse ? Theme.accentHover : Theme.accent
                    visible: msgInput.text.length > 0

                    Text {
                        anchors.centerIn: parent
                        text: "➤"
                        color: "#FFFFFF"
                        font.pixelSize: 16
                    }

                    MouseArea {
                        id: sendArea
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: sendBtn.clicked()
                    }
                }

                // Invisible button target for keyboard submit
                Item {
                    id: sendBtn
                    signal clicked()
                    onClicked: {
                        let txt = msgInput.text.trim()
                        if (txt.length === 0) return
                        Backend.sendText(txt)
                        msgInput.text = ""
                    }
                }
            }
        }
    }
}
