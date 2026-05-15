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

    property var reserveDomains: []
    property string feedbackText: ""
    property bool feedbackError: false
    property string checkingDomain: ""

    signal back()

    function refreshReserveDomains() {
        root.reserveDomains = Backend.getReserveDomains(root.targetType, root.targetId, root.primaryDomain)
    }

    function matchesTarget(type, id) {
        return type === root.targetType && id === root.targetId
    }

    function checkDomain(domain) {
        const reserveDomain = domain.trim()
        if (reserveDomain === "") {
            root.feedbackError = true
            root.feedbackText = "Укажите резервный домен."
            return
        }
        root.feedbackError = false
        root.feedbackText = "Проверка /notify: " + reserveDomain
        root.checkingDomain = reserveDomain
        Backend.checkReserveDomain(root.targetType, root.targetId, root.primaryDomain, reserveDomain)
    }

    Component.onCompleted: root.refreshReserveDomains()

    Connections {
        target: Backend
        function onReserveDomainAdded(type, id, reserve) {
            if (!root.matchesTarget(type, id))
                return
            reserveDomainInput.text = ""
            root.feedbackError = false
            root.feedbackText = "Резервный домен добавлен: " + reserve
            root.refreshReserveDomains()
        }
        function onReserveDomainRemoved(type, id, reserve) {
            if (!root.matchesTarget(type, id))
                return
            root.feedbackError = false
            root.feedbackText = "Резервный домен удалён: " + reserve
            root.refreshReserveDomains()
        }
        function onReserveDomainCheckFinished(type, id, reserve, ok, msg) {
            if (!root.matchesTarget(type, id))
                return
            root.checkingDomain = ""
            root.feedbackError = !ok
            root.feedbackText = reserve + ": " + msg
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
                    text: "Резервные адреса используются как fallback при подключении. Проверка выполняет PUT-запрос на /notify и считает адрес доступным, если endpoint ответил JSON."
                    color: Theme.textSecondary
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    wrapMode: Text.WordWrap
                }

                Text {
                    Layout.fillWidth: true
                    text: "Текущие резервные адреса"
                    color: Theme.textPrimary
                    font.pixelSize: Theme.fontMd
                    font.family: Theme.fontFamily
                    font.weight: Font.DemiBold
                }

                Text {
                    Layout.fillWidth: true
                    visible: root.reserveDomains.length === 0
                    text: "Резервные адреса ещё не добавлены."
                    color: Theme.textHint
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    wrapMode: Text.WordWrap
                }

                Repeater {
                    model: root.reserveDomains
                    delegate: Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: reserveItemContent.implicitHeight + 20
                        radius: Theme.radiusMd
                        color: Theme.bgSecondary
                        border.width: 1
                        border.color: Theme.border

                        readonly property string reserveDomain: modelData

                        ColumnLayout {
                            id: reserveItemContent
                            anchors.fill: parent
                            anchors.margins: 10
                            spacing: 8

                            Text {
                                Layout.fillWidth: true
                                text: reserveDomain
                                color: Theme.textPrimary
                                font.pixelSize: Theme.fontSm
                                font.family: Theme.fontFamily
                                elide: Text.ElideRight
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8

                                ParaButton {
                                    Layout.fillWidth: true
                                    text: root.checkingDomain === reserveDomain ? "Проверка…" : "Проверить /notify"
                                    secondary: true
                                    enabled: root.checkingDomain === ""
                                    onClicked: root.checkDomain(reserveDomain)
                                }

                                ParaButton {
                                    Layout.preferredWidth: 104
                                    text: "Удалить"
                                    destructive: true
                                    enabled: root.checkingDomain === ""
                                    onClicked: {
                                        if (root.targetType === "client")
                                            Backend.removeClientReserveDomain(root.targetId, reserveDomain)
                                        else
                                            Backend.removeAdminReserveDomain(root.primaryDomain, reserveDomain)
                                    }
                                }
                            }
                        }
                    }
                }

                ParaInput {
                    id: reserveDomainInput
                    Layout.fillWidth: true
                    label: "Новый резервный домен"
                    placeholder: "cdn.example.com"
                }

                Text {
                    Layout.fillWidth: true
                    visible: root.feedbackText.length > 0
                    text: root.feedbackText
                    color: root.feedbackError ? Theme.error : Theme.success
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                }

                ParaButton {
                    Layout.fillWidth: true
                    text: "Добавить резервный домен"
                    enabled: root.checkingDomain === ""
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
