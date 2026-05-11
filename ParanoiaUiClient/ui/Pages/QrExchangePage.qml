import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Dialogs
import ParanoiaUiClient

Rectangle {
    id: root
    color: Theme.bgPrimary

    required property string peer
    required property bool   updateExisting

    signal back()
    signal exchangeConfirmed()

    property string role:           ""   // "initiator" | "responder"
    property int    step:           0    // 0=choose, 1=exchange, 2=compare
    property string localStateJson:   ""
    property string localPayloadJson: ""
    property string peerPayloadJson:  ""
    property string sas:            ""
    property string feedback:       ""

    function localFilePath(fileUrl) {
        let value = decodeURIComponent(String(fileUrl))
        if (value.startsWith("file://")) value = value.substring(7)
        return value
    }

    FileDialog {
        id: scanImageDialog
        title: "Выбрать изображение QR payload"
        fileMode: FileDialog.OpenFile
        nameFilters: ["Изображения (*.png *.jpg *.jpeg *.bmp *.webp)", "Все файлы (*)"]
        property var targetField: null
        onAccepted: {
            const decoded = QrCodeUtils.decodeFromImage(root.localFilePath(selectedFile))
            if (!decoded.ok) {
                root.feedback = decoded.error || "QR-код не прочитан."
                return
            }
            if (targetField) targetField.text = decoded.text
            root.feedback = "Payload считан из QR-кода."
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        ParaHeader {
            Layout.fillWidth: true
            title: root.updateExisting ? "Обновить ключ диалога" : "Обменяться ключом"
            onBackClicked: root.back()
        }

        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: availableWidth
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

            ColumnLayout {
                width: parent.width
                spacing: 16

                Item { Layout.preferredHeight: 4 }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 16
                    Layout.rightMargin: 16
                    spacing: 12

                    Text {
                        Layout.fillWidth: true
                        text: "Собеседник: " + root.peer
                        color: Theme.textSecondary
                        font.pixelSize: Theme.fontSm
                        font.family: Theme.fontFamily
                        elide: Text.ElideRight
                    }

                    // ── Шаг 0: выбор роли ──────────────────────────────
                    ColumnLayout {
                        visible: root.step === 0
                        Layout.fillWidth: true
                        spacing: 12

                        Text {
                            Layout.fillWidth: true
                            text: "Кто начинает обмен?"
                            color: Theme.textPrimary
                            font.pixelSize: Theme.fontMd
                            font.family: Theme.fontFamily
                            wrapMode: Text.WordWrap
                        }

                        ParaButton {
                            Layout.fillWidth: true
                            text: "Я создаю приглашение"
                            onClicked: {
                                root.feedback = ""
                                const res = Backend.createDialogKeyInvitation(root.peer)
                                if (!res.ok) {
                                    root.feedback = res.error || "Ошибка создания приглашения."
                                    return
                                }
                                root.localStateJson   = res.stateJson
                                root.localPayloadJson = res.payloadJson
                                root.role = "initiator"
                                root.step = 1
                            }
                        }

                        ParaButton {
                            Layout.fillWidth: true
                            text: "Я получил приглашение"
                            secondary: true
                            onClicked: {
                                root.feedback = ""
                                root.role = "responder"
                                root.step = 1
                            }
                        }
                    }

                    // ── Шаг 1: обмен payload-ами ───────────────────────
                    ColumnLayout {
                        visible: root.step === 1
                        Layout.fillWidth: true
                        spacing: 12

                        // --- Инициатор: показываем invitation, ждём response ---
                        ColumnLayout {
                            visible: root.role === "initiator"
                            Layout.fillWidth: true
                            spacing: 8

                            Text {
                                Layout.fillWidth: true
                                text: "Ваше приглашение — передайте собеседнику:"
                                color: Theme.textPrimary
                                font.pixelSize: Theme.fontSm
                                font.family: Theme.fontFamily
                                wrapMode: Text.WordWrap
                            }

                            QrCodeBox {
                                Layout.alignment: Qt.AlignHCenter
                                boxSize: Math.min(260, root.width - 48)
                                payload: root.localPayloadJson
                                caption: "Invitation QR"
                                visible: root.localPayloadJson.length > 0
                            }

                            CopyablePublicKeyBlock {
                                Layout.fillWidth: true
                                visible: root.localPayloadJson.length > 0
                                lineCount: 5
                                keyText: {
                                    try { return JSON.stringify(JSON.parse(root.localPayloadJson), null, 2) }
                                    catch(e) { return root.localPayloadJson }
                                }
                                copyText: root.localPayloadJson
                                onCopied: root.feedback = "Payload скопирован."
                            }

                            ParaInput {
                                id: initiatorResponseInput
                                Layout.fillWidth: true
                                label: "Вставьте ответ собеседника:"
                                placeholder: "Вставьте response payload…"
                                lineCount: 5
                            }

                            ParaButton {
                                Layout.fillWidth: true
                                text: "Считать из QR-изображения"
                                secondary: true
                                onClicked: {
                                    scanImageDialog.targetField = initiatorResponseInput
                                    scanImageDialog.open()
                                }
                            }

                            ParaButton {
                                Layout.fillWidth: true
                                text: "Рассчитать SAS"
                                onClicked: {
                                    root.peerPayloadJson = initiatorResponseInput.text.trim()
                                    const res = Backend.dialogKeyFingerprint(root.localStateJson, root.peerPayloadJson)
                                    if (!res.ok) {
                                        root.feedback = res.error || "Ошибка расчёта SAS."
                                        return
                                    }
                                    root.sas = res.fingerprint
                                    root.feedback = ""
                                    root.step = 2
                                }
                            }
                        }

                        // --- Ответчик: вставляем invitation, создаём response ---
                        ColumnLayout {
                            visible: root.role === "responder"
                            Layout.fillWidth: true
                            spacing: 8                    

                            ParaInput {
                                id: responderInvitationInput
                                Layout.fillWidth: true
                                label: "Вставьте приглашение собеседника:"
                                placeholder: "Вставьте invitation payload…"
                                lineCount: 5
                            }

                            ParaButton {
                                Layout.fillWidth: true
                                text: "Считать из QR-изображения"
                                secondary: true
                                onClicked: {
                                    scanImageDialog.targetField = responderInvitationInput
                                    scanImageDialog.open()
                                }
                            }

                            ParaButton {
                                Layout.fillWidth: true
                                text: "Создать ответ"
                                onClicked: {
                                    root.peerPayloadJson = responderInvitationInput.text.trim()
                                    const res = Backend.createDialogKeyResponse(root.peerPayloadJson)
                                    if (!res.ok) {
                                        root.feedback = res.error || "Ошибка создания ответа."
                                        return
                                    }
                                    root.localStateJson   = res.stateJson
                                    root.localPayloadJson = res.payloadJson
                                    root.sas = res.fingerprint
                                    root.feedback = ""
                                    responderSharePane.visible = true
                                }
                            }

                            ColumnLayout {
                                id: responderSharePane
                                visible: false
                                Layout.fillWidth: true
                                spacing: 8

                                Text {
                                    Layout.fillWidth: true
                                    text: "Ваш ответ — передайте инициатору:"
                                    color: Theme.textPrimary
                                    font.pixelSize: Theme.fontSm
                                    font.family: Theme.fontFamily
                                    wrapMode: Text.WordWrap
                                }

                                QrCodeBox {
                                    Layout.alignment: Qt.AlignHCenter
                                    boxSize: Math.min(260, root.width - 48)
                                    payload: root.localPayloadJson
                                    caption: "Response QR"
                                    visible: root.localPayloadJson.length > 0
                                }

                                CopyablePublicKeyBlock {
                                    Layout.fillWidth: true
                                    visible: root.localPayloadJson.length > 0
                                    lineCount: 5
                                    keyText: {
                                        try { return JSON.stringify(JSON.parse(root.localPayloadJson), null, 2) }
                                        catch(e) { return root.localPayloadJson }
                                    }
                                    copyText: root.localPayloadJson
                                    onCopied: root.feedback = "Payload скопирован."
                                }

                                ParaButton {
                                    Layout.fillWidth: true
                                    text: "Далее — сравнить SAS"
                                    onClicked: {
                                        root.feedback = ""
                                        root.step = 2
                                    }
                                }
                            }
                        }
                    }

                    // ── Шаг 2: сравнение SAS и подтверждение ───────────
                    ColumnLayout {
                        visible: root.step === 2
                        Layout.fillWidth: true
                        spacing: 12

                        Text {
                            Layout.fillWidth: true
                            text: "Сравните код безопасности по независимому каналу:"
                            color: Theme.textPrimary
                            font.pixelSize: Theme.fontSm
                            font.family: Theme.fontFamily
                            wrapMode: Text.WordWrap
                        }

                        Text {
                            Layout.fillWidth: true
                            text: root.sas
                            color: Theme.success
                            font.pixelSize: 28
                            font.family: Theme.fontFamily
                            font.weight: Font.Bold
                            horizontalAlignment: Text.AlignHCenter
                        }

                        ParaButton {
                            Layout.fillWidth: true
                            text: "Подтвердить"
                            onClicked: {
                                const res = Backend.confirmDialogKeyExchange(
                                    root.peer,
                                    root.localStateJson,
                                    root.peerPayloadJson,
                                    root.sas,
                                    root.updateExisting
                                )
                                if (!res.ok) {
                                    root.feedback = res.error || "Ошибка подтверждения."
                                    return
                                }
                                root.feedback = ""
                                root.exchangeConfirmed()
                            }
                        }

                        ParaButton {
                            Layout.fillWidth: true
                            text: "Отмена"
                            secondary: true
                            onClicked: root.back()
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        text: root.feedback
                        color: root.feedback.includes("Ошибка") || root.feedback.includes("ошиб")
                               ? Theme.error : Theme.textSecondary
                        font.pixelSize: Theme.fontSm
                        font.family: Theme.fontFamily
                        wrapMode: Text.WordWrap
                        visible: root.feedback.length > 0
                    }

                    Item { Layout.preferredHeight: 16 }
                }
            }
        }
    }
}
