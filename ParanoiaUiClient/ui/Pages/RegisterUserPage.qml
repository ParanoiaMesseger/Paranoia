import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import ParanoiaUiClient

Rectangle {
    id: root
    color: Theme.bgPrimary

    required property string targetDomain
    readonly property bool cameraQrScan: MultimediaAvailable && CameraAvailable && (Qt.platform.os === "android" || Qt.platform.os === "ios" || Qt.platform.os === "osx")

    signal back()

    function openQrReader() {
        if (root.cameraQrScan)
            cameraScanLoader.active = true
        else
            registrationQrImageDialog.open()
    }

    Connections {
        target: Backend
        function onUserRegistered()       { regFeedback.text = qsTr("Пользователь зарегистрирован ✓"); root.back() }
        function onRegisterUserError(msg) { regFeedback.text = msg }
    }

    ParaFileDialog {
        id: registrationQrImageDialog
        title: qsTr("Выбрать изображение QR-кода")
        mode: "open"
        nameFilters: [qsTr("Изображения (*.png *.jpg *.jpeg *.bmp *.webp)"), qsTr("Все файлы (*)")]
        onAccepted: {
            const decoded = QrCodeUtils.decodeFromImage(Backend.urlToLocalPath(selectedFile))
            if (!decoded.ok) {
                regFeedback.text = decoded.error || qsTr("QR-код не прочитан.")
                return
            }
            const parsed = QrCodeUtils.registrationPublicKeyFromQr(decoded.text)
            if (!parsed.ok) {
                regFeedback.text = parsed.error || qsTr("QR-код не содержит публичный ключ.")
                return
            }
            newUserPubKeyInput.text = parsed.pubkey
            regFeedback.text = qsTr("QR-код прочитан ✓")
        }
    }

    Loader {
        id: cameraScanLoader
        anchors.fill: parent
        z: 1000
        active: false
        source: active ? "QrScanPage.qml" : ""
        onLoaded: {
            item.title = qsTr("Сканировать ключ")
            item.instructions = qsTr("Наведите камеру на QR-код с публичным ключом клиента.")
            item.back.connect(function () { cameraScanLoader.active = false })
            item.qrScanned.connect(function (text) {
                const parsed = QrCodeUtils.registrationPublicKeyFromQr(text)
                if (!parsed.ok) {
                    regFeedback.text = parsed.error || qsTr("QR-код не содержит публичный ключ.")
                    cameraScanLoader.active = false
                    return
                }
                newUserPubKeyInput.text = parsed.pubkey
                regFeedback.text = qsTr("QR-код прочитан ✓")
                cameraScanLoader.active = false
            })
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        ParaHeader {
            Layout.fillWidth: true
            title: qsTr("Зарегистрировать пользователя")
            onBackClicked: root.back()
        }

        Flickable {
            id: formFlick
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentHeight: Math.max(formFlick.height, contentCol.implicitHeight + 40)
            clip: true

            ColumnLayout {
                id: contentCol
                // По горизонтали — по центру с ограничением; по вертикали — по
                // центру вьюпорта (не липнуть к верху). Высокий контент — от верха.
                width: Math.min(parent.width - 40, 560)
                spacing: 16
                anchors.horizontalCenter: parent.horizontalCenter
                y: Math.max(20, (formFlick.height - implicitHeight) / 2)

                Text {
                    Layout.fillWidth: true
                    text: qsTr("Сервер: %1").arg(root.targetDomain)
                    color: Theme.textSecondary
                    font.pixelSize: Theme.fontSm
                    font.family:    Theme.fontFamily
                    elide: Text.ElideRight
                }

                ParaInput {
                    id: newUserPubKeyInput
                    Layout.fillWidth: true
                    label:       qsTr("Публичный ключ пользователя")
                    placeholder: qsTr("Вставьте ключ или считайте QR…")
                }

                ParaButton {
                    Layout.fillWidth: true
                    text: root.cameraQrScan ? qsTr("Сканировать QR камерой") : qsTr("Считать QR из файла")
                    secondary: true
                    onClicked: root.openQrReader()
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
                    text: qsTr("Зарегистрировать")
                    onClicked: {
                        let pubkey = newUserPubKeyInput.text.trim()
                        if (pubkey === "") {
                            regFeedback.text = qsTr("Введите публичный ключ.")
                            return
                        }
                        const parsed = QrCodeUtils.registrationPublicKeyFromQr(pubkey)
                        if (!parsed.ok) {
                            regFeedback.text = parsed.error || qsTr("Некорректный публичный ключ.")
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
