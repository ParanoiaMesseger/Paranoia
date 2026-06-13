import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import ParanoiaUiClient

Rectangle {
    id: root
    color: Theme.bgPrimary

    property var selectedExportPeers: ({})
    property int initialTabIndex: 0

    property string exportFilePath: ""

    signal back
    signal profileImported

    function refreshExportDialogs() {
        const dialogs = Backend.getDialogs();
        exportDialogList.model = dialogs;
        const selected = {};
        for (let i = 0; i < dialogs.length; ++i) {
            if (dialogs[i].hasKey)
                selected[dialogs[i].peer] = true;
        }
        selectedExportPeers = selected;
    }

    function setAllExportDialogs(checked) {
        const selected = {};
        const dialogs = exportDialogList.model || [];
        for (let i = 0; i < dialogs.length; ++i) {
            if (dialogs[i].hasKey)
                selected[dialogs[i].peer] = checked;
        }
        selectedExportPeers = selected;
    }

    function setExportDialogSelected(peer, checked) {
        const selected = {};
        const current = selectedExportPeers || {};
        for (const key in current)
            selected[key] = current[key];
        selected[peer] = checked;
        selectedExportPeers = selected;
    }

    function selectedPeerNames() {
        const result = [];
        const dialogs = exportDialogList.model || [];
        for (let i = 0; i < dialogs.length; ++i) {
            const peer = dialogs[i].peer;
            if (dialogs[i].hasKey && selectedExportPeers[peer] === true)
                result.push(peer);
        }
        return result;
    }

    Connections {
        target: Backend
        function onDialogsChanged() {
            root.refreshExportDialogs();
        }
    }

    ParaFileDialog {
        id: exportSaveDialog
        title: qsTr("Сохранить export-файл")
        mode: "save"
        defaultSuffix: "json"
        nameFilters: [qsTr("Paranoia export (*.json)"), qsTr("JSON (*.json)")]
        onAccepted: {
            exportFilePath = Backend.urlToLocalPath(selectedFile);
            exportFeedback.text = "";
            const profile = ["client", "admin", "full"][profileCombo.currentIndex];
            const peers = profile === "admin" ? [] : root.selectedPeerNames();
            if (profile !== "admin" && peers.length === 0) {
                exportFeedback.text = qsTr("Выберите хотя бы один диалог с keyring.");
                return;
            }
            const res = Backend.exportProfile(profile, peers, exportReceiverKey.text.trim(), exportFilePath.trim());
            if (res.ok) {
                exportFeedback.text = qsTr("✓ Экспорт сохранён: %1").arg(res.path);
                if (profile !== "admin")
                    exportFeedback.text += qsTr("\nДиалогов: %1, ключей: %2").arg(res.dialogues).arg(res.keyEntries);
            } else {
                exportFeedback.text = res.error || qsTr("Ошибка экспорта.");
            }
        }
    }

    Component.onCompleted: {
        tabBar.currentIndex = root.initialTabIndex;
        exportFeedback.text = "";
        exportReceiverKey.text = "";
        exportFilePath = "";
        root.refreshExportDialogs();
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        ParaHeader {
            Layout.fillWidth: true
            title: qsTr("Экспорт / Импорт")
            onBackClicked: root.back()
        }

        TabBar {
            id: tabBar
            Layout.fillWidth: true
            Layout.topMargin: 12
            // Клик по вкладке ↔ свайп: синхронизируем с SwipeView без binding-loop
            // (гард не даёт пинг-понгу зациклиться).
            onCurrentIndexChanged: if (swipeView.currentIndex !== currentIndex) swipeView.currentIndex = currentIndex
            background: Rectangle {
                color: Theme.bgDark
            }

            Repeater {
                model: [qsTr("Экспорт"), qsTr("Импорт")]
                TabButton {
                    required property string modelData
                    required property int index
                    text: modelData
                    background: Rectangle {
                        color: tabBar.currentIndex === index ? Theme.bgPrimary : Theme.bgDark
                        Rectangle {
                            anchors.bottom: parent.bottom
                            width: parent.width
                            height: 2
                            color: tabBar.currentIndex === index ? Theme.accent : "transparent"
                        }
                    }
                    contentItem: Text {
                        text: parent.text
                        color: tabBar.currentIndex === index ? Theme.accent : Theme.textSecondary
                        font.pixelSize: Theme.fontMd
                        font.family: Theme.fontFamily
                        font.weight: Font.Medium
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }

        SwipeView {
            id: swipeView
            Layout.fillWidth: true
            Layout.fillHeight: true
            // Свайп влево/вправо переключает вкладки; обратная синхронизация в
            // TabBar (без declarative-биндинга, чтобы свайп «прилипал»).
            onCurrentIndexChanged: if (tabBar.currentIndex !== currentIndex) tabBar.currentIndex = currentIndex

            // ── ЭКСПОРТ ───────────────────────────────────────
            ScrollView {
                id: exportScroll
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                contentWidth: availableWidth
                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                // Вертикальное центрирование короткого контента (не липнет к верху).
                topPadding: Math.max(0, (height - exportCol.implicitHeight) / 2)

                ColumnLayout {
                    id: exportCol
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Math.min(exportScroll.availableWidth - 32, 560)
                    spacing: 12

                    Item {
                        Layout.preferredHeight: 8
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.leftMargin: 16
                        Layout.rightMargin: 16
                        spacing: 12

                        Text {
                            Layout.fillWidth: true
                            text: qsTr("Файл шифруется ключом принимающего устройства.")
                            color: Theme.textSecondary
                            font.pixelSize: Theme.fontSm
                            font.family: Theme.fontFamily
                            wrapMode: Text.WordWrap
                        }

                        Text {
                            text: qsTr("Профиль экспорта:")
                            color: Theme.textPrimary
                            font.pixelSize: Theme.fontSm
                            font.family: Theme.fontFamily
                        }

                        ComboBox {
                            id: profileCombo
                            Layout.fillWidth: true
                            implicitHeight: 44
                            model: [qsTr("client — клиентские данные"), qsTr("admin — ключи администратора"), qsTr("full — всё")]
                            background: Rectangle {
                                implicitHeight: 44
                                radius: 20          // как у поля ввода (скруглённая пилюля)
                                color: Theme.bgInput
                                border.color: Theme.border
                            }
                            contentItem: Text {
                                leftPadding: 8
                                rightPadding: 28
                                text: profileCombo.displayText
                                color: Theme.textPrimary
                                font.pixelSize: Theme.fontSm
                                font.family: Theme.fontFamily
                                verticalAlignment: Text.AlignVCenter
                                elide: Text.ElideRight
                            }
                            popup: Popup {
                                y: profileCombo.height + 4
                                width: profileCombo.width
                                padding: 6          // отступ, чтобы скруглённые углы были видны вокруг списка
                                background: Rectangle {
                                    color: Theme.bgSecondary
                                    border.color: Theme.border
                                    radius: 16
                                }
                                contentItem: ListView {
                                    id: profilePopupList
                                    implicitHeight: Math.min(contentHeight, 160)
                                    model: profileCombo.delegateModel
                                    currentIndex: profileCombo.highlightedIndex
                                    clip: true
                                    ScrollBar.vertical: ScrollBar {
                                        policy: profilePopupList.contentHeight > profilePopupList.height ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
                                    }
                                }
                            }
                            delegate: ItemDelegate {
                                width: ListView.view ? ListView.view.width : profileCombo.width
                                height: 40
                                contentItem: Text {
                                    text: modelData
                                    color: Theme.textPrimary
                                    font.pixelSize: Theme.fontSm
                                    font.family: Theme.fontFamily
                                    leftPadding: 8
                                    rightPadding: 8
                                    verticalAlignment: Text.AlignVCenter
                                    elide: Text.ElideRight
                                }
                                background: Rectangle {
                                    color: hovered ? Theme.bgButton : "transparent"
                                }
                            }
                        }

                        Text {
                            Layout.fillWidth: true
                            text: qsTr("Диалоги для экспорта:")
                            color: Theme.textPrimary
                            font.pixelSize: Theme.fontSm
                            font.family: Theme.fontFamily
                            visible: profileCombo.currentIndex !== 1
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            height: Math.min(160, Math.max(160, exportDialogList.contentHeight + 2))
                            color: Theme.bgSecondary
                            radius: Theme.radiusLg
                            border.color: Theme.border
                            visible: profileCombo.currentIndex !== 1
                            clip: true

                            ListView {
                                id: exportDialogList
                                anchors.fill: parent
                                model: []
                                clip: true
                                ScrollBar.vertical: ScrollBar {}

                                delegate: Rectangle {
                                    width: ListView.view.width
                                    height: 38
                                    color: dialogExportArea.containsMouse ? Theme.bgSecondary : "transparent"
                                    opacity: modelData.hasKey ? 1.0 : 0.55

                                    RowLayout {
                                        anchors.fill: parent
                                        anchors.leftMargin: 10
                                        anchors.rightMargin: 10
                                        spacing: 8

                                        Rectangle {
                                            width: 18
                                            height: 18
                                            radius: 3
                                            color: root.selectedExportPeers[modelData.peer] === true ? Theme.accent : "transparent"
                                            border.color: modelData.hasKey ? Theme.accent : Theme.border

                                            CheckMark {
                                                anchors.centerIn: parent
                                                width: 14
                                                height: 14
                                                visible: root.selectedExportPeers[modelData.peer] === true
                                                color: Theme.textPrimary
                                                strokeWidth: 2
                                            }
                                        }

                                        Text {
                                            Layout.fillWidth: true
                                            text: modelData.peer
                                            color: Theme.textPrimary
                                            font.pixelSize: Theme.fontSm
                                            font.family: Theme.fontFamily
                                            elide: Text.ElideRight
                                        }

                                        Text {
                                            text: modelData.hasKey ? "keyring" : qsTr("нет keyring")
                                            color: modelData.hasKey ? Theme.textSecondary : Theme.error
                                            font.pixelSize: Theme.fontXs
                                            font.family: Theme.fontFamily
                                        }
                                    }

                                    MouseArea {
                                        id: dialogExportArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        onClicked: {
                                            if (modelData.hasKey)
                                                root.setExportDialogSelected(modelData.peer, !(root.selectedExportPeers[modelData.peer] === true));
                                        }
                                    }
                                }
                            }

                            Text {
                                anchors.centerIn: parent
                                text: qsTr("Нет диалогов с keyring")
                                color: Theme.textSecondary
                                font.pixelSize: Theme.fontSm
                                font.family: Theme.fontFamily
                                visible: exportDialogList.count === 0
                            }
                        }

                        ParaInput {
                            id: exportReceiverKey
                            Layout.fillWidth: true
                            placeholder: qsTr("Публичный ключ принимающего устройства")
                        }

                        Text {
                            Layout.fillWidth: true
                            text: qsTr("Файл содержит ваши ключи. Храните его в безопасном месте.")
                            color: Theme.textSecondary
                            font.pixelSize: Theme.fontXs
                            font.family: Theme.fontFamily
                            wrapMode: Text.WordWrap
                        }

                        Text {
                            id: exportFeedback
                            Layout.fillWidth: true
                            color: text.includes("✓") ? Theme.success : Theme.error
                            font.pixelSize: Theme.fontSm
                            font.family: Theme.fontFamily
                            wrapMode: Text.WordWrap
                            visible: text.length > 0
                        }

                        ParaButton {
                            Layout.fillWidth: true
                            text: qsTr("Экспортировать")
                            onClicked: {
                                exportSaveDialog.currentFile = Qt.resolvedUrl("paranoia-export.json");
                                exportSaveDialog.open();
                            }
                        }

                        Item {
                            Layout.preferredHeight: 16
                        }
                    }
                }
            }

            // ── ИМПОРТ ────────────────────────────────────────
            ScrollView {
                id: importScroll
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                contentWidth: availableWidth
                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                // Вертикальное центрирование короткого контента (не липнет к верху).
                topPadding: Math.max(0, (height - importCol.implicitHeight) / 2)

                ColumnLayout {
                    id: importCol
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Math.min(importScroll.availableWidth - 32, 560)
                    spacing: 12

                    Item { Layout.preferredHeight: 8 }

                    // Единая логика импорта (та же, что на отдельной странице импорта).
                    ImportProfilePanel {
                        Layout.fillWidth: true
                        Layout.leftMargin: 16
                        Layout.rightMargin: 16
                        onProfileImported: root.profileImported()
                    }

                    Item { Layout.preferredHeight: 16 }
                }
            }
        }
    }
}
