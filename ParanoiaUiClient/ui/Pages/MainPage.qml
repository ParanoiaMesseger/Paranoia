import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Dialogs
import ParanoiaUiClient
import QtQuick.VectorImage

Rectangle {
    id: root
    color: Theme.bgPrimary

    property bool hasAdminAccess: Backend.hasAdminAccess
    property string highlightProfileId: ""
    property string highlightPeer: ""
    property var sessionsData: []

    function refreshSessions() { sessionsData = Backend.getSessionList() }
    function currentProfileId() {
        for (let i = 0; i < sessionsData.length; ++i) {
            if (sessionsData[i].isActive)
                return sessionsData[i].profileId || ""
        }
        return ""
    }

    readonly property string activeProfileId: currentProfileId()

    signal openChat(string profileId, string peer)
    signal registerClient()
    signal installNewServer()
    signal openExportImport()
    signal openImport()
    signal openAddDialog()
    signal openUpdateKey(string peer)
    signal openClearHistory(string peer)
    signal openRegisterUser(string domain)
    signal openAddReserveDomain(string targetType, string targetId, string primaryDomain)

    function reserveDomainsText(domains) {
        if (!domains || domains.length === 0)
            return "Администратор"
        return "Резерв: " + domains.join(", ")
    }

    function contentIndexForTab(tabIndex) {
        if (root.hasAdminAccess)
            return tabIndex
        return tabIndex === 0 ? 0 : 2
    }

    // Закрывает верхний открытый попап. Возвращает true, если что-то закрыл.
    function handleBackButton(): bool {
        var popups = [
            deleteLocalPopup,
            deleteDialogPopup,
            noKeyWarning
        ]
        for (var i = 0; i < popups.length; i++) {
            if (popups[i].opened) {
                popups[i].close()
                return true
            }
        }
        return false
    }

    onHasAdminAccessChanged: {
        if (!root.hasAdminAccess && tabBar.currentIndex > 1)
            tabBar.currentIndex = 1
    }

    Component.onCompleted: root.refreshSessions()

    Connections {
        target: Backend
        function onDialogsChanged()    { dialogsView.model = Backend.getDialogs(); root.refreshSessions() }
        function onAdminStateChanged() { adminServersView.model = Backend.getAdminServers() }
        function onDialogDeleted(peer) { dialogsView.model = Backend.getDialogs() }
        function onSessionsChanged()   { root.refreshSessions() }
    }

    Connections {
        target: Chat
        function onDialogsChanged() { dialogsView.model = Backend.getDialogs() }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing:      0

        // ── Заголовок ─────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            height:           56
            color:            Theme.bgDark

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width; height: 2
                color: Theme.accentDim
            }

            Rectangle {
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                width: parent.width * .22; height: 2
                color: Theme.accent
            }

            VectorImage {
                id: logoSymbol
                anchors.left: parent.left
                anchors.leftMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                width: 32; height: 32
                source: "qrc:/logo_symbol_animated.svg"
                fillMode: VectorImage.PreserveAspectFit
                preferredRendererType: VectorImage.CurveRenderer
                animations.loops: Animation.Infinite
                assumeTrustedSource: true

                scale: symbolArea.containsPress ? 0.82 : 1.0
                Behavior on scale {
                    NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                }

                MouseArea {
                    id: symbolArea
                    anchors.fill: parent
                    anchors.margins: -6
                    onClicked: Theme.toggleTheme()
                }
            }

            Text {
                anchors.centerIn: parent
                text:             "PARANOIA"
                color:            Theme.textPrimary
                font.pixelSize:   Theme.fontLg
                font.family:      Theme.fontFamily
                font.weight:      Font.DemiBold
            }

            Rectangle {
                anchors.right:         parent.right
                anchors.rightMargin:   12
                anchors.verticalCenter: parent.verticalCenter
                width: 32; height: 32
                radius: Theme.radiusSm
                color: exportArea.containsMouse ? Theme.bgCard : "transparent"
                border.width: exportArea.containsMouse ? 1 : 0
                border.color: Theme.border

                Text {
                    anchors.centerIn: parent
                    text:  "IO"
                    color: Theme.accentHover
                    font.pixelSize: 12
                    font.family: Theme.monoFamily
                    font.weight: Font.DemiBold
                }
                MouseArea {
                    id: exportArea
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: root.openExportImport()
                }
            }
        }

        // ── TabBar ─────────────────────────────────────────
        TabBar {
            id: tabBar
            Layout.fillWidth: true
            background: Rectangle { color: Theme.bgDark }

            Repeater {
                model: root.hasAdminAccess ? ["Чаты", "Админ", "+"] : ["Чаты", "+"]

                TabButton {
                    required property string modelData
                    required property int    index

                    text: modelData

                    background: Rectangle {
                        color: tabBar.currentIndex === index
                                ? Theme.bgPrimary : Theme.bgDark
                        Rectangle {
                            anchors.bottom: parent.bottom
                            width: parent.width; height: 2
                            color: tabBar.currentIndex === index
                                   ? Theme.accent : "transparent"
                        }
                    }
                    contentItem: Text {
                        text:                parent.text
                        color:               tabBar.currentIndex === index
                                              ? Theme.accent : Theme.textSecondary
                        font.pixelSize:      Theme.fontMd
                        font.family:         Theme.fontFamily
                        font.weight:         Font.Medium
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment:   Text.AlignVCenter
                    }
                }
            }
        }

        // ── Контент вкладок ───────────────────────────────
        StackLayout {
            Layout.fillWidth:  true
            Layout.fillHeight: true
            currentIndex:      root.contentIndexForTab(tabBar.currentIndex)

            // ── USER tab ──────────────────────────────────
            Rectangle {
                color: Theme.bgPrimary

                // Not logged in message
                Column {
                    anchors.centerIn: parent
                    spacing:          12
                    visible: !Backend.loggedIn

                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text:           "Нет клиентского профиля"
                        color:          Theme.textSecondary
                        font.pixelSize: Theme.fontMd
                        font.family:    Theme.fontFamily
                    }
                    ParaButton {
                        text:      "Импортировать профиль"
                        onClicked: root.openImport()
                    }
                    ParaButton {
                        text:      "Регистрация клиентом"
                        secondary: true
                        onClicked: root.registerClient()
                    }
                }

                ColumnLayout {
                    anchors.fill:    parent
                    anchors.margins: 0
                    spacing:         0
                    visible: Backend.loggedIn

                    // Server header
                    Rectangle {
                        Layout.fillWidth: true
                        height:           36
                        color:            (root.sessionsData.length > 1 && sessionHdrArea.containsMouse)
                                          ? Theme.bgDark : Theme.bgSecondary

                        Row {
                            anchors.left:           parent.left
                            anchors.right:          reserveClientButton.left
                            anchors.top:            parent.top
                            anchors.bottom:         parent.bottom
                            anchors.leftMargin:     16
                            anchors.rightMargin:    4
                            spacing:                8

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text:  "NODE // " + Backend.server
                                color: Theme.textPrimary
                                font.pixelSize: Theme.fontSm
                                font.family:    Theme.fontFamily
                                font.weight:    Font.Medium
                                elide: Text.ElideRight
                                width: Math.min(implicitWidth, parent.width - 80)
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text:  "(" + Backend.username + ")"
                                color: Theme.textSecondary
                                font.pixelSize: Theme.fontXs
                                font.family:    Theme.fontFamily
                            }
                        }

                        // Session count badge — visible when >1 session
                        Rectangle {
                            id: sessionBadge
                            anchors.right:          parent.right
                            anchors.rightMargin:    8
                            anchors.verticalCenter: parent.verticalCenter
                            visible: root.sessionsData.length > 1
                            width: sessionBadgeText.implicitWidth + 10
                            height: 18
                            radius: 9
                            color: Theme.accentDim

                            Text {
                                id: sessionBadgeText
                                anchors.centerIn: parent
                                text:  root.sessionsData.length + " серв."
                                color: Theme.textPrimary
                                font.pixelSize: 9
                                font.family:    Theme.monoFamily
                                font.weight:    Font.Medium
                            }
                        }

                        Rectangle {
                            id: reserveClientButton
                            z: 2
                            anchors.right: sessionBadge.visible ? sessionBadge.left : parent.right
                            anchors.rightMargin: sessionBadge.visible ? 6 : 8
                            anchors.verticalCenter: parent.verticalCenter
                            width: 72
                            height: 26
                            radius: Theme.radiusSm
                            color: reserveClientArea.containsMouse ? Theme.bgButton : Theme.bgCard
                            border.width: 1
                            border.color: Theme.border
                            visible: Backend.loggedIn

                            Text {
                                anchors.centerIn: parent
                                text: "Резерв"
                                color: Theme.textSecondary
                                font.pixelSize: Theme.fontXs
                                font.family: Theme.fontFamily
                                font.weight: Font.Medium
                            }

                            MouseArea {
                                id: reserveClientArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.openAddReserveDomain("client", root.activeProfileId, Backend.server)
                            }
                        }

                        MouseArea {
                            id: sessionHdrArea
                            z: 0
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled:      root.sessionsData.length > 1
                            onClicked:    sessionSwitcherPopup.open()
                        }
                    }

                    // Dialogs list
                    ListView {
                        id:               dialogsView
                        Layout.fillWidth: true
                        Layout.fillHeight:true
                        model:            Backend.getDialogs()
                        clip:             true

                        ScrollBar.vertical: ScrollBar {}

                        delegate: Rectangle {
                            id: dlgItem
                            width:  ListView.view.width
                            height: 60
                            readonly property int unreadCount: modelData.unreadCount || 0
                            readonly property bool highlighted: unreadCount > 0 || modelData.notificationHint === true ||
                                                               (modelData.peer === root.highlightPeer &&
                                                                (root.highlightProfileId.length === 0 ||
                                                                 root.highlightProfileId === root.activeProfileId))
                            color:  highlighted ? Theme.bgSecondary : (dlgArea.containsMouse ? Theme.bgDark : "transparent")

                            Rectangle {
                                anchors.left: parent.left
                                anchors.top: parent.top
                                anchors.bottom: parent.bottom
                                width: 3
                                color: Theme.accent
                                visible: dlgItem.highlighted
                            }

                            Row {
                                anchors.fill:        parent
                                anchors.leftMargin:  16
                                anchors.rightMargin: 48
                                spacing:             12

                                // Аватар + индикатор ключа
                                Item {
                                    width: 38; height: 38
                                    anchors.verticalCenter: parent.verticalCenter

                                    Rectangle {
                                        anchors.fill: parent
                                        radius: 19
                                        color:  Theme.bgCard
                                        border.width: 1
                                        border.color: Theme.accentDim

                                        Text {
                                            anchors.centerIn: parent
                                            text:  modelData.peer.charAt(0).toUpperCase()
                                            color: Theme.accentHover
                                            font.pixelSize: Theme.fontMd
                                            font.weight:    Font.Bold
                                        }
                                    }

                                    Rectangle {
                                        anchors.right:  parent.right
                                        anchors.bottom: parent.bottom
                                        width: 14; height: 14
                                        radius: Theme.radiusSm
                                        color:  Theme.error
                                        visible: !modelData.hasKey

                                        Text {
                                            anchors.centerIn: parent
                                            text:  "!"
                                            color: Theme.textPrimary
                                            font.pixelSize: 8
                                            font.family: Theme.monoFamily
                                            font.weight: Font.Bold
                                        }
                                    }
                                }

                                Column {
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 3
                                    Text {
                                        text:           modelData.peer
                                        color:          dlgItem.highlighted ? Theme.accentHover : Theme.textPrimary
                                        font.pixelSize: Theme.fontMd
                                        font.family:    Theme.fontFamily
                                        font.weight:    dlgItem.highlighted ? Font.DemiBold : Font.Medium
                                    }
                                    Text {
                                        text: {
                                            if (!modelData.hasKey) return "KEY MISSING // SIGNAL BLOCKED"
                                            return modelData.lastMsg || "Нет сообщений"
                                        }
                                        color: !modelData.hasKey ? Theme.error : Theme.textSecondary
                                        font.pixelSize: Theme.fontSm
                                        font.family:    Theme.fontFamily
                                        elide:          Text.ElideRight
                                        width:          dialogsView.width - 110
                                    }
                                }
                            }

                            Rectangle {
                                anchors.right: parent.right
                                anchors.rightMargin: 44
                                anchors.verticalCenter: parent.verticalCenter
                                width: Math.max(20, unreadText.implicitWidth + 10)
                                height: 20
                                radius: 10
                                color: Theme.accent
                                visible: dlgItem.unreadCount > 0

                                Text {
                                    id: unreadText
                                    anchors.centerIn: parent
                                    text: dlgItem.unreadCount > 99 ? "99+" : dlgItem.unreadCount.toString()
                                    color: Theme.textPrimary
                                    font.pixelSize: Theme.fontXs
                                    font.family: Theme.monoFamily
                                    font.weight: Font.Bold
                                }
                            }

                            MouseArea {
                                id: dlgArea
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: {
                                    if (modelData.hasKey)
                                        root.openChat(root.activeProfileId, modelData.peer);
                                    else
                                        noKeyWarning.open();
                                }
                            }

                            // Кнопка меню диалога
                            Rectangle {
                                anchors.right:         parent.right
                                anchors.rightMargin:   8
                                anchors.verticalCenter: parent.verticalCenter
                                width: 32; height: 32
                                radius: 16
                                color:  Theme.bgDark

                                Text {
                                    anchors.centerIn: parent
                                    text:  "⋮"
                                    color: Theme.textSecondary
                                    font.pixelSize: 18
                                }

                                MouseArea {
                                    id: menuBtnArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: {
                                        dlgContextMenu.selectedPeer = modelData.peer

                                        dlgContextMenu.x = dlgItem.x + (dlgItem.width - dlgContextMenu.width - 8)
                                        dlgContextMenu.y = dlgItem.mapToItem(root, 0, 0).y + 16
                                        dlgContextMenu.open()
                                    }
                                }
                            }

                            Rectangle {
                                anchors.bottom: parent.bottom
                                width: parent.width; height: 1
                                color: Theme.separator
                            }
                        }

                        // Empty state
                        Item {
                            anchors.fill: parent
                            visible: dialogsView.count === 0

                            Column {
                                anchors.centerIn: parent
                                spacing: 8
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text:           "Нет диалогов"
                                    color:          Theme.textSecondary
                                    font.pixelSize: Theme.fontMd
                                    font.family:    Theme.fontFamily
                                }
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text:           "Нажмите + для добавления"
                                    color:          Theme.textHint
                                    font.pixelSize: Theme.fontSm
                                    font.family:    Theme.fontFamily
                                }
                            }
                        }
                    }

                    // Add dialog button
                    Rectangle {
                        Layout.fillWidth: true
                        height: 48
                        color: addArea.containsMouse ? Theme.bgSecondary : "transparent"

                        Rectangle {
                            anchors.top: parent.top
                            width: parent.width; height: 1
                            color: Theme.separator
                        }

                        Row {
                            anchors.fill:       parent
                            anchors.leftMargin: 16
                            spacing:            10

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text:  "+"
                                color: Theme.accent
                                font.pixelSize: Theme.fontLg
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text:  "Добавить диалог"
                                color: Theme.accent
                                font.pixelSize: Theme.fontSm
                                font.family:    Theme.fontFamily
                            }
                        }

                        MouseArea {
                            id:           addArea
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked:    root.openAddDialog()
                        }
                    }
                }
            }

            // ── ADMIN tab ─────────────────────────────────
            Rectangle {
                color: Theme.bgPrimary

                // No admin access message
                Column {
                    anchors.centerIn: parent
                    spacing: 12
                    visible: !root.hasAdminAccess

                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text:           "Нет администрируемых серверов"
                        color:          Theme.textSecondary
                        font.pixelSize: Theme.fontMd
                        font.family:    Theme.fontFamily
                    }
                    ParaButton {
                        text:      "Установить сервер"
                        onClicked: root.installNewServer()
                    }
                }

                ListView {
                    id: adminServersView
                    visible: root.hasAdminAccess
                    anchors.fill: parent
                    model:        Backend.getAdminServers()
                    clip:         true

                    delegate: Rectangle {
                        width:  ListView.view.width
                        height: modelData.reserveDomains && modelData.reserveDomains.length > 0 ? 78 : 64
                        color:  "transparent"

                        RowLayout {
                            anchors.fill:        parent
                            anchors.leftMargin:  16
                            anchors.rightMargin: 16

                            Column {
                                Layout.fillWidth: true
                                spacing:          4
                                Text {
                                    text:           modelData.domain
                                    color:          Theme.textPrimary
                                    font.pixelSize: Theme.fontMd
                                    font.family:    Theme.fontFamily
                                    font.weight:    Font.Medium
                                    elide:          Text.ElideRight
                                    width:          parent.width
                                }
                                Text {
                                    text:           root.reserveDomainsText(modelData.reserveDomains)
                                    color:          modelData.reserveDomains && modelData.reserveDomains.length > 0 ? Theme.textSecondary : Theme.accent
                                    font.pixelSize: Theme.fontSm
                                    font.family:    Theme.fontFamily
                                    elide:          Text.ElideRight
                                    width:          parent.width
                                }
                            }

                            ParaButton {
                                text:           "Резерв"
                                secondary:      true
                                implicitWidth:  86
                                implicitHeight: 36
                                onClicked:      root.openAddReserveDomain("admin", modelData.domain, modelData.domain)
                            }

                            ParaButton {
                                text:           "Пользователь"
                                implicitWidth:  122
                                implicitHeight: 36
                                onClicked:      root.openRegisterUser(modelData.domain)
                            }
                        }

                        Rectangle {
                            anchors.bottom: parent.bottom
                            width: parent.width; height: 1
                            color: Theme.separator
                        }
                    }
                }
            }

            // ── ADD tab ───────────────────────────────────
            Rectangle {
                color: Theme.bgPrimary

                ColumnLayout {
                    anchors.centerIn: parent
                    width:            280
                    spacing:          12

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text:             "Добавить профиль или сервер"
                        color:            Theme.textPrimary
                        font.pixelSize:   Theme.fontLg
                        font.family:      Theme.fontFamily
                        font.weight:      Font.Medium
                    }

                    Item { Layout.preferredHeight: 8 }

                    ParaButton {
                        Layout.fillWidth: true
                        text:             "Импорт"
                        onClicked:        root.openImport()
                    }

                    ParaButton {
                        Layout.fillWidth: true
                        text:             "Регистрация"
                        secondary:        true
                        onClicked:        root.registerClient()
                    }

                    ParaButton {
                        Layout.fillWidth: true
                        text:             "Установить свой сервер"
                        secondary:        true
                        onClicked:        root.installNewServer()
                    }
                }
            }
        }
    }

    // ── Контекстное меню диалога ──────────────────────────
    Popup {
        id: dlgContextMenu
        width: 236
        height: contextMenuColumn.implicitHeight + topPadding + bottomPadding
        padding: 6
        modal: false
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        z: 900

        property string selectedPeer: ""

        background: Rectangle {
            color: Theme.bgSecondary
            radius: Theme.radiusSm
            border.width: 1
            border.color: Theme.border
        }

        contentItem: Column {
            id: contextMenuColumn
            width: 224
            spacing: 2

            // ── Обновить ключ диалога ──────────────────────────────────────
            Rectangle {
                width: contextMenuColumn.width
                height: 34
                radius: Theme.radiusSm
                color: updateKeyArea.containsMouse ? Theme.bgButton : "transparent"
                Text {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    text: "Обновить ключ диалога"
                    color: Theme.textPrimary
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    elide: Text.ElideRight
                }
                MouseArea {
                    id: updateKeyArea
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: {
                        dlgContextMenu.close()
                        root.openUpdateKey(dlgContextMenu.selectedPeer)
                    }
                }
            }

            // ── Очистить историю на сервере ────────────────────────────────
            Rectangle {
                width: contextMenuColumn.width
                height: 34
                radius: Theme.radiusSm
                color: clearHistoryArea.containsMouse ? Theme.bgButton : "transparent"
                Text {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    text: "Очистить историю на сервере"
                    color: Theme.textPrimary
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    elide: Text.ElideRight
                }
                MouseArea {
                    id: clearHistoryArea
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: {
                        dlgContextMenu.close()
                        root.openClearHistory(dlgContextMenu.selectedPeer)
                    }
                }
            }

            // ── Separator ──────────────────────────────────────────────────
            Rectangle {
                width: contextMenuColumn.width
                height: 1
                color: Theme.separator
            }

            // ── Удалить локальную историю ──────────────────────────────────
            Rectangle {
                width: contextMenuColumn.width
                height: 34
                radius: Theme.radiusSm
                color: deleteLocalArea.containsMouse ? Theme.bgButton : "transparent"
                Text {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    text: "Удалить локальную историю"
                    color: Theme.textPrimary
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    elide: Text.ElideRight
                }
                MouseArea {
                    id: deleteLocalArea
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: {
                        dlgContextMenu.close()
                        deleteLocalTarget.text = dlgContextMenu.selectedPeer
                        deleteLocalPopup.open()
                    }
                }
            }

            // ── Удалить диалог (деструктивный) ────────────────────────────
            Rectangle {
                width: contextMenuColumn.width
                height: 34
                radius: Theme.radiusSm
                color: deleteDialogArea.containsMouse ? Theme.errorBg : "transparent"
                Text {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    text: "Удалить диалог"
                    color: Theme.error
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    elide: Text.ElideRight
                }
                MouseArea {
                    id: deleteDialogArea
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: {
                        dlgContextMenu.close()
                        deleteDialogTarget.text = dlgContextMenu.selectedPeer
                        deleteDialogPopup.open()
                    }
                }
            }
        }
    }

    // ── Попап: нет ключа диалога ──────────────────────────
    Popup {
        id: noKeyWarning
        anchors.centerIn: Overlay.overlay
        width: 300; padding: 24
        modal: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        background: Rectangle {
            radius: Theme.radiusLg
            color:  Theme.bgSecondary
            border.color: Theme.border
        }

        contentItem: ColumnLayout {
            spacing: 16
            Text {
                Layout.alignment: Qt.AlignHCenter
                text:  "SIGNAL BREAK // KEY MISSING"
                color: Theme.error
                font.pixelSize: Theme.fontMd
                font.family:    Theme.fontFamily
                font.weight:    Font.Medium
            }
            Text {
                Layout.fillWidth: true
                text: "Для начала переписки оба участника должны ввести одинаковый общий секрет. Обновите ключ через меню диалога (⋮)."
                color: Theme.textSecondary
                font.pixelSize: Theme.fontSm
                font.family:    Theme.fontFamily
                wrapMode: Text.WordWrap
            }
            ParaButton {
                Layout.alignment: Qt.AlignHCenter
                text: "Понятно"
                onClicked: noKeyWarning.close()
            }
        }
    }

    // ── Попап: удалить локальную историю ─────────────────
    Popup {
        id: deleteLocalPopup
        anchors.centerIn: Overlay.overlay
        width: 320; padding: 24
        modal: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        background: Rectangle {
            radius: Theme.radiusLg
            color:  Theme.bgSecondary
            border.color: Theme.border
        }

        contentItem: ColumnLayout {
            spacing: 16

            Text {
                Layout.alignment: Qt.AlignHCenter
                text:  "Удалить локальную историю"
                color: Theme.textPrimary
                font.pixelSize: Theme.fontLg
                font.family:    Theme.fontFamily
                font.weight:    Font.Medium
            }

            Text {
                id: deleteLocalTarget
                Layout.fillWidth: true
                color: Theme.textSecondary
                font.pixelSize: Theme.fontSm
                font.family:    Theme.fontFamily
            }

            Text {
                Layout.fillWidth: true
                text: "Локальная история диалога будет удалена из SQLite на этом устройстве. На сервере сообщения останутся зашифрованными."
                color: Theme.textSecondary
                font.pixelSize: Theme.fontSm
                font.family:    Theme.fontFamily
                wrapMode: Text.WordWrap
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 12

                ParaButton {
                    Layout.fillWidth: true
                    text: "Удалить"
                    onClicked: {
                        Backend.deleteDialogLocal(deleteLocalTarget.text)
                        deleteLocalPopup.close()
                    }
                }

                ParaButton {
                    Layout.fillWidth: true
                    text: "Отмена"
                    secondary: true
                    onClicked: deleteLocalPopup.close()
                }
            }
        }
    }

    // ── Попап: переключение сессий ────────────────────────
    Popup {
        id: sessionSwitcherPopup
        anchors.centerIn: Overlay.overlay
        width: 320
        padding: 12
        modal: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        background: Rectangle {
            radius: Theme.radiusLg
            color:  Theme.bgSecondary
            border.color: Theme.border
        }

        contentItem: Column {
            spacing: 4

            Text {
                width: parent.width
                text:  "Серверы"
                color: Theme.textSecondary
                font.pixelSize: Theme.fontSm
                font.family:    Theme.fontFamily
                font.weight:    Font.Medium
                leftPadding:    4
                bottomPadding:  4
            }

            Repeater {
                model: root.sessionsData

                delegate: Rectangle {
                    required property var modelData
                    width:  296
                    height: 48
                    radius: Theme.radiusSm
                    color:  modelData.isActive
                             ? Theme.bgCard
                             : (switchArea.containsMouse ? Theme.bgButton : "transparent")
                    border.width: modelData.isActive ? 1 : 0
                    border.color: Theme.accent

                    Row {
                        anchors.fill:        parent
                        anchors.leftMargin:  10
                        anchors.rightMargin: 10
                        spacing:             8

                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - (modelData.totalUnread > 0 ? 48 : 0) - 8
                            spacing: 2

                            Text {
                                text:           modelData.server
                                color:          modelData.isActive ? Theme.accent : Theme.textPrimary
                                font.pixelSize: Theme.fontSm
                                font.family:    Theme.fontFamily
                                font.weight:    modelData.isActive ? Font.DemiBold : Font.Normal
                                elide:          Text.ElideRight
                                width:          parent.width
                            }
                            Text {
                                text:           modelData.username
                                color:          Theme.textSecondary
                                font.pixelSize: Theme.fontXs
                                font.family:    Theme.fontFamily
                            }
                        }

                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: modelData.totalUnread > 0
                            width:   Math.max(24, unreadSessionText.implicitWidth + 10)
                            height:  20
                            radius:  10
                            color:   Theme.accent

                            Text {
                                id: unreadSessionText
                                anchors.centerIn: parent
                                text:  modelData.totalUnread > 99 ? "99+" : modelData.totalUnread.toString()
                                color: Theme.textPrimary
                                font.pixelSize: Theme.fontXs
                                font.family:    Theme.monoFamily
                                font.weight:    Font.Bold
                            }
                        }
                    }

                    MouseArea {
                        id: switchArea
                        anchors.fill: parent
                        hoverEnabled: true
                        enabled: !modelData.isActive
                        onClicked: {
                            Backend.switchSession(modelData.profileId)
                            sessionSwitcherPopup.close()
                        }
                    }
                }
            }
        }
    }

    // ── Попап: удалить диалог полностью ──────────────────
    Popup {
        id: deleteDialogPopup
        anchors.centerIn: Overlay.overlay
        width: 320; padding: 24
        modal: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        background: Rectangle {
            radius: Theme.radiusLg
            color:  Theme.bgSecondary
            border.color: Theme.border
        }

        contentItem: ColumnLayout {
            spacing: 16

            Text {
                Layout.alignment: Qt.AlignHCenter
                text:  "Удалить диалог"
                color: Theme.error
                font.pixelSize: Theme.fontLg
                font.family:    Theme.fontFamily
                font.weight:    Font.Medium
            }

            Text {
                id: deleteDialogTarget
                Layout.fillWidth: true
                color: Theme.textSecondary
                font.pixelSize: Theme.fontSm
                font.family:    Theme.fontFamily
            }

            Text {
                Layout.fillWidth: true
                text: "Удалить диалог, локальную историю и ключ с этого устройства. На сервере зашифрованные данные останутся."
                color: Theme.textSecondary
                font.pixelSize: Theme.fontSm
                font.family:    Theme.fontFamily
                wrapMode: Text.WordWrap
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 12

                ParaButton {
                    Layout.fillWidth: true
                    text: "Удалить"
                    onClicked: {
                        let peer = deleteDialogTarget.text
                        Backend.deleteDialogLocal(peer)
                        Backend.removeDialog(peer)
                        deleteDialogPopup.close()
                    }
                }

                ParaButton {
                    Layout.fillWidth: true
                    text: "Отмена"
                    secondary: true
                    onClicked: deleteDialogPopup.close()
                }
            }
        }
    }
}
