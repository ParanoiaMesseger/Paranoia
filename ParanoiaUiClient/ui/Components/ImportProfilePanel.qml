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
        title: qsTr("Выбрать export-файл")
        mode: "open"
        nameFilters: [qsTr("Paranoia export (*.json)"), qsTr("JSON (*.json)"), qsTr("Все файлы (*)")]
        onAccepted: {
            panel.importFilePath = Backend.urlToLocalPath(selectedFile)
            importFeedback.text = ""
            deleteFileBanner.visible = false
            const res = Backend.importProfile(panel.importFilePath.trim())
            if (res.ok) {
                importFeedback.text =
                    qsTr("✓ Импорт выполнен. Диалогов: %1, ключей: %2, профилей: %3, admin-серверов: %4")
                        .arg(res.importedDialogues).arg(res.importedKeyEntries)
                        .arg(res.importedProfiles || 0).arg(res.importedAdminServers)
                if (res.conflicts > 0)
                    importFeedback.text += qsTr("\nКонфликтов keyring: %1 (не перезаписаны)").arg(res.conflicts)
                if (res.skippedEntries > 0)
                    importFeedback.text += qsTr("\nПропущено записей: %1").arg(res.skippedEntries)
                deleteFileBanner.visible = true
                panel.profileImported()
            } else {
                importFeedback.text = res.error || qsTr("Ошибка импорта.")
            }
        }
    }

    Text {
        Layout.fillWidth: true
        text: qsTr("Импортировать профиль из зашифрованного файла. Передайте ваш публичный ключ экспортирующему устройству — файл расшифровывается ключом этого устройства.")
        color: Theme.textSecondary
        font.pixelSize: Theme.fontSm
        font.family: Theme.fontFamily
        wrapMode: Text.WordWrap
    }

    CopyablePublicKeyBlock {
        Layout.fillWidth: true
        title: qsTr("Ваш публичный ключ:")
        keyText: Backend.devicePubkey
        backgroundColor: Theme.bgSecondary
        titleColor: Theme.textPrimary
        titleFontSize: Theme.fontSm
        keyElide: Text.ElideRight
    }

    Text {
        Layout.fillWidth: true
        text: qsTr("После успешного импорта рекомендуется удалить файл экспорта.")
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
                text: qsTr("Удалить файл экспорта?")
                color: Theme.textSecondary
                font.pixelSize: Theme.fontSm
                font.family: Theme.fontFamily
                wrapMode: Text.WordWrap
            }

            ParaButton {
                Layout.fillWidth: true
                implicitHeight: 36
                text: qsTr("Удалить")
                onClicked: {
                    const path = panel.importFilePath.trim()
                    const res = Backend.deleteExportFile(path)
                    if (res.ok)
                        importFeedback.text += qsTr("\nФайл экспорта удалён.")
                    else
                        importFeedback.text += qsTr("\nУдалите файл вручную: %1 (%2)").arg(path).arg(res.error || qsTr("ошибка"))
                    deleteFileBanner.visible = false
                }
            }

            ParaButton {
                Layout.fillWidth: true
                implicitHeight: 36
                text: qsTr("Нет")
                secondary: true
                onClicked: deleteFileBanner.visible = false
            }
        }
    }

    ParaButton {
        Layout.fillWidth: true
        text: qsTr("Импортировать")
        onClicked: importOpenDialog.open()
    }
}
