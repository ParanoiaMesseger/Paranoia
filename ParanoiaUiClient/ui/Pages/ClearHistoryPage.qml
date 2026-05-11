import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import ParanoiaUiClient

Rectangle {
    id: root
    color: Theme.bgPrimary

    required property string peer

    signal back()

    Connections {
        target: Backend
        function onServerHistoryCleared(peer) { serverHistoryFeedback.text = "История на сервере удалена ✓" }
        function onServerHistoryError(msg)    { serverHistoryFeedback.text = msg }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        ParaHeader {
            Layout.fillWidth: true
            title: "Удалить серверную историю"
            onBackClicked: root.back()
        }

        Flickable {
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentHeight: contentCol.implicitHeight
            clip: true

            ColumnLayout {
                id: contentCol
                width: parent.width
                spacing: 16
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 20

                Text {
                    Layout.fillWidth: true
                    text: root.peer
                    color: Theme.textSecondary
                    font.pixelSize: Theme.fontSm
                    font.family:    Theme.fontFamily
                }

                Text {
                    Layout.fillWidth: true
                    text: "Удалить с сервера все сообщения до указанного номера (seq) включительно. Введите 0 для удаления всей истории диалога."
                    color: Theme.textSecondary
                    font.pixelSize: Theme.fontSm
                    font.family:    Theme.fontFamily
                    wrapMode: Text.WordWrap
                }

                ParaInput {
                    id: cutSeqInput
                    Layout.fillWidth: true
                    label:       "Номер сообщения (seq)"
                    placeholder: "0 = вся история"
                }

                Text {
                    id: serverHistoryFeedback
                    Layout.fillWidth: true
                    color: text.includes("✓") ? Theme.success : Theme.error
                    font.pixelSize: Theme.fontSm
                    font.family:    Theme.fontFamily
                    wrapMode: Text.WordWrap
                    visible: text.length > 0
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12

                    ParaButton {
                        Layout.fillWidth: true
                        text: "Удалить"
                        onClicked: {
                            let seq = parseInt(cutSeqInput.text) || 0
                            Backend.clearServerHistory(root.peer, seq)
                        }
                    }

                    ParaButton {
                        Layout.fillWidth: true
                        text: "Закрыть"
                        secondary: true
                        onClicked: root.back()
                    }
                }

                Item { Layout.preferredHeight: 16 }
            }
        }
    }
}
