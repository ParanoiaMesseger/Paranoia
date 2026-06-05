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

    // TURN-список доступен только для клиентских профилей (admin не звонит).
    property var turnServers: []
    property var turnStatus: ({})
    property string turnFeedbackText: ""
    property bool turnFeedbackError: false

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

    function setTurnStatus(url, status) {
        const next = Object.assign({}, root.turnStatus)
        next[url] = status
        root.turnStatus = next
    }
    function pruneTurnStatus() {
        const present = {}
        for (var i = 0; i < root.turnServers.length; ++i) present[root.turnServers[i]] = true
        const next = {}
        for (var d in root.turnStatus) if (present[d]) next[d] = root.turnStatus[d]
        root.turnStatus = next
    }
    function checkTurn(url) {
        const u = url.trim()
        if (u === "") return
        root.setTurnStatus(u, { state: "checking", pingMs: -1, message: "" })
        Backend.checkTurnServer(root.targetId, u)
    }
    function refreshTurnServers() {
        if (root.targetType !== "client") {
            root.turnServers = []
            return
        }
        root.turnServers = Backend.getTurnServers(root.targetId)
        root.pruneTurnStatus()
        for (var i = 0; i < root.turnServers.length; ++i)
            root.checkTurn(root.turnServers[i])
    }

    Component.onCompleted: {
        root.refreshReserveDomains()
        root.refreshTurnServers()
    }

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
        function onTurnServerAdded(profileId, url) {
            if (profileId !== root.targetId) return
            turnInput.text = ""
            root.turnFeedbackError = false
            root.turnFeedbackText = "TURN-сервер добавлен: " + url
            root.refreshTurnServers()
        }
        function onTurnServerRemoved(profileId, url) {
            if (profileId !== root.targetId) return
            root.turnFeedbackError = false
            root.turnFeedbackText = "TURN-сервер удалён: " + url
            root.refreshTurnServers()
        }
        function onTurnServerCheckFinished(profileId, url, ok, msg, pingMs) {
            if (profileId !== root.targetId) return
            root.setTurnStatus(url, { state: ok ? "ok" : "error", pingMs: pingMs, message: msg })
        }
        function onTurnServerError(msg) {
            root.turnFeedbackError = true
            root.turnFeedbackText = msg
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
            id: formFlick
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentHeight: Math.max(formFlick.height, contentCol.implicitHeight + 48)
            clip: true

            ColumnLayout {
                id: contentCol
                width: Math.min(parent.width - 48, 560)
                anchors.horizontalCenter: parent.horizontalCenter
                y: Math.max(24, (formFlick.height - implicitHeight) / 2)
                spacing: 16

                Item { Layout.preferredHeight: 8 }

                Text {
                    Layout.fillWidth: true
                    text: "Резервные адреса используются при проблемах с доступом к основному адресу."
                    color: Theme.textSecondary
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    wrapMode: Text.WordWrap
                }

                Text {
                    Layout.fillWidth: true
                    text: "Основной адрес: " + root.primaryDomain
                    color: Theme.textSecondary
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    elide: Text.ElideRight
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

                                    AppIcon {
                                        anchors.centerIn: parent
                                        width: 14
                                        height: 14
                                        name: "close"
                                        iconColor: Theme.error
                                        strokeWidth: 3
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

                // ── Резервные TURN-серверы (только для клиентских профилей) ──
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 1
                    color: Theme.border
                    visible: root.targetType === "client"
                }

                Text {
                    Layout.fillWidth: true
                    visible: root.targetType === "client"
                    text: "Резервные TURN-серверы используются для звонков, когда не удается установить прямое соединение между собеседниками и основной TURN сервер недоступен."
                    color: Theme.textSecondary
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    wrapMode: Text.WordWrap
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    visible: root.targetType === "client"

                    Text {
                        Layout.fillWidth: true
                        text: "Текущие TURN-серверы"
                        color: Theme.textPrimary
                        font.pixelSize: Theme.fontMd
                        font.family: Theme.fontFamily
                        font.weight: Font.DemiBold
                    }

                    RefreshIconButton {
                        Layout.preferredWidth: 40
                        Layout.preferredHeight: 40
                        visible: root.turnServers.length > 0
                        onClicked: root.refreshTurnServers()
                    }
                }

                Text {
                    Layout.fillWidth: true
                    visible: root.targetType === "client" && root.turnServers.length === 0
                    text: "Резервные TURN-серверы не добавлены."
                    color: Theme.textHint
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    wrapMode: Text.WordWrap
                }

                Repeater {
                    model: root.targetType === "client" ? root.turnServers : []
                    delegate: Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: turnItemContent.implicitHeight + 20
                        radius: Theme.radiusMd
                        color: Theme.bgSecondary
                        border.width: 1
                        border.color: Theme.border

                        readonly property string turnUrl: modelData
                        readonly property var turnEntry: root.turnStatus[turnUrl]
                        readonly property string turnState: turnEntry ? turnEntry.state : ""
                        readonly property string turnMsg: turnEntry ? turnEntry.message : ""

                        ColumnLayout {
                            id: turnItemContent
                            anchors.fill: parent
                            anchors.margins: 10
                            spacing: 6

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10

                                Text {
                                    Layout.fillWidth: true
                                    Layout.minimumWidth: 0
                                    text: turnUrl
                                    color: Theme.textPrimary
                                    font.pixelSize: Theme.fontSm
                                    font.family: Theme.fontFamily
                                    elide: Text.ElideRight
                                }

                                Text {
                                    Layout.alignment: Qt.AlignVCenter
                                    text: {
                                        if (turnState === "checking") return "проверка…"
                                        if (turnState === "ok")       return "ok"
                                        if (turnState === "error")    return "ошибка"
                                        return "—"
                                    }
                                    color: {
                                        if (turnState === "ok")    return Theme.success
                                        if (turnState === "error") return Theme.error
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
                                    color: turnRemoveArea.containsMouse ? Theme.error : Theme.errorBg
                                    border.width: 1
                                    border.color: Theme.error

                                    AppIcon {
                                        anchors.centerIn: parent
                                        width: 14
                                        height: 14
                                        name: "close"
                                        iconColor: Theme.error
                                        strokeWidth: 3
                                    }

                                    MouseArea {
                                        id: turnRemoveArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: Backend.removeTurnServer(root.targetId, turnUrl)
                                    }
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                visible: turnState === "error" && turnMsg.length > 0
                                text: turnMsg
                                color: Theme.error
                                font.pixelSize: Theme.fontSm
                                font.family: Theme.fontFamily
                                wrapMode: Text.WordWrap
                            }
                        }
                    }
                }

                ParaInput {
                    id: turnInput
                    Layout.fillWidth: true
                    visible: root.targetType === "client"
                    label: "Новый TURN-сервер"
                    placeholder: "turn.example.com:3478"
                }

                Text {
                    Layout.fillWidth: true
                    visible: root.targetType === "client" && root.turnFeedbackText.length > 0
                    text: root.turnFeedbackText
                    color: root.turnFeedbackError ? Theme.error : Theme.success
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                }

                ParaButton {
                    Layout.fillWidth: true
                    visible: root.targetType === "client"
                    text: "Добавить TURN-сервер"
                    onClicked: {
                        const t = turnInput.text.trim()
                        if (t === "") {
                            root.turnFeedbackError = true
                            root.turnFeedbackText = "Укажите адрес TURN-сервера."
                            return
                        }
                        root.turnFeedbackError = false
                        root.turnFeedbackText = ""
                        Backend.addTurnServer(root.targetId, t)
                    }
                }

                Item { Layout.preferredHeight: 16 }
            }
        }
    }
}
