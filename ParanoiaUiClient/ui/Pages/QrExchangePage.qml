import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
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
    property bool   feedbackError:  false
    property var cameraScanTargetField: null
    readonly property bool cameraQrScan: MultimediaAvailable && CameraAvailable && (Qt.platform.os === "android" || Qt.platform.os === "ios" || Qt.platform.os === "osx")

    // Единая точка установки фидбэка: текст + явный флаг ошибки (цвет берётся из
    // feedbackError, а не из проверки подстроки — иначе подсветка ломается при
    // переводе строк на другой язык).
    function setFeedback(text, isError) {
        root.feedback = text
        root.feedbackError = isError === true
    }

    function openCameraScanner(targetField) {
        root.cameraScanTargetField = targetField
        cameraScanLoader.active = true
    }

    function openQrReader(targetField) {
        if (root.cameraQrScan) {
            root.openCameraScanner(targetField)
            return
        }
        scanImageDialog.targetField = targetField
        scanImageDialog.open()
    }

    ParaFileDialog {
        id: scanImageDialog
        title: qsTr("Выбрать изображение QR payload")
        mode: "open"
        nameFilters: [qsTr("Изображения (*.png *.jpg *.jpeg *.bmp *.webp)"), qsTr("Все файлы (*)")]
        property var targetField: null
        onAccepted: {
            const decoded = QrCodeUtils.decodeFromImage(Backend.urlToLocalPath(selectedFile))
            if (!decoded.ok) {
                root.setFeedback(decoded.error || qsTr("QR-код не прочитан."), true)
                return
            }
            if (targetField) targetField.text = decoded.text
            root.setFeedback(qsTr("Payload считан из QR-кода."), false)
        }
    }

    Loader {
        id: cameraScanLoader
        anchors.fill: parent
        z: 1000
        active: false
        source: active ? "QrScanPage.qml" : ""
        onLoaded: {
            item.title = qsTr("Сканировать QR payload")
            item.instructions = qsTr("Наведите камеру на QR-код с payload обмена ключом.")
            item.back.connect(function () { cameraScanLoader.active = false })
            item.qrScanned.connect(function (text) {
                if (root.cameraScanTargetField)
                    root.cameraScanTargetField.text = text
                root.setFeedback(qsTr("Payload считан из QR-кода."), false)
                cameraScanLoader.active = false
            })
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        ParaHeader {
            Layout.fillWidth: true
            title: root.updateExisting ? qsTr("Обновить ключ диалога") : qsTr("Обменяться ключом")
            onBackClicked: root.back()
        }

        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: availableWidth
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ScrollBar.vertical: AppScrollBar {}

            ColumnLayout {
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.min(parent.width - 32, 560)
                spacing: 16

                Item { Layout.preferredHeight: 4 }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 16
                    Layout.rightMargin: 16
                    spacing: 12

                    Text {
                        Layout.fillWidth: true
                        text: qsTr("Собеседник: %1").arg(root.peer)
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
                            text: qsTr("Кто начинает обмен?")
                            color: Theme.textPrimary
                            font.pixelSize: Theme.fontMd
                            font.family: Theme.fontFamily
                            wrapMode: Text.WordWrap
                        }

                        ParaButton {
                            Layout.fillWidth: true
                            text: qsTr("Я создаю приглашение")
                            onClicked: {
                                root.feedback = ""
                                const res = Backend.createDialogKeyInvitation(root.peer)
                                if (!res.ok) {
                                    root.setFeedback(res.error || qsTr("Ошибка создания приглашения."), true)
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
                            text: qsTr("Я получил приглашение")
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
                                text: qsTr("Ваше приглашение — передайте собеседнику:")
                                color: Theme.textPrimary
                                font.pixelSize: Theme.fontSm
                                font.family: Theme.fontFamily
                                wrapMode: Text.WordWrap
                            }

                            QrCodeBox {
                                Layout.alignment: Qt.AlignHCenter
                                boxSize: Math.min(260, root.width - 48)
                                payload: root.localPayloadJson
                                caption: qsTr("Invitation QR")
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
                                onCopied: root.setFeedback(qsTr("Payload скопирован."), false)
                            }

                            ParaInput {
                                id: initiatorResponseInput
                                Layout.fillWidth: true
                                label: qsTr("Вставьте ответ собеседника:")
                                placeholder: qsTr("Вставьте response payload…")
                                lineCount: 5
                            }

                            ParaButton {
                                Layout.fillWidth: true
                                text: root.cameraQrScan ? qsTr("Сканировать QR камерой") : qsTr("Считать QR из файла")
                                secondary: true
                                onClicked: root.openQrReader(initiatorResponseInput)
                            }

                            ParaButton {
                                Layout.fillWidth: true
                                text: qsTr("Рассчитать SAS")
                                onClicked: {
                                    root.peerPayloadJson = initiatorResponseInput.text.trim()
                                    const res = Backend.dialogKeyFingerprint(root.localStateJson, root.peerPayloadJson)
                                    if (!res.ok) {
                                        root.setFeedback(res.error || qsTr("Ошибка расчёта SAS."), true)
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
                                label: qsTr("Вставьте приглашение собеседника:")
                                placeholder: qsTr("Вставьте invitation payload…")
                                lineCount: 5
                            }

                            ParaButton {
                                Layout.fillWidth: true
                                text: root.cameraQrScan ? qsTr("Сканировать QR камерой") : qsTr("Считать QR из файла")
                                secondary: true
                                onClicked: root.openQrReader(responderInvitationInput)
                            }

                            ParaButton {
                                Layout.fillWidth: true
                                text: qsTr("Создать ответ")
                                onClicked: {
                                    root.peerPayloadJson = responderInvitationInput.text.trim()
                                    const res = Backend.createDialogKeyResponse(root.peerPayloadJson)
                                    if (!res.ok) {
                                        root.setFeedback(res.error || qsTr("Ошибка создания ответа."), true)
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
                                    text: qsTr("Ваш ответ — передайте инициатору:")
                                    color: Theme.textPrimary
                                    font.pixelSize: Theme.fontSm
                                    font.family: Theme.fontFamily
                                    wrapMode: Text.WordWrap
                                }

                                QrCodeBox {
                                    Layout.alignment: Qt.AlignHCenter
                                    boxSize: Math.min(260, root.width - 48)
                                    payload: root.localPayloadJson
                                    caption: qsTr("Response QR")
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
                                    onCopied: root.setFeedback(qsTr("Payload скопирован."), false)
                                }

                                ParaButton {
                                    Layout.fillWidth: true
                                    text: qsTr("Далее — сравнить SAS")
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
                            text: qsTr("Сравните код безопасности по независимому каналу:")
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
                            text: qsTr("Подтвердить")
                            onClicked: {
                                const res = Backend.confirmDialogKeyExchange(
                                    root.peer,
                                    root.localStateJson,
                                    root.peerPayloadJson,
                                    root.sas,
                                    root.updateExisting
                                )
                                if (!res.ok) {
                                    root.setFeedback(res.error || qsTr("Ошибка подтверждения."), true)
                                    return
                                }
                                root.feedback = ""
                                root.exchangeConfirmed()
                            }
                        }

                        ParaButton {
                            Layout.fillWidth: true
                            text: qsTr("Отмена")
                            secondary: true
                            onClicked: root.back()
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        text: root.feedback
                        color: root.feedbackError ? Theme.error : Theme.textSecondary
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
