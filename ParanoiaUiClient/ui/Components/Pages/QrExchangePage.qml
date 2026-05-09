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

    function localFilePath(fileUrl) {
        let value = decodeURIComponent(String(fileUrl))
        if (value.startsWith("file://"))
            value = value.substring(7)
        return value
    }

    FileDialog {
        id: qrPeerPayloadImageDialog
        title: "Выбрать изображение QR payload"
        fileMode: FileDialog.OpenFile
        nameFilters: ["Изображения (*.png *.jpg *.jpeg *.bmp *.webp)", "Все файлы (*)"]
        onAccepted: {
            const decoded = QrCodeUtils.decodeFromImage(root.localFilePath(selectedFile))
            if (!decoded.ok) {
                qrExchangeFeedback.text = decoded.error || "QR-код не прочитан."
                return
            }
            qrPeerPayloadJson.text = decoded.text
            qrExchangeFeedback.text = "Payload считан из QR-кода."
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        ParaHeader {
            Layout.fillWidth: true
            title: "QR/JSON обмен ключом"
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
                spacing: 12

                Item { Layout.preferredHeight: 8 }

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

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        ParaButton {
                            Layout.fillWidth: true
                            text: "Создать invitation"
                            onClicked: {
                                let res = Backend.createDialogKeyInvitation(root.peer)
                                if (!res.ok) {
                                    qrExchangeFeedback.text = res.error || "Ошибка invitation."
                                    return
                                }
                                qrLocalStateJson.text = res.stateJson
                                qrLocalPayloadJson.text = res.payloadJson
                                qrFingerprintText.text = ""
                                qrExchangeFeedback.text = "Передайте payload собеседнику. State не отправляйте."
                            }
                        }

                        ParaButton {
                            Layout.fillWidth: true
                            text: "Создать response"
                            secondary: true
                            onClicked: {
                                let res = Backend.createDialogKeyResponse(qrPeerPayloadJson.text.trim())
                                if (!res.ok) {
                                    qrExchangeFeedback.text = res.error || "Ошибка response."
                                    return
                                }
                                qrLocalStateJson.text = res.stateJson
                                qrLocalPayloadJson.text = res.payloadJson
                                qrFingerprintText.text = res.fingerprint
                                qrExchangeFeedback.text = "Передайте response payload инициатору и сравните SAS."
                            }
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        text: "Ваш payload для передачи"
                        color: Theme.textPrimary
                        font.pixelSize: Theme.fontSm
                        font.family: Theme.fontFamily
                    }

                    TextArea {
                        id: qrLocalPayloadJson
                        Layout.fillWidth: true
                        implicitHeight: 86
                        readOnly: true
                        wrapMode: TextEdit.Wrap
                        inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase
                        color: Theme.textPrimary
                        selectedTextColor: Theme.textPrimary
                        selectionColor: Theme.accent
                        background: Rectangle { color: Theme.bgInput; border.color: Theme.border; radius: Theme.radiusSm }
                    }

                    QrCodeBox {
                        Layout.alignment: Qt.AlignHCenter
                        boxSize: Math.min(280, root.width - 48)
                        payload: qrLocalPayloadJson.text
                        caption: "QR payload"
                        visible: qrLocalPayloadJson.text.length > 0
                    }

                    ParaButton {
                        Layout.fillWidth: true
                        text: "Копировать payload"
                        secondary: true
                        onClicked: {
                            qrLocalPayloadJson.selectAll()
                            qrLocalPayloadJson.copy()
                            qrExchangeFeedback.text = "Payload скопирован."
                        }
                    }

                    TextArea {
                        id: qrLocalStateJson
                        visible: false
                        inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase
                    }

                    Text {
                        Layout.fillWidth: true
                        text: "Payload собеседника"
                        color: Theme.textPrimary
                        font.pixelSize: Theme.fontSm
                        font.family: Theme.fontFamily
                    }

                    TextArea {
                        id: qrPeerPayloadJson
                        Layout.fillWidth: true
                        implicitHeight: 86
                        wrapMode: TextEdit.Wrap
                        inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase
                        color: Theme.textPrimary
                        selectedTextColor: Theme.textPrimary
                        selectionColor: Theme.accent
                        placeholderText: "Вставьте invitation или response payload JSON…"
                        placeholderTextColor: Theme.textHint
                        background: Rectangle { color: Theme.bgInput; border.color: Theme.border; radius: Theme.radiusSm }
                    }

                    ParaButton {
                        Layout.fillWidth: true
                        text: "Считать payload из QR-изображения"
                        secondary: true
                        onClicked: qrPeerPayloadImageDialog.open()
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        ParaButton {
                            Layout.fillWidth: true
                            text: "Рассчитать SAS"
                            onClicked: {
                                let res = Backend.dialogKeyFingerprint(qrLocalStateJson.text, qrPeerPayloadJson.text.trim())
                                if (!res.ok) {
                                    qrExchangeFeedback.text = res.error || "Ошибка SAS."
                                    return
                                }
                                qrFingerprintText.text = res.fingerprint
                                qrExchangeFeedback.text = "Сравните SAS по независимому каналу."
                            }
                        }

                        ParaButton {
                            Layout.fillWidth: true
                            text: "Подтвердить"
                            secondary: true
                            onClicked: {
                                let res = Backend.confirmDialogKeyExchange(
                                    root.peer,
                                    qrLocalStateJson.text,
                                    qrPeerPayloadJson.text.trim(),
                                    qrFingerprintText.text,
                                    root.updateExisting
                                )
                                if (!res.ok) {
                                    qrExchangeFeedback.text = res.error || "Ошибка подтверждения."
                                    return
                                }
                                qrExchangeFeedback.text = "Ключ сохранён."
                                root.exchangeConfirmed()
                            }
                        }
                    }

                    Text {
                        id: qrFingerprintText
                        Layout.fillWidth: true
                        text: ""
                        color: Theme.success
                        font.pixelSize: 28
                        font.family: Theme.fontFamily
                        font.weight: Font.Bold
                        horizontalAlignment: Text.AlignHCenter
                        visible: text.length > 0
                    }

                    Text {
                        id: qrExchangeFeedback
                        Layout.fillWidth: true
                        color: text.includes("ошиб") || text.includes("Ошибка") ? Theme.error : Theme.textSecondary
                        font.pixelSize: Theme.fontSm
                        font.family: Theme.fontFamily
                        wrapMode: Text.WordWrap
                        visible: text.length > 0
                    }

                    Item { Layout.preferredHeight: 16 }
                }
            }
        }
    }
}
