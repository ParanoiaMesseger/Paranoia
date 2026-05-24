import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Dialogs
import ParanoiaUiClient

Rectangle {
    id: root
    color: Theme.bgPrimary
    property string importFilePath: ""
    signal back()
    signal profileImported()

    FileDialog {
        id: importOpenDialog
        title: "Выбрать export-файл"
        fileMode: FileDialog.OpenFile
        nameFilters: ["Paranoia export (*.json)", "JSON (*.json)", "Все файлы (*)"]
        onAccepted: importFilePath = Backend.urlToLocalPath(selectedFile)
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        ParaHeader {
            Layout.fillWidth: true
            title: "Импорт"
            onBackClicked: root.back()
        }

        ScrollView {
            id: importScroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: availableWidth
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

            ColumnLayout {
                width: importScroll.availableWidth
                spacing: 16

                Item { Layout.preferredHeight: 8 }

                Text {
                    Layout.fillWidth: true
                    Layout.leftMargin: 24
                    Layout.rightMargin: 24
                    text: "Импортировать профиль из зашифрованного файла экспорта. Файл будет расшифрован приватным ключом этого устройства."
                    color: Theme.textSecondary
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    wrapMode: Text.WordWrap
                }

                CopyablePublicKeyBlock {
                    Layout.fillWidth: true
                    Layout.leftMargin: 24
                    Layout.rightMargin: 24
                    title: "Ваш публичный ключ (сообщите экспортирующему устройству):"
                    keyText: Backend.devicePubkey
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 24
                    Layout.rightMargin: 24
                    spacing: 8

                    ParaButton {
                        Layout.fillWidth: true
                        Layout.minimumWidth: 0
                        text: "Выбрать файл"
                        secondary: true
                        onClicked: importOpenDialog.open()
                    }
                }

                Text {
                    Layout.fillWidth: true
                    Layout.leftMargin: 24
                    Layout.rightMargin: 24
                    text: "После успешного импорта рекомендуется удалить файл экспорта."
                    color: Theme.textSecondary
                    font.pixelSize: Theme.fontXs
                    font.family: Theme.fontFamily
                    wrapMode: Text.WordWrap
                }

                Text {
                    id: importFeedback
                    Layout.fillWidth: true
                    Layout.leftMargin: 24
                    Layout.rightMargin: 24
                    color: text.includes("✓") ? Theme.success : Theme.error
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    wrapMode: Text.WordWrap
                    visible: text.length > 0
                }

                Rectangle {
                    id: deleteFileBanner
                    Layout.fillWidth: true
                    Layout.leftMargin: 24
                    Layout.rightMargin: 24
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
                        anchors.topMargin: 8
                        anchors.bottomMargin: 8
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
                            Layout.minimumWidth: 0
                            implicitHeight: 36
                            text: "Удалить"
                            onClicked: {
                                const path = importFilePath.trim()
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
                            Layout.minimumWidth: 0
                            implicitHeight: 36
                            text: "Нет"
                            secondary: true
                            onClicked: deleteFileBanner.visible = false
                        }
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 24
                    Layout.rightMargin: 24
                    spacing: 12

                    ParaButton {
                        Layout.fillWidth: true
                        Layout.minimumWidth: 0
                        text: "Импортировать"
                        onClicked: {
                            importFeedback.text = ""
                            deleteFileBanner.visible = false

                            const res = Backend.importProfile(importFilePath.trim())
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
                                root.profileImported()
                            } else {
                                importFeedback.text = res.error || "Ошибка импорта."
                            }
                        }
                    }

                }

                Item { Layout.preferredHeight: 24 }
            }
        }
    }
}
