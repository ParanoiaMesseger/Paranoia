import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Dialogs
import ParanoiaUiClient

Rectangle {
    id: root
    color: Theme.bgPrimary

    property var selectedExportPeers: ({})
    property int initialTabIndex: 0

    property string exportFilePath: ""
    property string importFilePath: ""

    signal back
    signal profileImported

    function localFilePath(fileUrl) {
        let value = decodeURIComponent(String(fileUrl));
        if (value.startsWith("file://"))
            value = value.substring(7);
        return value;
    }

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

    FileDialog {
        id: exportSaveDialog
        title: "Сохранить export-файл"
        fileMode: FileDialog.SaveFile
        defaultSuffix: "json"
        nameFilters: ["Paranoia export (*.json)", "JSON (*.json)"]
        onAccepted: {
            exportFilePath = root.localFilePath(selectedFile);
            exportFeedback.text = "";
            const profile = ["client", "admin", "full"][profileCombo.currentIndex];
            const peers = profile === "admin" ? [] : root.selectedPeerNames();
            if (profile !== "admin" && peers.length === 0) {
                exportFeedback.text = "Выберите хотя бы один диалог с keyring.";
                return;
            }
            const res = Backend.exportProfile(profile, peers, exportReceiverKey.text.trim(), exportFilePath.trim());
            if (res.ok) {
                exportFeedback.text = "✓ Экспорт сохранён: " + res.path;
                if (profile !== "admin")
                    exportFeedback.text += "\nДиалогов: " + res.dialogues + ", ключей: " + res.keyEntries;
            } else {
                exportFeedback.text = res.error || "Ошибка экспорта.";
            }
        }
    }

    FileDialog {
        id: importOpenDialog
        title: "Выбрать export-файл"
        fileMode: FileDialog.OpenFile
        nameFilters: ["Paranoia export (*.json)", "JSON (*.json)", "Все файлы (*)"]
        onAccepted: {
            importFilePath = root.localFilePath(selectedFile);
            importFeedback.text = "";
            deleteFileBanner.visible = false;
            const res = Backend.importProfile(importFilePath.trim());
            if (res.ok) {
                importFeedback.text = "✓ Импорт выполнен. Диалогов: " + res.importedDialogues + ", ключей: " + res.importedKeyEntries + ", профилей: " + (res.importedProfiles || 0) + ", admin-серверов: " + res.importedAdminServers;
                if (res.conflicts > 0)
                    importFeedback.text += "\nКонфликтов keyring: " + res.conflicts + " (не перезаписаны)";
                if (res.skippedEntries > 0)
                    importFeedback.text += "\nПропущено записей: " + res.skippedEntries;
                deleteFileBanner.visible = true;
                root.profileImported();
            } else {
                importFeedback.text = res.error || "Ошибка импорта.";
            }
        }
    }

    Component.onCompleted: {
        tabBar.currentIndex = root.initialTabIndex;
        exportFeedback.text = "";
        importFeedback.text = "";
        exportReceiverKey.text = "";
        exportFilePath = "";
        importFilePath = "";
        root.refreshExportDialogs();
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        ParaHeader {
            Layout.fillWidth: true
            title: "Экспорт / Импорт"
            onBackClicked: root.back()
        }

        TabBar {
            id: tabBar
            Layout.fillWidth: true
            Layout.topMargin: 12
            background: Rectangle {
                color: Theme.bgDark
            }

            Repeater {
                model: ["Экспорт", "Импорт"]
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

        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: tabBar.currentIndex

            // ── ЭКСПОРТ ───────────────────────────────────────
            ScrollView {
                id: exportScroll
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                contentWidth: availableWidth
                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

                ColumnLayout {
                    width: exportScroll.availableWidth
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
                            text: "Файл экспорта шифруется публичным ключом принимающего устройства."
                            color: Theme.textSecondary
                            font.pixelSize: Theme.fontSm
                            font.family: Theme.fontFamily
                            wrapMode: Text.WordWrap
                        }

                        Text {
                            text: "Профиль экспорта:"
                            color: Theme.textPrimary
                            font.pixelSize: Theme.fontSm
                            font.family: Theme.fontFamily
                        }

                        ComboBox {
                            id: profileCombo
                            Layout.fillWidth: true
                            implicitHeight: 44
                            model: ["client — клиентские данные", "admin — ключи администратора", "full — всё"]
                            background: Rectangle {
                                implicitHeight: 44
                                radius: Theme.radiusSm
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
                                y: profileCombo.height
                                width: profileCombo.width
                                padding: 0
                                background: Rectangle {
                                    color: Theme.bgSecondary
                                    border.color: Theme.border
                                    radius: Theme.radiusSm
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
                            text: "Диалоги для экспорта:"
                            color: Theme.textPrimary
                            font.pixelSize: Theme.fontSm
                            font.family: Theme.fontFamily
                            visible: profileCombo.currentIndex !== 1
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            height: Math.min(160, Math.max(160, exportDialogList.contentHeight + 2))
                            color: Theme.bgSecondary
                            radius: Theme.radiusSm
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
                                            text: modelData.hasKey ? "keyring" : "нет keyring"
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
                                text: "Нет диалогов с keyring"
                                color: Theme.textSecondary
                                font.pixelSize: Theme.fontSm
                                font.family: Theme.fontFamily
                                visible: exportDialogList.count === 0
                            }
                        }

                        ParaInput {
                            id: exportReceiverKey
                            Layout.fillWidth: true
                            placeholder: "Публичный ключ принимающего устройства"
                        }

                        Text {
                            Layout.fillWidth: true
                            text: "WARNING // Файл содержит ваши ключи и keyring. Храните его в безопасном месте."
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
                            text: "Экспортировать"
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

                ColumnLayout {
                    width: importScroll.availableWidth
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
                            text: "Импортировать профиль из зашифрованного файла. Передайте ваш публичный ключ экспортирующему устройство."
                            color: Theme.textSecondary
                            font.pixelSize: Theme.fontSm
                            font.family: Theme.fontFamily
                            wrapMode: Text.WordWrap
                        }

                        CopyablePublicKeyBlock {
                            Layout.fillWidth: true
                            title: "Ваш публичный ключ:"
                            keyText: Backend.devicePubkey
                            backgroundColor: Theme.bgSecondary
                            titleColor: Theme.textPrimary
                            titleFontSize: Theme.fontSm
                            keyElide: Text.ElideRight
                        }

                        Text {
                            Layout.fillWidth: true
                            text: "После успешного импорта рекомендуется удалить файл экспорта."
                            color: Theme.textSecondary
                            font.pixelSize: Theme.fontXs
                            font.family: Theme.fontFamily
                            wrapMode: Text.WordWrap
                        }

                        Text {
                            id: importFeedback
                            Layout.fillWidth: true
                            color: text.includes("✓") ? Theme.success : Theme.error
                            font.pixelSize: Theme.fontSm
                            font.family: Theme.fontFamily
                            wrapMode: Text.WordWrap
                            visible: text.length > 0
                        }

                        Rectangle {
                            id: deleteFileBanner
                            Layout.fillWidth: true
                            implicitHeight: deleteFileLayout.implicitHeight + 16
                            color: Theme.bgSecondary
                            radius: Theme.radiusSm
                            border.color: Theme.border
                            visible: false

                            ColumnLayout {
                                id: deleteFileLayout
                                anchors.fill: parent
                                anchors.leftMargin: 12
                                anchors.rightMargin: 12
                                spacing: 8

                                Text {
                                    Layout.fillWidth: true
                                    text: "Удалить файл экспорта?"
                                    color: Theme.textSecondary
                                    font.pixelSize: Theme.fontSm
                                    font.family: Theme.fontFamily
                                    wrapMode: Text.WordWrap
                                }

                                ParaButton {
                                    text: "Удалить"
                                    Layout.fillWidth: true
                                    implicitHeight: 36
                                    onClicked: {
                                        let path = importFilePath.trim();
                                        const res = Backend.deleteExportFile(path);
                                        if (res.ok)
                                            importFeedback.text += "\nФайл экспорта удалён.";
                                        else
                                            importFeedback.text += "\nУдалите файл вручную: " + path + " (" + (res.error || "ошибка") + ")";
                                        deleteFileBanner.visible = false;
                                    }
                                }

                                ParaButton {
                                    text: "Нет"
                                    secondary: true
                                    Layout.fillWidth: true
                                    implicitHeight: 36
                                    onClicked: deleteFileBanner.visible = false
                                }
                            }
                        }

                        ParaButton {
                            Layout.fillWidth: true
                            text: "Импортировать"
                            onClicked: importOpenDialog.open()
                        }

                        Item {
                            Layout.preferredHeight: 16
                        }
                    }
                }
            }
        }
    }
}
