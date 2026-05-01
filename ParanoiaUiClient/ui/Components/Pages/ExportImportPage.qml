import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import ParanoiaUiClient

// Диалог экспорта/импорта keyring (F2b/Y1c).
// Открывается как Popup из MainPage.
Popup {
    id: root
    anchors.centerIn: Overlay.overlay
    width:   Math.min(440, Overlay.overlay ? Overlay.overlay.width - 24 : 440)
    height:  Math.min(680, Overlay.overlay ? Overlay.overlay.height - 40 : 680)
    padding: 20
    modal:   true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    property var selectedExportPeers: ({})

    function refreshExportDialogs() {
        const dialogs = Backend.getDialogs()
        exportDialogList.model = dialogs
        const selected = {}
        for (let i = 0; i < dialogs.length; ++i) {
            if (dialogs[i].hasKey)
                selected[dialogs[i].peer] = true
        }
        selectedExportPeers = selected
    }

    function setAllExportDialogs(checked) {
        const selected = {}
        const dialogs = exportDialogList.model || []
        for (let i = 0; i < dialogs.length; ++i) {
            if (dialogs[i].hasKey)
                selected[dialogs[i].peer] = checked
        }
        selectedExportPeers = selected
    }

    function setExportDialogSelected(peer, checked) {
        const selected = {}
        const current = selectedExportPeers || {}
        for (const key in current)
            selected[key] = current[key]
        selected[peer] = checked
        selectedExportPeers = selected
    }

    function selectedPeerNames() {
        const result = []
        const dialogs = exportDialogList.model || []
        for (let i = 0; i < dialogs.length; ++i) {
            const peer = dialogs[i].peer
            if (dialogs[i].hasKey && selectedExportPeers[peer] === true)
                result.push(peer)
        }
        return result
    }

    background: Rectangle {
        radius: Theme.radiusLg
        color:  Theme.bgSecondary
        border.color: Theme.border
    }

    Connections {
        target: Backend
        function onDialogsChanged() {
            if (root.opened)
                root.refreshExportDialogs()
        }
    }

    onOpened: {
        tabBar.currentIndex = 0
        exportFeedback.text = ""
        importFeedback.text = ""
        exportReceiverKey.text = ""
        exportFilePath.text    = ""
        importFilePath.text    = ""
        root.refreshExportDialogs()
    }

    contentItem: ColumnLayout {
        spacing: 0

        // ── Заголовок ─────────────────────────────────────
        Text {
            Layout.alignment: Qt.AlignHCenter
            Layout.bottomMargin: 12
            text: "Экспорт / Импорт профиля"
            color: Theme.textPrimary
            font.pixelSize: Theme.fontLg
            font.family:    Theme.fontFamily
            font.weight:    Font.Medium
        }

        // ── Device public key ─────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.bottomMargin: 12
            height: 56
            color:  Theme.bgPrimary
            radius: Theme.radiusSm
            border.color: Theme.border

            ColumnLayout {
                anchors.fill:        parent
                anchors.leftMargin:  12
                anchors.rightMargin: 8
                anchors.topMargin:   6
                anchors.bottomMargin: 6
                spacing: 2

                Text {
                    text:  "Ваш публичный ключ (для получателя экспорта):"
                    color: Theme.textSecondary
                    font.pixelSize: Theme.fontXs
                    font.family:    Theme.fontFamily
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6

                    Text {
                        Layout.fillWidth: true
                        text:  Backend.devicePubkey || "—"
                        color: Theme.textPrimary
                        font.pixelSize: 10
                        font.family:    "monospace"
                        elide:          Text.ElideMiddle
                    }

                    Rectangle {
                        width: 28; height: 20
                        radius: Theme.radiusSm
                        color: copyPubArea.containsMouse ? Theme.bgButton : "transparent"
                        Text {
                            anchors.centerIn: parent
                            text:  "📋"
                            font.pixelSize: 13
                        }
                        MouseArea {
                            id: copyPubArea
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: {
                                devicePubkeyHelper.text = Backend.devicePubkey
                                devicePubkeyHelper.selectAll()
                                devicePubkeyHelper.copy()
                            }
                        }
                        TextEdit {
                            id: devicePubkeyHelper
                            visible: false
                        }
                    }
                }
            }
        }

        // ── Вкладки ───────────────────────────────────────
        TabBar {
            id: tabBar
            Layout.fillWidth: true
            Layout.bottomMargin: 12
            background: Rectangle { color: Theme.bgSecondary }

            Repeater {
                model: ["Экспорт", "Импорт"]
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
                        text:  parent.text
                        color: tabBar.currentIndex === index
                               ? Theme.accent : Theme.textSecondary
                        font.pixelSize: Theme.fontMd
                        font.family:    Theme.fontFamily
                        font.weight:    Font.Medium
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment:   Text.AlignVCenter
                    }
                }
            }
        }

        StackLayout {
            Layout.fillWidth:  true
            Layout.fillHeight: true
            currentIndex:      tabBar.currentIndex

            // ── ЭКСПОРТ ───────────────────────────────────
            ScrollView {
                clip: true
                contentWidth: availableWidth

                ColumnLayout {
                    width: parent.availableWidth
                    spacing: 12

                    Text {
                        Layout.fillWidth: true
                        text: "Создать зашифрованный файл переноса профиля на другое устройство. Файл шифруется на публичном ключе принимающего устройства (Y1c)."
                        color: Theme.textSecondary
                        font.pixelSize: Theme.fontSm
                        font.family:    Theme.fontFamily
                        wrapMode: Text.WordWrap
                    }

                    // Профиль
                    Text {
                        text:  "Профиль экспорта:"
                        color: Theme.textPrimary
                        font.pixelSize: Theme.fontSm
                        font.family:    Theme.fontFamily
                    }

                    ComboBox {
                        id: profileCombo
                        Layout.fillWidth: true
                        model: ["client — клиентские данные", "admin — ключи администратора", "full — всё"]
                        background: Rectangle {
                            radius: Theme.radiusSm
                            color:  Theme.bgInput
                            border.color: Theme.border
                        }
                        contentItem: Text {
                            leftPadding: 8
                            text:  profileCombo.displayText
                            color: Theme.textPrimary
                            font.pixelSize: Theme.fontSm
                            font.family:    Theme.fontFamily
                            verticalAlignment: Text.AlignVCenter
                        }
                        popup: Popup {
                            y: profileCombo.height
                            width: profileCombo.width
                            padding: 4
                            background: Rectangle {
                                color: Theme.bgSecondary
                                border.color: Theme.border
                                radius: Theme.radiusSm
                            }
                            contentItem: ListView {
                                implicitHeight: contentHeight
                                model: profileCombo.delegateModel
                                clip: true
                            }
                        }
                        delegate: ItemDelegate {
                            width: profileCombo.width
                            contentItem: Text {
                                text:  modelData
                                color: Theme.textPrimary
                                font.pixelSize: Theme.fontSm
                                font.family:    Theme.fontFamily
                                leftPadding: 8
                            }
                            background: Rectangle {
                                color: hovered ? Theme.bgButton : "transparent"
                            }
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        text: "Диалоги для экспорта (X2c):"
                        color: Theme.textPrimary
                        font.pixelSize: Theme.fontSm
                        font.family: Theme.fontFamily
                        visible: profileCombo.currentIndex !== 1
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        visible: profileCombo.currentIndex !== 1

                        ParaButton {
                            Layout.fillWidth: true
                            text: "Выбрать все"
                            secondary: true
                            onClicked: root.setAllExportDialogs(true)
                        }

                        ParaButton {
                            Layout.fillWidth: true
                            text: "Снять выбор"
                            secondary: true
                            onClicked: root.setAllExportDialogs(false)
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        height: Math.min(160, Math.max(48, exportDialogList.contentHeight + 2))
                        color: Theme.bgPrimary
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

                                        Text {
                                            anchors.centerIn: parent
                                            text: root.selectedExportPeers[modelData.peer] === true ? "✓" : ""
                                            color: "#FFFFFF"
                                            font.pixelSize: 12
                                            font.family: Theme.fontFamily
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
                                            root.setExportDialogSelected(modelData.peer, !(root.selectedExportPeers[modelData.peer] === true))
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

                    // Публичный ключ получателя
                    ParaInput {
                        id: exportReceiverKey
                        Layout.fillWidth: true
                        label:       "Публичный ключ принимающего устройства (base64)"
                        placeholder: "X25519 pubkey получателя…"
                    }

                    // Путь к файлу
                    ParaInput {
                        id: exportFilePath
                        Layout.fillWidth: true
                        label:       "Путь для сохранения файла"
                        placeholder: "/tmp/paranoia_export.json"
                    }

                    Text {
                        Layout.fillWidth: true
                        text: "⚠ Файл содержит ваши ключи и keyring. Храните его в безопасном месте."
                        color: Theme.textSecondary
                        font.pixelSize: Theme.fontXs
                        font.family:    Theme.fontFamily
                        wrapMode: Text.WordWrap
                    }

                    Text {
                        id: exportFeedback
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
                            text: "Экспортировать"
                            onClicked: {
                                exportFeedback.text = ""
                                const profile = ["client", "admin", "full"][profileCombo.currentIndex]
                                const peers = profile === "admin" ? [] : root.selectedPeerNames()
                                if (profile !== "admin" && peers.length === 0) {
                                    exportFeedback.text = "Выберите хотя бы один диалог с keyring."
                                    return
                                }
                                const res = Backend.exportProfile(
                                    profile,
                                    peers,
                                    exportReceiverKey.text.trim(),
                                    exportFilePath.text.trim()
                                )
                                if (res.ok) {
                                    exportFeedback.text = "✓ Экспорт сохранён: " + res.path
                                    if (profile !== "admin")
                                        exportFeedback.text += "\nДиалогов: " + res.dialogues + ", ключей: " + res.keyEntries
                                } else {
                                    exportFeedback.text = res.error || "Ошибка экспорта."
                                }
                            }
                        }

                        ParaButton {
                            Layout.fillWidth: true
                            text: "Закрыть"
                            secondary: true
                            onClicked: root.close()
                        }
                    }
                }
            }

            // ── ИМПОРТ ───────────────────────────────────
            ScrollView {
                clip: true
                contentWidth: availableWidth

                ColumnLayout {
                    width: parent.availableWidth
                    spacing: 12

                    Text {
                        Layout.fillWidth: true
                        text: "Импортировать профиль из зашифрованного файла экспорта. Файл будет расшифрован приватным ключом этого устройства."
                        color: Theme.textSecondary
                        font.pixelSize: Theme.fontSm
                        font.family:    Theme.fontFamily
                        wrapMode: Text.WordWrap
                    }

                    Text {
                        Layout.fillWidth: true
                        text: "Ваш публичный ключ (сообщите экспортирующему устройству):"
                        color: Theme.textPrimary
                        font.pixelSize: Theme.fontSm
                        font.family:    Theme.fontFamily
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        height: 36
                        color:  Theme.bgPrimary
                        radius: Theme.radiusSm
                        border.color: Theme.border

                        Text {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            verticalAlignment: Text.AlignVCenter
                            text:  Backend.devicePubkey || "—"
                            color: Theme.textPrimary
                            font.pixelSize: 10
                            font.family:    "monospace"
                            elide:          Text.ElideRight
                        }
                    }

                    // Путь к файлу
                    ParaInput {
                        id: importFilePath
                        Layout.fillWidth: true
                        label:       "Путь к файлу экспорта"
                        placeholder: "/tmp/paranoia_export.json"
                    }

                    Text {
                        Layout.fillWidth: true
                        text: "После успешного импорта рекомендуется удалить файл экспорта."
                        color: Theme.textSecondary
                        font.pixelSize: Theme.fontXs
                        font.family:    Theme.fontFamily
                        wrapMode: Text.WordWrap
                    }

                    Text {
                        id: importFeedback
                        Layout.fillWidth: true
                        color: text.includes("✓") ? Theme.success : Theme.error
                        font.pixelSize: Theme.fontSm
                        font.family:    Theme.fontFamily
                        wrapMode: Text.WordWrap
                        visible: text.length > 0
                    }

                    // Предложить удалить файл (Z3b)
                    Rectangle {
                        id: deleteFileBanner
                        Layout.fillWidth: true
                        height: 60
                        color:  Theme.bgPrimary
                        radius: Theme.radiusSm
                        border.color: Theme.border
                        visible: false

                        RowLayout {
                            anchors.fill:        parent
                            anchors.leftMargin:  12
                            anchors.rightMargin: 12
                            spacing: 8

                            Text {
                                Layout.fillWidth: true
                                text: "Удалить файл экспорта?"
                                color: Theme.textSecondary
                                font.pixelSize: Theme.fontSm
                                font.family:    Theme.fontFamily
                                wrapMode: Text.WordWrap
                            }

                            ParaButton {
                                text:      "Удалить"
                                implicitWidth:  80
                                implicitHeight: 32
                                onClicked: {
                                    let path = importFilePath.text.trim()
                                    const res = Backend.deleteExportFile(path)
                                    if (res.ok)
                                        importFeedback.text += "\nФайл экспорта удалён."
                                    else
                                        importFeedback.text += "\nУдалите файл вручную: " + path + " (" + (res.error || "ошибка") + ")"
                                    deleteFileBanner.visible = false
                                }
                            }

                            ParaButton {
                                text:      "Нет"
                                secondary: true
                                implicitWidth:  60
                                implicitHeight: 32
                                onClicked: deleteFileBanner.visible = false
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 12

                        ParaButton {
                            Layout.fillWidth: true
                            text: "Импортировать"
                            onClicked: {
                                importFeedback.text = ""
                                deleteFileBanner.visible = false
                                const res = Backend.importProfile(importFilePath.text.trim())
                                if (res.ok) {
                                    importFeedback.text =
                                        "✓ Импорт выполнен. Диалогов: " + res.importedDialogues +
                                        ", ключей: " + res.importedKeyEntries +
                                        ", серверов: " + res.importedAdminServers
                                    if (res.conflicts > 0)
                                        importFeedback.text += "\nКонфликтов keyring: " + res.conflicts + " (не перезаписаны)"
                                    if (res.skippedEntries > 0)
                                        importFeedback.text += "\nПропущено записей: " + res.skippedEntries
                                    deleteFileBanner.visible = true
                                } else {
                                    importFeedback.text = res.error || "Ошибка импорта."
                                }
                            }
                        }

                        ParaButton {
                            Layout.fillWidth: true
                            text: "Закрыть"
                            secondary: true
                            onClicked: root.close()
                        }
                    }
                }
            }
        }
    }
}
