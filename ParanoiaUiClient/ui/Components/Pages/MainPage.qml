import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Dialogs
import ParanoiaUiClient

Rectangle {
    id: root
    color: Theme.bgPrimary

    property bool hasAdminAccess: Backend.hasAdminAccess
    property bool hasUserAccess:  Backend.loggedIn
    property string qrExchangePeer: ""
    property bool qrExchangeUpdateExisting: false

    signal openChat(string peer)
    signal registerClient()
    signal installNewServer()

    function contentIndexForTab(tabIndex) {
        if (root.hasAdminAccess)
            return tabIndex
        return tabIndex === 0 ? 0 : 2
    }

    onHasAdminAccessChanged: {
        if (!root.hasAdminAccess && tabBar.currentIndex > 1)
            tabBar.currentIndex = 1
    }

    Connections {
        target: Backend
        function onDialogsChanged()       { dialogsView.model = Backend.getDialogs() }
        function onAdminStateChanged()    { adminServersView.model = Backend.getAdminServers() }
        function onUserRegistered()       { regFeedback.text = "Пользователь зарегистрирован ✓"; registerUserPopup.close() }
        function onRegisterUserError(msg) { regFeedback.text = msg }
        function onDialogDeleted(peer)    { dialogsView.model = Backend.getDialogs() }
        function onServerHistoryCleared(peer) { serverHistoryFeedback.text = "История на сервере удалена ✓" }
        function onServerHistoryError(msg)    { serverHistoryFeedback.text = msg }
    }

    ExportImportPage { id: exportImportPopup }

    FileDialog {
        id: registrationQrImageDialog
        title: "Выбрать изображение QR-кода"
        fileMode: FileDialog.OpenFile
        nameFilters: ["Изображения (*.png *.jpg *.jpeg *.bmp *.webp)", "Все файлы (*)"]
        onAccepted: {
            const decoded = Backend.decodeQrCodeFromImage(root.localFilePath(selectedFile))
            if (!decoded.ok) {
                regFeedback.text = decoded.error || "QR-код не прочитан."
                return
            }
            const parsed = Backend.registrationPublicKeyFromQr(decoded.text)
            if (!parsed.ok) {
                regFeedback.text = parsed.error || "QR-код не содержит публичный ключ."
                return
            }
            newUserPubKeyInput.text = parsed.pubkey
            regFeedback.text = "QR-код прочитан ✓"
        }
    }

    FileDialog {
        id: qrPeerPayloadImageDialog
        title: "Выбрать изображение QR payload"
        fileMode: FileDialog.OpenFile
        nameFilters: ["Изображения (*.png *.jpg *.jpeg *.bmp *.webp)", "Все файлы (*)"]
        onAccepted: {
            const decoded = Backend.decodeQrCodeFromImage(root.localFilePath(selectedFile))
            if (!decoded.ok) {
                qrExchangeFeedback.text = decoded.error || "QR-код не прочитан."
                return
            }
            qrPeerPayloadJson.text = decoded.text
            qrExchangeFeedback.text = "Payload считан из QR-кода."
        }
    }

    function localFilePath(fileUrl) {
        let value = decodeURIComponent(String(fileUrl))
        if (value.startsWith("file://"))
            value = value.substring(7)
        return value
    }

    function openQrExchange(peer, updateExisting) {
        qrExchangePeer = peer
        qrExchangeUpdateExisting = updateExisting
        qrLocalStateJson.text = ""
        qrLocalPayloadJson.text = ""
        qrPeerPayloadJson.text = ""
        qrFingerprintText.text = ""
        qrExchangeFeedback.text = ""
        qrExchangePopup.open()
    }

    ColumnLayout {
        anchors.fill: parent
        spacing:      0

        // ── Заголовок ─────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            height:           56
            color:            Theme.bgSecondary

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width; height: 1
                color: Theme.separator
            }

            Text {
                anchors.centerIn: parent
                text:             "Paranoia"
                color:            Theme.textPrimary
                font.pixelSize:   Theme.fontLg
                font.family:      Theme.fontFamily
                font.weight:      Font.Medium
            }

            Rectangle {
                anchors.right:         parent.right
                anchors.rightMargin:   12
                anchors.verticalCenter: parent.verticalCenter
                width: 32; height: 32
                radius: 16
                color: exportArea.containsMouse ? Theme.bgButton : "transparent"

                Text {
                    anchors.centerIn: parent
                    text:  "⬆⬇"
                    color: Theme.textSecondary
                    font.pixelSize: 14
                }
                MouseArea {
                    id: exportArea
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: exportImportPopup.openExportImport()
                }
            }
        }

        // ── TabBar ─────────────────────────────────────────
        TabBar {
            id: tabBar
            Layout.fillWidth: true
            background: Rectangle { color: Theme.bgSecondary }

            Repeater {
                model: root.hasAdminAccess ? ["Чаты", "Админ", "+"] : ["Чаты", "+"]

                TabButton {
                    required property string modelData
                    required property int    index

                    text: modelData

                    background: Rectangle {
                        color: tabBar.currentIndex === index
                               ? Theme.bgPrimary : Theme.bgSecondary
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
                        onClicked: exportImportPopup.openImport()
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
                        color:            Theme.bgSecondary

                        Row {
                            anchors.fill:       parent
                            anchors.leftMargin: 16
                            spacing:            8

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text:  "🖥  " + Backend.server
                                color: Theme.textPrimary
                                font.pixelSize: Theme.fontSm
                                font.family:    Theme.fontFamily
                                font.weight:    Font.Medium
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text:  "(" + Backend.username + ")"
                                color: Theme.textSecondary
                                font.pixelSize: Theme.fontXs
                                font.family:    Theme.fontFamily
                            }
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
                            color:  dlgArea.containsMouse ? Theme.bgSecondary : "transparent"

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
                                        color:  Theme.bgButton

                                        Text {
                                            anchors.centerIn: parent
                                            text:  modelData.peer.charAt(0).toUpperCase()
                                            color: "#FFFFFF"
                                            font.pixelSize: Theme.fontMd
                                            font.weight:    Font.Bold
                                        }
                                    }

                                    // Иконка замка — ключ установлен
                                    Rectangle {
                                        anchors.right:  parent.right
                                        anchors.bottom: parent.bottom
                                        width: 14; height: 14
                                        radius: 7
                                        color:  modelData.hasKey ? Theme.success : Theme.error
                                        visible: true

                                        Text {
                                            anchors.centerIn: parent
                                            text:  modelData.hasKey ? "🔒" : "⚠"
                                            font.pixelSize: 8
                                        }
                                    }
                                }

                                Column {
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 3
                                    Text {
                                        text:           modelData.peer
                                        color:          Theme.textPrimary
                                        font.pixelSize: Theme.fontMd
                                        font.family:    Theme.fontFamily
                                        font.weight:    Font.Medium
                                    }
                                    Text {
                                        text: {
                                            if (!modelData.hasKey) return "⚠ Ключ не установлен"
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

                            // Кнопка меню диалога
                            Rectangle {
                                anchors.right:         parent.right
                                anchors.rightMargin:   8
                                anchors.verticalCenter: parent.verticalCenter
                                width: 32; height: 32
                                radius: 16
                                color: menuBtnArea.containsMouse ? Theme.bgSecondary : "transparent"
                                visible: dlgArea.containsMouse || menuBtnArea.containsMouse

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
                                        dlgContextMenu.popup()
                                    }
                                }
                            }

                            Rectangle {
                                anchors.bottom: parent.bottom
                                width: parent.width; height: 1
                                color: Theme.separator
                            }

                            MouseArea {
                                id:           dlgArea
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: {
                                    if (modelData.hasKey)
                                        root.openChat(modelData.peer)
                                    else
                                        noKeyWarning.open()
                                }
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
                            onClicked:    addDialogPopup.open()
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
                        height: 64
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
                                    text:           "Администратор"
                                    color:          Theme.accent
                                    font.pixelSize: Theme.fontSm
                                    font.family:    Theme.fontFamily
                                }
                            }

                            ParaButton {
                                text:           "Зарегистрировать"
                                implicitWidth:  140
                                implicitHeight: 36
                                onClicked: {
                                    registerTargetDomain = modelData.domain
                                    registerUserPopup.open()
                                }
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
                        text:             "Импорт профиля"
                        onClicked:        exportImportPopup.openImport()
                    }

                    ParaButton {
                        Layout.fillWidth: true
                        text:             "Регистрация клиентом"
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
    Menu {
        id: dlgContextMenu
        property string selectedPeer: ""

        background: Rectangle {
            radius: Theme.radiusSm
            color:  Theme.bgSecondary
            border.color: Theme.border
        }

        MenuItem {
            text: "Обновить ключ диалога"
            contentItem: Text {
                text:           parent.text
                color:          Theme.textPrimary
                font.pixelSize: Theme.fontSm
                font.family:    Theme.fontFamily
                leftPadding:    8
            }
            background: Rectangle {
                color: parent.highlighted ? Theme.bgButton : "transparent"
            }
            onTriggered: {
                updateKeyTarget.text = dlgContextMenu.selectedPeer
                updateKeyPopup.open()
            }
        }

        MenuItem {
            text: "Очистить историю на сервере"
            contentItem: Text {
                text:           parent.text
                color:          Theme.textPrimary
                font.pixelSize: Theme.fontSm
                font.family:    Theme.fontFamily
                leftPadding:    8
            }
            background: Rectangle {
                color: parent.highlighted ? Theme.bgButton : "transparent"
            }
            onTriggered: {
                serverHistoryFeedback.text = ""
                clearHistoryTarget.text = dlgContextMenu.selectedPeer
                clearHistoryPopup.open()
            }
        }

        MenuSeparator {
            contentItem: Rectangle { height: 1; color: Theme.separator }
        }

        MenuItem {
            text: "Удалить локальную историю"
            contentItem: Text {
                text:           parent.text
                color:          Theme.textPrimary
                font.pixelSize: Theme.fontSm
                font.family:    Theme.fontFamily
                leftPadding:    8
            }
            background: Rectangle {
                color: parent.highlighted ? Theme.bgButton : "transparent"
            }
            onTriggered: {
                deleteLocalTarget.text = dlgContextMenu.selectedPeer
                deleteLocalPopup.open()
            }
        }

        MenuItem {
            text: "Удалить диалог"
            contentItem: Text {
                text:           parent.text
                color:          Theme.error
                font.pixelSize: Theme.fontSm
                font.family:    Theme.fontFamily
                leftPadding:    8
            }
            background: Rectangle {
                color: parent.highlighted ? "#2A1A1C" : "transparent"
            }
            onTriggered: {
                deleteDialogTarget.text = dlgContextMenu.selectedPeer
                deleteDialogPopup.open()
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
                text:  "⚠ Ключ диалога не установлен"
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

    // ── Попап: обновить ключ диалога ──────────────────────
    Popup {
        id: updateKeyPopup
        anchors.centerIn: Overlay.overlay
        width: 320; padding: 24
        modal: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        background: Rectangle {
            radius: Theme.radiusLg
            color:  Theme.bgSecondary
            border.color: Theme.border
        }

        onOpened: { newKeyInput.text = ""; updateKeyError.text = "" }

        contentItem: ColumnLayout {
            spacing: 16

            Text {
                Layout.alignment: Qt.AlignHCenter
                text:  "Обновить ключ диалога"
                color: Theme.textPrimary
                font.pixelSize: Theme.fontLg
                font.family:    Theme.fontFamily
                font.weight:    Font.Medium
            }

            Text {
                id: updateKeyTarget
                Layout.fillWidth: true
                color: Theme.textSecondary
                font.pixelSize: Theme.fontSm
                font.family:    Theme.fontFamily
            }

            Text {
                Layout.fillWidth: true
                text: "Введите новый общий секрет. Обе стороны должны ввести одинаковое значение."
                color: Theme.textSecondary
                font.pixelSize: Theme.fontSm
                font.family:    Theme.fontFamily
                wrapMode: Text.WordWrap
            }

            ParaInput {
                id: newKeyInput
                Layout.fillWidth: true
                label:       "Новый общий секрет"
                placeholder: "секретная фраза…"
                echoMode:    TextInput.Password
            }

            ParaButton {
                Layout.fillWidth: true
                text: "Обменяться ключом через QR/JSON"
                secondary: true
                onClicked: root.openQrExchange(updateKeyTarget.text, true)
            }

            Text {
                id: updateKeyError
                Layout.fillWidth: true
                color: Theme.error
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
                    text: "Обновить"
                    onClicked: {
                        let secret = newKeyInput.text
                        if (secret.length < 4) {
                            updateKeyError.text = "Секрет слишком короткий (минимум 4 символа)."
                            return
                        }
                        Backend.updateDialogKey(updateKeyTarget.text, secret)
                        updateKeyPopup.close()
                    }
                }

                ParaButton {
                    Layout.fillWidth: true
                    text: "Отмена"
                    secondary: true
                    onClicked: updateKeyPopup.close()
                }
            }
        }
    }

    // ── Попап: очистить историю на сервере ────────────────
    Popup {
        id: clearHistoryPopup
        anchors.centerIn: Overlay.overlay
        width: 340; padding: 24
        modal: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        background: Rectangle {
            radius: Theme.radiusLg
            color:  Theme.bgSecondary
            border.color: Theme.border
        }

        onOpened: { cutSeqInput.text = ""; serverHistoryFeedback.text = "" }

        contentItem: ColumnLayout {
            spacing: 16

            Text {
                Layout.alignment: Qt.AlignHCenter
                text:  "Удалить серверную историю"
                color: Theme.textPrimary
                font.pixelSize: Theme.fontLg
                font.family:    Theme.fontFamily
                font.weight:    Font.Medium
            }

            Text {
                id: clearHistoryTarget
                Layout.fillWidth: true
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
                        Backend.clearServerHistory(clearHistoryTarget.text, seq)
                    }
                }

                ParaButton {
                    Layout.fillWidth: true
                    text: "Закрыть"
                    secondary: true
                    onClicked: clearHistoryPopup.close()
                }
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

    // ── Попап: добавить диалог ────────────────────────────
    Popup {
        id:          addDialogPopup
        anchors.centerIn: Overlay.overlay
        width:       320
        padding:     24
        modal:       true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        background: Rectangle {
            radius: Theme.radiusLg
            color:  Theme.bgSecondary
            border.color: Theme.border
        }

        onOpened: {
            newPeerInput.text    = ""
            newSecretInput.text  = ""
            addDialogError.text  = ""
        }

        contentItem: ColumnLayout {
            spacing: 16

            Text {
                Layout.alignment:   Qt.AlignHCenter
                text:               "Добавить собеседника"
                color:              Theme.textPrimary
                font.pixelSize:     Theme.fontLg
                font.family:        Theme.fontFamily
                font.weight:        Font.Medium
            }

            ParaInput {
                id:              newPeerInput
                Layout.fillWidth: true
                label:           "Имя пользователя собеседника"
                placeholder:     "username"
            }

            ParaInput {
                id:              newSecretInput
                Layout.fillWidth: true
                label:           "Общий секрет (оба вводят одинаково)"
                placeholder:     "секретная фраза…"
                echoMode:        TextInput.Password
            }

            ParaButton {
                Layout.fillWidth: true
                text: "Обменяться ключом через QR/JSON"
                secondary: true
                onClicked: {
                    let peer = newPeerInput.text.trim()
                    if (peer === "") {
                        addDialogError.text = "Введите имя пользователя."
                        return
                    }
                    root.openQrExchange(peer, false)
                }
            }

            Text {
                id: addDialogError
                Layout.fillWidth:    true
                color:               Theme.error
                font.pixelSize:      Theme.fontSm
                font.family:         Theme.fontFamily
                horizontalAlignment: Text.AlignHCenter
                wrapMode:            Text.WordWrap
                visible:             text.length > 0
            }

            RowLayout {
                Layout.fillWidth: true
                spacing:          12

                ParaButton {
                    Layout.fillWidth: true
                    text:             "Добавить"
                    onClicked: {
                        let peer   = newPeerInput.text.trim()
                        let secret = newSecretInput.text
                        if (peer === "") {
                            addDialogError.text = "Введите имя пользователя."
                            return
                        }
                        if (secret.length < 4) {
                            addDialogError.text = "Секрет слишком короткий."
                            return
                        }
                        Backend.addDialog(peer, secret)
                        addDialogPopup.close()
                    }
                }

                ParaButton {
                    Layout.fillWidth: true
                    text:             "Отмена"
                    secondary:        true
                    onClicked:        addDialogPopup.close()
                }
            }
        }
    }

    // ── Попап: QR/JSON out-of-band обмен ключом ───────────
    Popup {
        id: qrExchangePopup
        anchors.centerIn: Overlay.overlay
        width: Math.min(380, Overlay.overlay.width - 24)
        height: Math.min(720, Overlay.overlay.height - 40)
        padding: 20
        modal: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        background: Rectangle {
            radius: Theme.radiusLg
            color:  Theme.bgSecondary
            border.color: Theme.border
        }

        contentItem: ScrollView {
            clip: true
            contentWidth: availableWidth

            ColumnLayout {
                width: qrExchangePopup.availableWidth
                spacing: 12

            Text {
                Layout.alignment: Qt.AlignHCenter
                text: "QR/JSON обмен ключом"
                color: Theme.textPrimary
                font.pixelSize: Theme.fontLg
                font.family: Theme.fontFamily
                font.weight: Font.Medium
            }

            Text {
                Layout.fillWidth: true
                text: "Собеседник: " + root.qrExchangePeer
                color: Theme.textSecondary
                font.pixelSize: Theme.fontSm
                font.family: Theme.fontFamily
                elide: Text.ElideRight
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 8

                ParaButton {
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                    text: "Создать invitation"
                    onClicked: {
                        let res = Backend.createDialogKeyInvitation(root.qrExchangePeer)
                        if (!res.ok) {
                            qrExchangeFeedback.text = res.error || "Ошибка invitation."
                            return
                        }
                        qrLocalStateJson.text = res.stateJson
                        qrLocalPayloadJson.text = res.payloadJson
                        qrFingerprintText.text = ""
                        qrExchangeFeedback.text = "Передайте payload собеседнику. State не отправляйте."
                    }
                }

                ParaButton {
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                    text: "Создать response"
                    secondary: true
                    onClicked: {
                        let res = Backend.createDialogKeyResponse(qrPeerPayloadJson.text.trim())
                        if (!res.ok) {
                            qrExchangeFeedback.text = res.error || "Ошибка response."
                            return
                        }
                        qrLocalStateJson.text = res.stateJson
                        qrLocalPayloadJson.text = res.payloadJson
                        qrFingerprintText.text = res.fingerprint
                        qrExchangeFeedback.text = "Передайте response payload инициатору и сравните SAS."
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                text: "Ваш payload для передачи"
                color: Theme.textPrimary
                font.pixelSize: Theme.fontSm
                font.family: Theme.fontFamily
            }

            TextArea {
                id: qrLocalPayloadJson
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                implicitHeight: 86
                readOnly: true
                wrapMode: TextEdit.Wrap
                color: Theme.textPrimary
                selectedTextColor: Theme.textPrimary
                selectionColor: Theme.accent
                background: Rectangle { color: Theme.bgInput; border.color: Theme.border; radius: Theme.radiusSm }
            }

            QrCodeBox {
                Layout.alignment: Qt.AlignHCenter
                boxSize: Math.min(240, qrExchangePopup.availableWidth - 32)
                payload: qrLocalPayloadJson.text
                caption: "QR payload"
                visible: qrLocalPayloadJson.text.length > 0
            }

            ParaButton {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                text: "Копировать payload"
                secondary: true
                onClicked: {
                    qrLocalPayloadJson.selectAll()
                    qrLocalPayloadJson.copy()
                    qrExchangeFeedback.text = "Payload скопирован."
                }
            }

            TextArea {
                id: qrLocalStateJson
                visible: false
            }

            Text {
                Layout.fillWidth: true
                text: "Payload собеседника"
                color: Theme.textPrimary
                font.pixelSize: Theme.fontSm
                font.family: Theme.fontFamily
            }

            TextArea {
                id: qrPeerPayloadJson
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                implicitHeight: 86
                wrapMode: TextEdit.Wrap
                color: Theme.textPrimary
                selectedTextColor: Theme.textPrimary
                selectionColor: Theme.accent
                placeholderText: "Вставьте invitation или response payload JSON…"
                placeholderTextColor: Theme.textHint
                background: Rectangle { color: Theme.bgInput; border.color: Theme.border; radius: Theme.radiusSm }
            }

            ParaButton {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                text: "Считать payload из QR-изображения"
                secondary: true
                onClicked: qrPeerPayloadImageDialog.open()
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 8

                ParaButton {
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                    text: "Рассчитать SAS"
                    onClicked: {
                        let res = Backend.dialogKeyFingerprint(qrLocalStateJson.text, qrPeerPayloadJson.text.trim())
                        if (!res.ok) {
                            qrExchangeFeedback.text = res.error || "Ошибка SAS."
                            return
                        }
                        qrFingerprintText.text = res.fingerprint
                        qrExchangeFeedback.text = "Сравните SAS по независимому каналу."
                    }
                }

                ParaButton {
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                    text: "Подтвердить"
                    secondary: true
                    onClicked: {
                        let res = Backend.confirmDialogKeyExchange(
                            root.qrExchangePeer,
                            qrLocalStateJson.text,
                            qrPeerPayloadJson.text.trim(),
                            qrFingerprintText.text,
                            root.qrExchangeUpdateExisting
                        )
                        if (!res.ok) {
                            qrExchangeFeedback.text = res.error || "Ошибка подтверждения."
                            return
                        }
                        qrExchangeFeedback.text = "Ключ сохранён."
                        qrExchangePopup.close()
                        addDialogPopup.close()
                        updateKeyPopup.close()
                    }
                }
            }

            Text {
                id: qrFingerprintText
                Layout.fillWidth: true
                text: ""
                color: Theme.success
                font.pixelSize: 28
                font.family: Theme.fontFamily
                font.weight: Font.Bold
                horizontalAlignment: Text.AlignHCenter
                visible: text.length > 0
            }

            Text {
                id: qrExchangeFeedback
                Layout.fillWidth: true
                color: text.includes("ошиб") || text.includes("Ошибка") ? Theme.error : Theme.textSecondary
                font.pixelSize: Theme.fontSm
                font.family: Theme.fontFamily
                wrapMode: Text.WordWrap
                visible: text.length > 0
            }

            ParaButton {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                text: "Закрыть"
                secondary: true
                onClicked: qrExchangePopup.close()
            }
            }
        }
    }

    // ── Попап: регистрация пользователя (Admin) ───────────
    property string registerTargetDomain: ""

    Popup {
        id:          registerUserPopup
        anchors.centerIn: Overlay.overlay
        width:       Math.min(420, Overlay.overlay.width - 24)
        padding:     width < 360 ? 16 : 24
        modal:       true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        background: Rectangle {
            radius: Theme.radiusLg
            color:  Theme.bgSecondary
            border.color: Theme.border
        }

        onOpened: {
            newUserNameInput.text   = ""
            newUserPubKeyInput.text = ""
            regFeedback.text        = ""
        }

        contentItem: ColumnLayout {
            spacing: 16

            Text {
                Layout.alignment:   Qt.AlignHCenter
                text:               "Зарегистрировать пользователя"
                color:              Theme.textPrimary
                font.pixelSize:     Theme.fontLg
                font.family:        Theme.fontFamily
                font.weight:        Font.Medium
            }

            Text {
                Layout.fillWidth:   true
                text:               "Сервер: " + root.registerTargetDomain
                color:              Theme.textSecondary
                font.pixelSize:     Theme.fontSm
                font.family:        Theme.fontFamily
                elide:              Text.ElideRight
            }

            ParaInput {
                id:              newUserNameInput
                Layout.fillWidth: true
                label:           "Имя пользователя"
                placeholder:     "username"
            }

            ParaInput {
                id:              newUserPubKeyInput
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                label:           "Публичный ключ пользователя"
                placeholder:     "Вставьте ключ или считайте QR…"
            }

            ParaButton {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                text: "Считать QR с изображения"
                secondary: true
                onClicked: registrationQrImageDialog.open()
            }

            Text {
                id: regFeedback
                Layout.fillWidth:    true
                color:               text.includes("✓") ? Theme.success : Theme.error
                font.pixelSize:      Theme.fontSm
                font.family:         Theme.fontFamily
                horizontalAlignment: Text.AlignHCenter
                wrapMode:            Text.WordWrap
                visible:             text.length > 0
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing:          12

                ParaButton {
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                    text:             "Зарегистрировать"
                    onClicked: {
                        let user   = newUserNameInput.text.trim()
                        let pubkey = newUserPubKeyInput.text.trim()
                        if (user === "" || pubkey === "") {
                            regFeedback.text = "Заполните все поля."
                            return
                        }
                        const parsed = Backend.registrationPublicKeyFromQr(pubkey)
                        if (!parsed.ok) {
                            regFeedback.text = parsed.error || "Некорректный публичный ключ."
                            return
                        }
                        pubkey = parsed.pubkey
                        regFeedback.text = ""
                        Backend.registerUser(root.registerTargetDomain, user, pubkey)
                    }
                }

                ParaButton {
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                    text:             "Закрыть"
                    secondary:        true
                    onClicked:        registerUserPopup.close()
                }
            }
        }
    }
}
