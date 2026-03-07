import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import ParanoiaUiClient

Rectangle {
    id: root
    color: Theme.bgPrimary

    property bool hasAdminAccess: false
    property bool hasUserAccess:  true

    // ── Модель серверов (заглушка) ────────────────────────
    ListModel {
        id: serversModel
        ListElement { serverName: "paranoia.example.com"; isAdmin: true }
        ListElement { serverName: "chat.myserver.net";   isAdmin: false }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing:      0

        // ── Заголовок главного экрана ─────────────────────
        Rectangle {
            Layout.fillWidth: true
            height:           56
            color:            Theme.bgSecondary

            Rectangle {
                anchors.bottom: parent.bottom
                width:  parent.width; height: 1
                color:  Theme.separator
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

        // ── TabBar ────────────────────────────────────────
        TabBar {
            id:               tabBar
            Layout.fillWidth: true
            background: Rectangle { color: Theme.bgSecondary }
            currentIndex:     hasUserAccess ? 0 : 1

            Repeater {
                model: {
                    let tabs = []
                    if (root.hasUserAccess)  tabs.push("User")
                    if (root.hasAdminAccess) tabs.push("Admin")
                    tabs.push("+")
                    return tabs
                }

                TabButton {
                    text: modelData
                    background: Rectangle {
                        color: TabBar.tabBar.currentIndex === index
                               ? Theme.bgPrimary : Theme.bgSecondary
                        Rectangle {
                            anchors.bottom: parent.bottom
                            width:  parent.width; height: 2
                            color:  TabBar.tabBar.currentIndex === index
                                    ? Theme.accent : "transparent"
                        }
                    }
                    contentItem: Text {
                        text:               parent.text
                        color:              TabBar.tabBar.currentIndex === index
                                            ? Theme.accent : Theme.textSecondary
                        font.pixelSize:     Theme.fontMd
                        font.family:        Theme.fontFamily
                        font.weight:        Font.Medium
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment:  Text.AlignVCenter
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

                ColumnLayout {
                    anchors.fill:    parent
                    anchors.margins: 0
                    spacing:         0

                    // Дерево серверов
                    ListView {
                        id:               serverListView
                        Layout.fillWidth: true
                        Layout.fillHeight:true
                        model:            serversModel
                        clip:             true

                        delegate: Column {
                            width: parent.width
                            spacing: 0

                            // ── Заголовок сервера ──────────
                            Rectangle {
                                width:  parent.width
                                height: 48
                                color:  serverHeaderArea.containsMouse
                                        ? Theme.bgSecondary : "transparent"

                                Row {
                                    anchors.fill:        parent
                                    anchors.leftMargin:  16
                                    anchors.rightMargin: 16
                                    spacing:             10

                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text:  expanded ? "▾" : "▸"
                                        color: Theme.textSecondary
                                        font.pixelSize: Theme.fontSm
                                    }

                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text:  "🖥  " + serverName
                                        color: Theme.textPrimary
                                        font.pixelSize: Theme.fontMd
                                        font.family:    Theme.fontFamily
                                        font.weight:    Font.Medium
                                    }

                                    Item { width: 1; height: 1; Layout.fillWidth: true }
                                }

                                MouseArea {
                                    id:           serverHeaderArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked:    expanded = !expanded
                                }
                            }

                            // ── Диалоги сервера ───────────
                            property bool expanded: true
                            property var dialogs: ListModel {
                                ListElement { dialogName: "Alice"; lastMsg: "HI" }
                            }

                            Column {
                                visible: expanded
                                width:   parent.width

                                Repeater {
                                    model: parent.parent.dialogs

                                    Rectangle {
                                        width:  serverListView.width
                                        height: 56
                                        color:  dialogArea.containsMouse
                                                ? Theme.bgSecondary : "transparent"

                                        Row {
                                            anchors.fill:        parent
                                            anchors.leftMargin:  42
                                            anchors.rightMargin: 16
                                            spacing:             12

                                            // Аватар
                                            Rectangle {
                                                width:  36; height: 36
                                                radius: 18
                                                color:  Theme.bgButton
                                                anchors.verticalCenter: parent.verticalCenter

                                                Text {
                                                    anchors.centerIn: parent
                                                    text:  dialogName.charAt(0).toUpperCase()
                                                    color: "#FFFFFF"
                                                    font.pixelSize: Theme.fontMd
                                                    font.weight: Font.Bold
                                                }
                                            }

                                            Column {
                                                anchors.verticalCenter: parent.verticalCenter
                                                spacing: 2
                                                Text {
                                                    text:           dialogName
                                                    color:          Theme.textPrimary
                                                    font.pixelSize: Theme.fontMd
                                                    font.family:    Theme.fontFamily
                                                    font.weight:    Font.Medium
                                                }
                                                Text {
                                                    text:           lastMsg
                                                    color:          Theme.textSecondary
                                                    font.pixelSize: Theme.fontSm
                                                    font.family:    Theme.fontFamily
                                                }
                                            }
                                        }

                                        MouseArea {
                                            id:           dialogArea
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            onClicked: { /* открыть чат */ }
                                        }
                                    }
                                }

                                // Кнопка «+ Добавить диалог»
                                Rectangle {
                                    width:  serverListView.width
                                    height: 44
                                    color:  addDialogArea.containsMouse
                                            ? Theme.bgSecondary : "transparent"

                                    Row {
                                        anchors.fill:       parent
                                        anchors.leftMargin: 42
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
                                        id:           addDialogArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        onClicked:    addDialogPopup.open()
                                    }
                                }
                            }

                            // Разделитель
                            Rectangle {
                                width:  parent.width; height: 1
                                color:  Theme.separator
                            }
                        }
                    }
                }
            }

            // ── ADMIN tab ─────────────────────────────────
            Rectangle {
                color: Theme.bgPrimary
                visible: root.hasAdminAccess

                ListView {
                    anchors.fill: parent
                    model:        serversModel
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
                                    text:           serverName
                                    color:          Theme.textPrimary
                                    font.pixelSize: Theme.fontMd
                                    font.family:    Theme.fontFamily
                                    font.weight:    Font.Medium
                                }
                                Text {
                                    text:           isAdmin ? "Администратор" : "Клиент"
                                    color:          isAdmin ? Theme.accent : Theme.textSecondary
                                    font.pixelSize: Theme.fontSm
                                    font.family:    Theme.fontFamily
                                }
                            }

                            ParaButton {
                                text:            "Регистрация юзера"
                                implicitWidth:   160
                                implicitHeight:  36
                                visible:         isAdmin
                                onClicked:       registerUserPopup.open()
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

                    ParaButton {
                        Layout.fillWidth: true
                        text:             "Подключиться к серверу"
                        onClicked: { /* stackView.push connectChoice */ }
                    }

                    ParaButton {
                        Layout.fillWidth: true
                        text:             "Установить свой сервер"
                        secondary:        true
                        onClicked: { /* stackView.push installServer */ }
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

            ParaButton {
                Layout.fillWidth: true
                text:             "Сканировать QR-код собеседника"
                onClicked: { /* запустить QR-сканер */ }
            }

            ParaButton {
                Layout.fillWidth: true
                text:             "Показать мой QR-код"
                secondary:        true
                onClicked: { /* показать свой QR */ }
            }

            ParaButton {
                Layout.fillWidth: true
                text:             "Отмена"
                destructive:      true
                onClicked:        addDialogPopup.close()
            }
        }
    }

    // ── Попап: регистрация пользователя (Admin) ───────────
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

            ParaInput {
                id:              newUserNameInput
                Layout.fillWidth: true
                label:           "Имя пользователя"
                placeholder:     "username"
            }

            ParaInput {
                id:              newUserPubKeyInput
                Layout.fillWidth: true
                label:           "Публичный ключ пользователя (USER_PUB)"
                placeholder:     "Вставьте ключ или отсканируйте QR…"
            }

            ParaButton {
                Layout.fillWidth: true
                text:             "Отсканировать QR пользователя"
                secondary:        true
                onClicked: { /* запустить QR-сканер → newUserPubKeyInput */ }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing:          12

                ParaButton {
                    Layout.fillWidth: true
                    text:             "Зарегистрировать"
                    onClicked: {
                        // backend.registerUser(server, newUserNameInput.text,
                        //                      newUserPubKeyInput.text)
                        registerUserPopup.close()
                    }
                }

                ParaButton {
                    Layout.fillWidth: true
                    text:             "Отмена"
                    secondary:        true
                    onClicked:        registerUserPopup.close()
                }
            }
        }
    }
}
