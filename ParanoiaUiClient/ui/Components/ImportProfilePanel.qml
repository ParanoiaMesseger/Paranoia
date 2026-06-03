import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import ParanoiaUiClient

// Единая логика импорта профиля из зашифрованного export-файла. Переиспользуется
// и на отдельной странице импорта (HelloPage), и во вкладке «Импорт» страницы
// Экспорт/Импорт (MainPage) — чтобы не дублировать FileDialog + importProfile +
// баннер удаления файла. Положить внутрь ColumnLayout/ScrollView родителя.
ColumnLayout {
    id: panel
    spacing: 12

    // Эмитится после успешного импорта (родитель решает, навигировать ли).
    signal profileImported()

    property string importFilePath: ""

    ParaFileDialog {
        id: importOpenDialog
        title: "Выбрать export-файл"
        mode: "open"
        nameFilters: ["Paranoia export (*.json)", "JSON (*.json)", "Все файлы (*)"]
        onAccepted: {
            panel.importFilePath = Backend.urlToLocalPath(selectedFile)
            importFeedback.text = ""
            deleteFileBanner.visible = false
            const res = Backend.importProfile(panel.importFilePath.trim())
            if (res.ok) {
                importFeedback.text =
                    "✓ Импорт выполнен. Диалогов: " + res.importedDialogues +
                    ", ключей: " + res.importedKeyEntries +
                    ", профилей: " + (res.importedProfiles || 0) +
                    ", admin-серверов: " + res.importedAdminServers
                if (res.conflicts > 0)
                    importFeedback.text += "\nКонфликтов keyring: " + res.conflicts + " (не перезаписаны)"
                if (res.skippedEntries > 0)
                    importFeedback.text += "\nПропущено записей: " + res.skippedEntries
                deleteFileBanner.visible = true
                panel.profileImported()
            } else {
                importFeedback.text = res.error || "Ошибка импорта."
            }
        }
    }

    Text {
        Layout.fillWidth: true
        text: "Импортировать профиль из зашифрованного файла. Передайте ваш публичный ключ экспортирующему устройству — файл расшифровывается ключом этого устройства."
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
                Layout.fillWidth: true
                implicitHeight: 36
                text: "Удалить"
                onClicked: {
                    const path = panel.importFilePath.trim()
                    const res = Backend.deleteExportFile(path)
                    if (res.ok)
                        importFeedback.text += "\nФайл экспорта удалён."
                    else
                        importFeedback.text += "\nУдалите файл вручную: " + path + " (" + (res.error || "ошибка") + ")"
                    deleteFileBanner.visible = false
                }
            }

            ParaButton {
                Layout.fillWidth: true
                implicitHeight: 36
                text: "Нет"
                secondary: true
                onClicked: deleteFileBanner.visible = false
            }
        }
    }

    ParaButton {
        Layout.fillWidth: true
        text: "Импортировать"
        onClicked: importOpenDialog.open()
    }
}
