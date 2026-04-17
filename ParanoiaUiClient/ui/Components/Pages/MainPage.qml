import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import ParanoiaUiClient

Rectangle {
    id: root
    color: Theme.bgPrimary

    property bool hasAdminAccess: Backend.hasAdminAccess
    property bool hasUserAccess:  Backend.loggedIn

    signal openChat(string peer)
    signal addServer()
    signal installNewServer()

    Connections {
        target: Backend
        function onDialogsChanged()       { dialogsView.model = Backend.getDialogs() }
        function onUserRegistered()       { regFeedback.text = "Пользователь зарегистрирован ✓"; registerUserPopup.close() }
        function onRegisterUserError(msg) { regFeedback.text = msg }
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
        }

        // ── TabBar (always 3 fixed tabs) ──────────────────
        TabBar {
            id: tabBar
            Layout.fillWidth: true
            background: Rectangle { color: Theme.bgSecondary }

            Repeater {
                model: ["Чаты", "Админ", "+"]

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
            currentIndex:      tabBar.currentIndex

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
                        text:           "Войдите в аккаунт"
                        color:          Theme.textSecondary
                        font.pixelSize: Theme.fontMd
                        font.family:    Theme.fontFamily
                    }
                    ParaButton {
                        text:      "Подключиться"
                        onClicked: root.addServer()
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
                            width:  ListView.view.width
                            height: 60
                            color:  dlgArea.containsMouse ? Theme.bgSecondary : "transparent"

                            Row {
                                anchors.fill:        parent
                                anchors.leftMargin:  16
                                anchors.rightMargin: 16
                                spacing:             12

                                Rectangle {
                                    width:  38; height: 38
                                    radius: 19
                                    color:  Theme.bgButton
                                    anchors.verticalCenter: parent.verticalCenter

                                    Text {
                                        anchors.centerIn: parent
                                        text:  modelData.peer.charAt(0).toUpperCase()
                                        color: "#FFFFFF"
                                        font.pixelSize: Theme.fontMd
                                        font.weight:    Font.Bold
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
                                        text:           modelData.lastMsg || "Нет сообщений"
                                        color:          Theme.textSecondary
                                        font.pixelSize: Theme.fontSm
                                        font.family:    Theme.fontFamily
                                        elide:          Text.ElideRight
                                        width:          dialogsView.width - 80
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
                                onClicked:    root.openChat(modelData.peer)
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
                        text:           "Нет прав администратора"
                        color:          Theme.textSecondary
                        font.pixelSize: Theme.fontMd
                        font.family:    Theme.fontFamily
                    }
                    ParaButton {
                        text:      "Войти как Админ"
                        onClicked: root.addServer()
                    }
                }

                ListView {
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
                        text:             "Добавить сервер"
                        color:            Theme.textPrimary
                        font.pixelSize:   Theme.fontLg
                        font.family:      Theme.fontFamily
                        font.weight:      Font.Medium
                    }

                    Item { Layout.preferredHeight: 8 }

                    ParaButton {
                        Layout.fillWidth: true
                        text:             "Подключиться к серверу"
                        onClicked:        root.addServer()
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

    // ── Попап: регистрация пользователя (Admin) ───────────
    property string registerTargetDomain: ""

    Popup {
        id:          registerUserPopup
        anchors.centerIn: Overlay.overlay
        width:       340
        padding:     24
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
                label:           "Публичный ключ пользователя"
                placeholder:     "Вставьте ключ…"
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

            RowLayout {
                Layout.fillWidth: true
                spacing:          12

                ParaButton {
                    Layout.fillWidth: true
                    text:             "Зарегистрировать"
                    onClicked: {
                        let user   = newUserNameInput.text.trim()
                        let pubkey = newUserPubKeyInput.text.trim()
                        if (user === "" || pubkey === "") {
                            regFeedback.text = "Заполните все поля."
                            return
                        }
                        regFeedback.text = ""
                        Backend.registerUser(root.registerTargetDomain, user, pubkey)
                    }
                }

                ParaButton {
                    Layout.fillWidth: true
                    text:             "Закрыть"
                    secondary:        true
                    onClicked:        registerUserPopup.close()
                }
            }
        }
    }
}
