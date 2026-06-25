import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import ParanoiaUiClient

Rectangle {
    id: root
    color: Theme.bgPrimary

    signal back
    signal openQrExchange(string peer, bool updateExisting)

    // Корпоративный профиль показывает список доступных диалогов (ростер) и
    // качает ключ выбранного по требованию — без обмена QR/JSON. Личный профиль
    // обменивается ключом вручную.
    property bool corporate: false
    property bool loading: false
    property string statusText: ""
    property string toastText: ""
    property var rosterModel: []

    Component.onCompleted: {
        corporate = Backend.isCorporateProfile()
        if (corporate) {
            loading = true
            statusText = ""
            Backend.fetchCorporateRoster()
        }
    }

    Connections {
        target: Backend
        function onCorporateRosterFetched(ok, entries, message) {
            root.loading = false
            if (ok) {
                root.rosterModel = entries
                root.statusText = entries.length === 0 ? message : ""
            } else {
                root.rosterModel = []
                root.statusText = message
            }
        }
        function onCorporateDialogueAdded(ok, partnerServerId, message) {
            root.toastText = message
            // Перечитываем ростер — обновить пометки «добавлен».
            if (ok)
                Backend.fetchCorporateRoster()
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        ParaHeader {
            Layout.fillWidth: true
            title: root.corporate ? qsTr("Доступные диалоги") : qsTr("Добавить собеседника")
            onBackClicked: root.back()
        }

        // ── Корпоративный профиль: список доступных диалогов (ростер) ──────────
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.corporate
            spacing: 0

            Text {
                Layout.fillWidth: true
                Layout.margins: 16
                visible: root.toastText.length > 0
                text: root.toastText
                color: Theme.textSecondary
                font.pixelSize: Theme.fontSm
                font.family: Theme.fontFamily
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
            }

            // Индикатор загрузки / пустой ростер / ошибка.
            ColumnLayout {
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: 32
                spacing: 12
                visible: root.loading || (root.rosterModel.length === 0)

                BusyIndicator {
                    Layout.alignment: Qt.AlignHCenter
                    running: root.loading
                    visible: root.loading
                }
                Text {
                    Layout.alignment: Qt.AlignHCenter
                    visible: !root.loading
                    text: root.statusText.length > 0 ? root.statusText : qsTr("Нет доступных диалогов")
                    color: Theme.textSecondary
                    font.pixelSize: Theme.fontMd
                    font.family: Theme.fontFamily
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                }
                ParaButton {
                    Layout.alignment: Qt.AlignHCenter
                    visible: !root.loading
                    text: qsTr("Обновить")
                    onClicked: {
                        root.loading = true
                        root.statusText = ""
                        Backend.fetchCorporateRoster()
                    }
                }
            }

            ListView {
                id: rosterList
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: !root.loading && root.rosterModel.length > 0
                clip: true
                model: root.rosterModel
                spacing: 0

                delegate: Rectangle {
                    width: rosterList.width
                    height: 64
                    color: "transparent"

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 16
                        anchors.rightMargin: 16
                        spacing: 12

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            Text {
                                Layout.fillWidth: true
                                text: (modelData.fullName && modelData.fullName.length > 0)
                                      ? modelData.fullName : modelData.username
                                color: Theme.textPrimary
                                font.pixelSize: Theme.fontMd
                                font.bold: true
                                font.family: Theme.fontFamily
                                elide: Text.ElideRight
                            }
                            Text {
                                Layout.fillWidth: true
                                text: modelData.username
                                color: Theme.textSecondary
                                font.pixelSize: Theme.fontXs
                                font.family: Theme.fontFamily
                                elide: Text.ElideMiddle
                            }
                        }

                        ParaButton {
                            text: modelData.added ? qsTr("Добавлен") : qsTr("Добавить")
                            enabled: !modelData.added
                            onClicked: {
                                root.toastText = qsTr("Загрузка ключа…")
                                Backend.addCorporateDialogue(modelData.username,
                                                             modelData.fullName || "")
                            }
                        }
                    }

                    Rectangle {
                        anchors.bottom: parent.bottom
                        anchors.left: parent.left
                        anchors.right: parent.right
                        height: 1
                        color: Theme.border
                    }
                }
            }
        }

        // ── Личный профиль: ручной обмен ключом через QR/JSON ─────────────────
        Flickable {
            id: formFlick
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !root.corporate
            contentHeight: Math.max(formFlick.height, contentCol.implicitHeight + 40)
            clip: true

            ColumnLayout {
                id: contentCol
                // По горизонтали — по центру с ограничением ширины; по вертикали —
                // по центру вьюпорта (ручной ввод не должен липнуть к верху).
                // Контент выше экрана — от верха со скроллом.
                width: Math.min(parent.width - 40, 460)
                spacing: 16
                anchors.horizontalCenter: parent.horizontalCenter
                y: Math.max(20, (formFlick.height - implicitHeight) / 2)

                ParaInput {
                    id: newPeerInput
                    Layout.fillWidth: true
                    label: qsTr("Имя собеседника (локальная метка)")
                    placeholder: "username"
                }

                Text {
                    id: addDialogError
                    Layout.fillWidth: true
                    color: Theme.error
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    visible: text.length > 0
                }

                ParaButton {
                    Layout.fillWidth: true
                    text: qsTr("Обменяться ключом через QR/JSON")
                    onClicked: {
                        let peer = newPeerInput.text.trim()
                        if (peer === "") {
                            addDialogError.text = qsTr("Введите имя собеседника.")
                            return
                        }
                        addDialogError.text = ""
                        root.openQrExchange(peer, false)
                    }
                }

                Item {
                    Layout.preferredHeight: 16
                }
            }
        }
    }
}
