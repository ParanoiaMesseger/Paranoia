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
    // domain -> { state: "checking"|"ok"|"error", pingMs: int, message: string }
    property var reserveStatus: ({})
    property string feedbackText: ""
    property bool feedbackError: false

    signal back()

    function setStatus(domain, status) {
        const next = Object.assign({}, root.reserveStatus)
        next[domain] = status
        root.reserveStatus = next
    }

    function pruneStatus() {
        const present = {}
        for (var i = 0; i < root.reserveDomains.length; ++i)
            present[root.reserveDomains[i]] = true
        const next = {}
        for (var d in root.reserveStatus)
            if (present[d]) next[d] = root.reserveStatus[d]
        root.reserveStatus = next
    }

    function matchesTarget(type, id) {
        return type === root.targetType && id === root.targetId
    }

    function checkDomain(domain) {
        const reserveDomain = domain.trim()
        if (reserveDomain === "") return
        root.setStatus(reserveDomain, { state: "checking", pingMs: -1, message: "" })
        Backend.checkReserveDomain(root.targetType, root.targetId, root.primaryDomain, reserveDomain)
    }

    function refreshReserveDomains() {
        root.reserveDomains = Backend.getReserveDomains(root.targetType, root.targetId, root.primaryDomain)
        root.pruneStatus()
        for (var i = 0; i < root.reserveDomains.length; ++i)
            root.checkDomain(root.reserveDomains[i])
    }

    Component.onCompleted: root.refreshReserveDomains()

    Connections {
        target: Backend
        function onReserveDomainAdded(type, id, reserve) {
            if (!root.matchesTarget(type, id)) return
            reserveDomainInput.text = ""
            root.feedbackError = false
            root.feedbackText = "Резервный домен добавлен: " + reserve
            root.refreshReserveDomains()
        }
        function onReserveDomainRemoved(type, id, reserve) {
            if (!root.matchesTarget(type, id)) return
            root.feedbackError = false
            root.feedbackText = "Резервный домен удалён: " + reserve
            root.refreshReserveDomains()
        }
        function onReserveDomainCheckFinished(type, id, reserve, ok, msg, pingMs) {
            if (!root.matchesTarget(type, id)) return
            root.setStatus(reserve, {
                state: ok ? "ok" : "error",
                pingMs: pingMs,
                message: msg
            })
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
                    text: "Резервные адреса используются как fallback при подключении. При открытии окна каждый адрес автоматически проверяется PUT-запросом на /notify; рядом с адресом показывается время отклика."
                    color: Theme.textSecondary
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    wrapMode: Text.WordWrap
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Text {
                        Layout.fillWidth: true
                        text: "Текущие резервные адреса"
                        color: Theme.textPrimary
                        font.pixelSize: Theme.fontMd
                        font.family: Theme.fontFamily
                        font.weight: Font.DemiBold
                    }

                    RefreshIconButton {
                        Layout.preferredWidth: 40
                        Layout.preferredHeight: 40
                        visible: root.reserveDomains.length > 0
                        onClicked: root.refreshReserveDomains()
                    }
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
                        readonly property var statusEntry: root.reserveStatus[reserveDomain]
                        readonly property string checkState: statusEntry ? statusEntry.state : ""
                        readonly property int pingMs: statusEntry ? statusEntry.pingMs : -1
                        readonly property string checkMessage: statusEntry ? statusEntry.message : ""

                        ColumnLayout {
                            id: reserveItemContent
                            anchors.fill: parent
                            anchors.margins: 10
                            spacing: 6

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10

                                Text {
                                    Layout.fillWidth: true
                                    Layout.minimumWidth: 0
                                    text: reserveDomain
                                    color: Theme.textPrimary
                                    font.pixelSize: Theme.fontSm
                                    font.family: Theme.fontFamily
                                    elide: Text.ElideRight
                                }

                                Text {
                                    Layout.alignment: Qt.AlignVCenter
                                    text: {
                                        if (checkState === "checking") return "проверка…"
                                        if (checkState === "ok")       return pingMs + " ms"
                                        if (checkState === "error")    return "недоступен"
                                        return "—"
                                    }
                                    color: {
                                        if (checkState === "ok")    return Theme.success
                                        if (checkState === "error") return Theme.error
                                        return Theme.textSecondary
                                    }
                                    font.pixelSize: Theme.fontSm
                                    font.family: Theme.fontFamily
                                    font.weight: Font.DemiBold
                                }

                                Rectangle {
                                    Layout.preferredWidth: 32
                                    Layout.preferredHeight: 32
                                    radius: Theme.radiusMd
                                    color: removeArea.containsMouse ? Theme.error : Theme.errorBg
                                    border.width: 1
                                    border.color: Theme.error

                                    Canvas {
                                        anchors.centerIn: parent
                                        width: 14
                                        height: 14
                                        antialiasing: true

                                        property color iconColor: Theme.error
                                        onIconColorChanged: requestPaint()

                                        onPaint: {
                                            const ctx = getContext("2d")
                                            ctx.clearRect(0, 0, width, height)
                                            ctx.strokeStyle = iconColor
                                            ctx.lineWidth = 2
                                            ctx.lineCap = "round"

                                            ctx.beginPath()
                                            ctx.moveTo(width * 0.27, height * 0.27)
                                            ctx.lineTo(width * 0.73, height * 0.73)
                                            ctx.moveTo(width * 0.73, height * 0.27)
                                            ctx.lineTo(width * 0.27, height * 0.73)
                                            ctx.stroke()
                                        }
                                    }

                                    MouseArea {
                                        id: removeArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            if (root.targetType === "client")
                                                Backend.removeClientReserveDomain(root.targetId, reserveDomain)
                                            else
                                                Backend.removeAdminReserveDomain(root.primaryDomain, reserveDomain)
                                        }
                                    }
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                visible: checkState === "error" && checkMessage.length > 0
                                text: checkMessage
                                color: Theme.error
                                font.pixelSize: Theme.fontSm
                                font.family: Theme.fontFamily
                                wrapMode: Text.WordWrap
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
