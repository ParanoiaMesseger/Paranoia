import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import ParanoiaUiClient

Rectangle {
    id: root
    color: Theme.bgPrimary

    required property string targetType
    required property string targetId
    required property string primaryDomain

    property string feedbackText: ""
    property bool feedbackError: false

    signal back()

    Connections {
        target: Backend
        function onReserveDomainAdded(type, id, reserve) {
            if (type !== root.targetType || id !== root.targetId)
                return
            root.feedbackError = false
            root.feedbackText = "Резервный домен добавлен: " + reserve
            root.back()
        }
        function onReserveDomainError(msg) {
            root.feedbackError = true
            root.feedbackText = msg
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        ParaHeader {
            Layout.fillWidth: true
            title: root.targetType === "client" ? "Резерв клиента" : "Резерв админа"
            onBackClicked: root.back()
        }

        Flickable {
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentHeight: contentCol.implicitHeight + 32
            clip: true

            ColumnLayout {
                id: contentCol
                width: parent.width
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: 24
                spacing: 16

                Item { Layout.preferredHeight: 8 }

                Text {
                    Layout.fillWidth: true
                    text: "Основной адрес: " + root.primaryDomain
                    color: Theme.textSecondary
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    elide: Text.ElideRight
                }

                Text {
                    Layout.fillWidth: true
                    text: "Укажите уже настроенный резервный адрес. Приложение только сохранит его и будет использовать как fallback при подключении."
                    color: Theme.textSecondary
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    wrapMode: Text.WordWrap
                }

                ParaInput {
                    id: reserveDomainInput
                    Layout.fillWidth: true
                    label: "Резервный домен"
                    placeholder: "cdn.example.com"
                }

                Text {
                    Layout.fillWidth: true
                    visible: root.feedbackText.length > 0
                    text: root.feedbackText
                    color: root.feedbackError ? Theme.error : Theme.textSecondary
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                }

                ParaButton {
                    Layout.fillWidth: true
                    text: "Добавить резервный домен"
                    onClicked: {
                        const reserveDomain = reserveDomainInput.text.trim()
                        if (reserveDomain === "") {
                            root.feedbackError = true
                            root.feedbackText = "Укажите резервный домен."
                            return
                        }
                        root.feedbackError = false
                        root.feedbackText = ""
                        if (root.targetType === "client")
                            Backend.addClientReserveDomain(root.targetId, reserveDomain)
                        else
                            Backend.addAdminReserveDomain(root.primaryDomain, reserveDomain)
                    }
                }

                Item { Layout.preferredHeight: 16 }
            }
        }
    }
}
