import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Dialogs
import ParanoiaUiClient

Rectangle {
    id: root
    color: Theme.bgPrimary

    required property string targetDomain

    signal back()

    function localFilePath(fileUrl) {
        let value = decodeURIComponent(String(fileUrl))
        if (value.startsWith("file://"))
            value = value.substring(7)
        return value
    }

    Connections {
        target: Backend
        function onUserRegistered()       { regFeedback.text = "Пользователь зарегистрирован ✓"; root.back() }
        function onRegisterUserError(msg) { regFeedback.text = msg }
    }

    FileDialog {
        id: registrationQrImageDialog
        title: "Выбрать изображение QR-кода"
        fileMode: FileDialog.OpenFile
        nameFilters: ["Изображения (*.png *.jpg *.jpeg *.bmp *.webp)", "Все файлы (*)"]
        onAccepted: {
            const decoded = QrCodeUtils.decodeFromImage(root.localFilePath(selectedFile))
            if (!decoded.ok) {
                regFeedback.text = decoded.error || "QR-код не прочитан."
                return
            }
            const parsed = QrCodeUtils.registrationPublicKeyFromQr(decoded.text)
            if (!parsed.ok) {
                regFeedback.text = parsed.error || "QR-код не содержит публичный ключ."
                return
            }
            newUserPubKeyInput.text = parsed.pubkey
            regFeedback.text = "QR-код прочитан ✓"
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        ParaHeader {
            Layout.fillWidth: true
            title: "Зарегистрировать пользователя"
            onBackClicked: root.back()
        }

        Flickable {
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentHeight: contentCol.implicitHeight
            clip: true

            ColumnLayout {
                id: contentCol
                width: parent.width
                spacing: 16
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 20

                Text {
                    Layout.fillWidth: true
                    text: "Сервер: " + root.targetDomain
                    color: Theme.textSecondary
                    font.pixelSize: Theme.fontSm
                    font.family:    Theme.fontFamily
                    elide: Text.ElideRight
                }

                ParaInput {
                    id: newUserPubKeyInput
                    Layout.fillWidth: true
                    label:       "Публичный ключ пользователя"
                    placeholder: "Вставьте ключ или считайте QR…"
                }

                ParaButton {
                    Layout.fillWidth: true
                    text: "Считать QR с изображения"
                    secondary: true
                    onClicked: registrationQrImageDialog.open()
                }

                Text {
                    id: regFeedback
                    Layout.fillWidth: true
                    color: text.includes("✓") ? Theme.success : Theme.error
                    font.pixelSize: Theme.fontSm
                    font.family:    Theme.fontFamily
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    visible: text.length > 0
                }

                ParaButton {
                    Layout.fillWidth: true
                    text: "Зарегистрировать"
                    onClicked: {
                        let pubkey = newUserPubKeyInput.text.trim()
                        if (pubkey === "") {
                            regFeedback.text = "Введите публичный ключ."
                            return
                        }
                        const parsed = QrCodeUtils.registrationPublicKeyFromQr(pubkey)
                        if (!parsed.ok) {
                            regFeedback.text = parsed.error || "Некорректный публичный ключ."
                            return
                        }
                        pubkey = parsed.pubkey
                        regFeedback.text = ""
                        Backend.registerUser(root.targetDomain, pubkey)
                    }
                }

                Item { Layout.preferredHeight: 16 }
            }
        }
    }
}
