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
    // Share-target: если приложение открыли через системный share-sheet,
    // показываем баннер «выберите чат» и передаём содержимое в выбранный
    // ChatPage через signal openChat (Main.qml собирает props).
    property string shareTargetText: ""
    property var shareTargetFiles: []
    readonly property bool hasShareTarget: shareTargetText.length > 0 || (shareTargetFiles && shareTargetFiles.length > 0)
    signal cancelShareTarget()

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
    signal openRegisterUser(string domain)
    signal openAddReserveDomain(string targetType, string targetId, string primaryDomain)
    signal openVersionInfo()
    signal openChangePin()
    signal openMasking()

    function reserveDomainsText(domains) {
        if (!domains || domains.length === 0)
            return qsTr("Администратор")
        return qsTr("Резерв: %1").arg(domains.join(", "))
    }

    function contentIndexForTab(tabIndex) {
        if (root.hasAdminAccess)
            return tabIndex
        return tabIndex === 0 ? 0 : 2
    }

    // Закрывает верхний открытый попап. Возвращает true, если что-то закрыл.
    function handleBackButton(): bool {
        var popups = [
            clearDialogPopup,
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

    // Список всех диалогов (источник); отображается отфильтрованным/отсортированным.
    property var allDialogs: Backend.getDialogs()
    // Строка поиска по имени собеседника.
    property string dialogQuery: ""

    // Фильтр по имени + сортировка: непрочитанные сверху, затем по убыванию
    // количества непрочитанных, затем по алфавиту.
    function filteredDialogs() {
        const q = root.dialogQuery.trim().toLowerCase()
        const src = (root.allDialogs || []).filter(function(d) {
            return q === "" || (d.peer || "").toLowerCase().indexOf(q) !== -1
        })
        return src.slice().sort(function(a, b) {
            const ua = a.unreadCount || 0
            const ub = b.unreadCount || 0
            if ((ua > 0) !== (ub > 0)) return ua > 0 ? -1 : 1
            if (ua !== ub) return ub - ua
            return (a.peer || "").localeCompare(b.peer || "")
        })
    }

    Connections {
        target: Backend
        function onDialogsChanged()    { root.allDialogs = Backend.getDialogs(); root.refreshSessions() }
        function onAdminStateChanged() { adminServersView.model = Backend.getAdminServers() }
        function onDialogDeleted(peer) { root.allDialogs = Backend.getDialogs() }
        function onSessionsChanged()   { root.refreshSessions() }
    }

    Connections {
        target: Chat
        function onDialogsChanged() { root.allDialogs = Backend.getDialogs() }
    }

    Connections {
        target: Notifications
        function onDialogsChanged() { root.allDialogs = Backend.getDialogs(); root.refreshSessions() }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing:      0

        // ── Share-target banner ───────────────────────────
        Rectangle {
            id: shareBanner
            Layout.fillWidth: true
            Layout.preferredHeight: root.hasShareTarget ? 56 : 0
            visible: root.hasShareTarget
            color: Theme.accentDim

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 8
                spacing: 8

                Column {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 2
                    Text {
                        text: qsTr("Поделиться в чат — выберите получателя")
                        color: Theme.textPrimary
                        font.pixelSize: Theme.fontSm
                        font.family: Theme.fontFamily
                        font.weight: Font.Medium
                        elide: Text.ElideRight
                    }
                    Text {
                        width: parent.width
                        text: {
                            if (root.shareTargetText.length > 0)
                                return root.shareTargetText.length > 70
                                       ? root.shareTargetText.substring(0, 70) + "…"
                                       : root.shareTargetText
                            if (root.shareTargetFiles && root.shareTargetFiles.length > 0)
                                return qsTr("Файлов: %1").arg(root.shareTargetFiles.length)
                            return ""
                        }
                        color: Theme.textSecondary
                        font.pixelSize: Theme.fontXs
                        font.family: Theme.fontFamily
                        elide: Text.ElideRight
                    }
                }

                Rectangle {
                    Layout.preferredWidth: 36
                    Layout.preferredHeight: 36
                    Layout.alignment: Qt.AlignVCenter
                    radius: Theme.radiusSm
                    color: shareCancelArea.containsMouse ? Theme.bgCard : "transparent"
                    border.width: 1
                    border.color: Theme.border
                    AppIcon {
                        anchors.centerIn: parent
                        width: 16; height: 16
                        name: "close"
                        iconColor: Theme.accentHover
                        strokeWidth: 2
                    }
                    MouseArea {
                        id: shareCancelArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.cancelShareTarget()
                    }
                }
            }
        }

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

                AppIcon {
                    anchors.centerIn: parent
                    width: 20
                    height: 20
                    name: "importExport"
                    iconColor: Theme.accentHover
                    strokeWidth: 2
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
                model: root.hasAdminAccess ? [qsTr("Чаты"), qsTr("Админ"), "+"] : [qsTr("Чаты"), "+"]

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
                        text:           qsTr("Нет клиентского профиля")
                        color:          Theme.textSecondary
                        font.pixelSize: Theme.fontMd
                        font.family:    Theme.fontFamily
                    }
                    ParaButton {
                        text:      qsTr("Импортировать профиль")
                        onClicked: root.openImport()
                    }
                    ParaButton {
                        text:      qsTr("Регистрация клиентом")
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
                                text:  Backend.server
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

                            // Индикатор маскировки: refresh (сверка идёт),
                            // check (сверено/применено), x (ошибка). Скрыт, если
                            // профиль не задаёт раздачу маски. Тап — экран маскировки.
                            Item {
                                id: maskIndicator
                                anchors.verticalCenter: parent.verticalCenter
                                width: 18; height: 18
                                readonly property string ms: Backend.maskingState
                                visible: ms.length > 0

                                AppIcon {
                                    anchors.centerIn: parent
                                    width: 14; height: 14
                                    name: parent.ms === "checking" ? "refresh"
                                          : parent.ms === "error"    ? "x" : "check"
                                    iconColor: parent.ms === "error" ? Theme.error
                                               : parent.ms === "checking" ? Theme.textSecondary
                                               : Theme.success
                                    strokeWidth: 2

                                    RotationAnimator on rotation {
                                        running: maskIndicator.ms === "checking"
                                        from: 0; to: 360; duration: 900
                                        loops: Animation.Infinite
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.openMasking()
                                }
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
                                text:  qsTr("%1 серв.").arg(root.sessionsData.length)
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
                                text: qsTr("Резерв")
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

                    // Поиск по диалогам
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.leftMargin: 8
                        Layout.rightMargin: 8
                        Layout.topMargin: 6
                        height: 36
                        radius: Theme.radiusMd
                        color: Theme.bgInput
                        border.width: 1
                        border.color: dialogSearchField.activeFocus ? Theme.accent : Theme.border
                        Behavior on border.color { ColorAnimation { duration: 100 } }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 10
                            anchors.rightMargin: 8
                            spacing: 6

                            // Иконка поиска — AppIcon (SVG), а не юникод-глиф:
                            // на Android шрифт может не иметь «⌕» и он не рендерится.
                            AppIcon {
                                Layout.preferredWidth: 16
                                Layout.preferredHeight: 16
                                Layout.alignment: Qt.AlignVCenter
                                name: "search"
                                iconColor: Theme.textHint
                                strokeWidth: 2
                            }
                            TextField {
                                id: dialogSearchField
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                color: Theme.textPrimary
                                font.pixelSize: Theme.fontSm
                                font.family: Theme.fontFamily
                                background: null
                                verticalAlignment: TextInput.AlignVCenter
                                // Обнуляем паддинги, чтобы вводимый текст
                                // начинался ровно там же, где placeholder.
                                topPadding: 0
                                bottomPadding: 0
                                leftPadding: 0
                                rightPadding: 0
                                inputMethodHints: Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase
                                onTextChanged: root.dialogQuery = text

                                // Собственный placeholder вместо встроенного: в
                                // Material-стиле (Android) встроенный «всплывает»
                                // вверх и наезжает на границу поля.
                                Text {
                                    anchors.fill: parent
                                    verticalAlignment: Text.AlignVCenter
                                    visible: dialogSearchField.text.length === 0
                                    text: qsTr("Поиск по имени…")
                                    color: Theme.textHint
                                    font: dialogSearchField.font
                                    elide: Text.ElideRight
                                }
                            }
                            Rectangle {
                                Layout.preferredWidth: 24
                                Layout.preferredHeight: 24
                                Layout.alignment: Qt.AlignVCenter
                                visible: dialogSearchField.text !== ""
                                radius: Theme.radiusSm
                                color: "transparent"
                                AppIcon {
                                    anchors.centerIn: parent
                                    width: 14; height: 14
                                    name: "close"
                                    iconColor: Theme.textHint
                                    strokeWidth: 2
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    anchors.margins: -4
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: { dialogSearchField.text = ""; root.dialogQuery = "" }
                                }
                            }
                        }
                    }

                    // Dialogs list
                    ListView {
                        id:               dialogsView
                        Layout.fillWidth: true
                        Layout.fillHeight:true
                        model:            root.filteredDialogs()
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
                                            return modelData.lastMsg ? String(modelData.lastMsg).replace(/\s+/g, " ") : qsTr("Нет сообщений")
                                        }
                                        color: !modelData.hasKey ? Theme.error : Theme.textSecondary
                                        font.pixelSize: Theme.fontSm
                                        font.family:    Theme.fontFamily
                                        elide:          Text.ElideRight
                                        wrapMode:       Text.NoWrap
                                        maximumLineCount: 1
                                        clip:           true
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

                                AppIcon {
                                    anchors.centerIn: parent
                                    width: 20
                                    height: 20
                                    name: "moreVertical"
                                    iconColor: Theme.textSecondary
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
                                    text:           qsTr("Нет диалогов")
                                    color:          Theme.textSecondary
                                    font.pixelSize: Theme.fontMd
                                    font.family:    Theme.fontFamily
                                }
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text:           qsTr("Нажмите + для добавления")
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

                            AppIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 20
                                height: 20
                                name: "plus"
                                iconColor: Theme.accent
                                strokeWidth: 2.2
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text:  qsTr("Добавить диалог")
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
                        text:           qsTr("Нет администрируемых серверов")
                        color:          Theme.textSecondary
                        font.pixelSize: Theme.fontMd
                        font.family:    Theme.fontFamily
                    }
                    ParaButton {
                        text:      qsTr("Установить сервер")
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
                                text:           qsTr("Резерв")
                                secondary:      true
                                implicitWidth:  86
                                implicitHeight: 36
                                onClicked:      root.openAddReserveDomain("admin", modelData.domain, modelData.domain)
                            }

                            ParaButton {
                                text:           qsTr("Пользователь")
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
                        text:             qsTr("Добавить профиль или сервер")
                        color:            Theme.textPrimary
                        font.pixelSize:   Theme.fontLg
                        font.family:      Theme.fontFamily
                        font.weight:      Font.Medium
                    }

                    Item { Layout.preferredHeight: 8 }

                    ParaButton {
                        Layout.fillWidth: true
                        text:             qsTr("Импорт")
                        onClicked:        root.openImport()
                    }

                    ParaButton {
                        Layout.fillWidth: true
                        text:             qsTr("Регистрация")
                        secondary:        true
                        onClicked:        root.registerClient()
                    }

                    ParaButton {
                        Layout.fillWidth: true
                        text:             qsTr("Установить свой сервер")
                        secondary:        true
                        onClicked:        root.installNewServer()
                    }

                    ParaButton {
                        Layout.fillWidth: true
                        text:             qsTr("Маскировка трафика")
                        secondary:        true
                        onClicked:        root.openMasking()
                    }

                    ParaButton {
                        Layout.fillWidth: true
                        text:             qsTr("Сменить PIN-код")
                        secondary:        true
                        onClicked:        root.openChangePin()
                    }

                    ParaButton {
                        Layout.fillWidth: true
                        text:             qsTr("Версия приложения")
                        secondary:        true
                        onClicked:        root.openVersionInfo()
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
                    text: qsTr("Обновить ключ диалога")
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

            // ── Очистить диалог ────────────────────────────────────────────
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
                    text: qsTr("Очистить диалог")
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
                        clearDialogTarget.text = dlgContextMenu.selectedPeer
                        clearDialogPopup.open()
                    }
                }
            }

            // ── Separator ──────────────────────────────────────────────────
            Rectangle {
                width: contextMenuColumn.width
                height: 1
                color: Theme.separator
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
                    text: qsTr("Удалить диалог")
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
                text: qsTr("Для начала переписки оба участника должны ввести одинаковый общий секрет. Обновите ключ через меню диалога (⋮).")
                color: Theme.textSecondary
                font.pixelSize: Theme.fontSm
                font.family:    Theme.fontFamily
                wrapMode: Text.WordWrap
            }
            ParaButton {
                Layout.alignment: Qt.AlignHCenter
                text: qsTr("Понятно")
                onClicked: noKeyWarning.close()
            }
        }
    }

    // ── Попап: очистить диалог (сервер + локально, ключи сохраняются) ───
    Popup {
        id: clearDialogPopup
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
                text:  qsTr("Очистить диалог")
                color: Theme.textPrimary
                font.pixelSize: Theme.fontLg
                font.family:    Theme.fontFamily
                font.weight:    Font.Medium
            }

            Text {
                id: clearDialogTarget
                Layout.fillWidth: true
                color: Theme.textSecondary
                font.pixelSize: Theme.fontSm
                font.family:    Theme.fontFamily
            }

            Text {
                Layout.fillWidth: true
                text: qsTr("Вся история (тексты и файлы) удалится и с сервера, и на этом устройстве. На втором устройстве/у собеседника история исчезнет при следующей синхронизации. Ключ диалога сохраняется — можно продолжить переписку.")
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
                    text: qsTr("Очистить")
                    onClicked: {
                        Backend.clearDialogHistory(clearDialogTarget.text)
                        clearDialogPopup.close()
                    }
                }

                ParaButton {
                    Layout.fillWidth: true
                    text: qsTr("Отмена")
                    secondary: true
                    onClicked: clearDialogPopup.close()
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
                text:  qsTr("Серверы")
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
                text:  qsTr("Удалить диалог")
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
                text: qsTr("Удалить диалог, локальную историю и ключ с этого устройства. На сервере зашифрованные данные останутся.")
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
                    text: qsTr("Удалить")
                    onClicked: {
                        let peer = deleteDialogTarget.text
                        Backend.deleteDialogLocal(peer)
                        Backend.removeDialog(peer)
                        deleteDialogPopup.close()
                    }
                }

                ParaButton {
                    Layout.fillWidth: true
                    text: qsTr("Отмена")
                    secondary: true
                    onClicked: deleteDialogPopup.close()
                }
            }
        }
    }

}
