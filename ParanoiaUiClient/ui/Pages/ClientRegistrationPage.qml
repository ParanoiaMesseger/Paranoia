import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Dialogs
import ParanoiaUiClient

// Регистрация клиента. Поддерживает три источника параметров:
//   • ручной ввод адреса сервера;
//   • импорт «профиля подключения» (открытый QR/файл параметров сервера) —
//     заполняет адрес/резерв/тариф/параметры маскировки для любого тарифа;
//   • для корпоративного тарифа — дополнительный шаг: пользователь передаёт
//     админу свой ключ устройства, получает шифрованный бандл (идентичность +
//     PSK + маскировка) и импортирует его.
Rectangle {
    id: root
    color: Theme.bgPrimary

    signal back()
    signal loggedIn()

    property string publicKey:  ""
    property string privateKey: ""
    property bool   generating: false
    property bool   isLoading: false
    property string errorMsg: ""

    // Импортированный профиль подключения.
    property string tariff: ""
    property string importedMaskingUrl: ""
    property string importedMaskingTrusted: ""
    property string importFeedback: ""

    // Режимы ввода: по умолчанию показан выбор источника (QR/файл) + кнопка
    // «Ввести вручную». manualMode — пользователь выбрал ручной ввод; imported —
    // параметры подгружены из профиля подключения. В обоих случаях показывается
    // раздел ввода (адрес/имя/вход), а выбор источника скрывается.
    property bool manualMode: false
    property bool imported: false

    readonly property bool isCorporate: tariff === "corporate"
    // Выбор источника (QR/файл/вручную) — пока не выбран ручной ввод и не
    // импортированы параметры (и тариф не корпоративный).
    readonly property bool chooseVisible: !isCorporate && !manualMode && !imported
    // Раздел ввода адреса/имени/входа (частный/коммерческий/ручной).
    readonly property bool entryVisible: !isCorporate && !generating && (manualMode || imported)
    readonly property bool cameraQrScan: MultimediaAvailable &&
        (Qt.platform.os === "android" || Qt.platform.os === "ios" || Qt.platform.os === "osx")

    function tariffLabel(t) {
        switch (t) {
            case "private":    return "Частный сервер"
            case "commercial": return "Коммерческий тариф"
            case "corporate":  return "Корпоративный тариф"
            default:           return ""
        }
    }

    function registrationQrPayload() {
        return JSON.stringify({ type: "paranoia.registration.pubkey.v1", pubkey: root.publicKey })
    }

    function applyParsed(res) {
        if (!res.ok) {
            root.importFeedback = res.error || "Не удалось разобрать профиль подключения."
            return
        }
        root.tariff = res.tariff || ""
        root.importedMaskingUrl = res.masking_url || ""
        root.importedMaskingTrusted = res.masking_trusted_pubkey || ""
        endpointInput.text = res.server || ""
        const reserves = res.reserve_server_urls || []
        reserveEndpointInput.text = reserves.length > 0 ? reserves[0] : ""
        root.imported = true
        root.importFeedback = "Профиль подключения загружен: " + (root.tariffLabel(root.tariff) || "сервер")
    }

    function applyBundleText(text) { root.applyParsed(Backend.parseConnectionBundle(text)) }

    function openParamsQrReader() {
        if (root.cameraQrScan) { cameraScanLoader.active = true; return }
        paramsImageDialog.open()
    }

    Connections {
        target: Backend
        function onKeyPairGenerated(pub, priv) {
            root.publicKey  = pub
            root.privateKey = priv
            root.generating = false
        }
        function onLoginStateChanged() {
            if (Backend.loggedIn) {
                root.isLoading = false
                root.loggedIn()
            }
        }
        function onLoginError(msg) {
            root.isLoading = false
            root.errorMsg = msg
        }
    }

    Component.onCompleted: {
        generating = true
        Backend.generateKeyPair()
    }

    // ── Источники профиля подключения ────────────────────────────────────────
    FileDialog {
        id: paramsFileDialog
        title: "Выбрать профиль подключения"
        fileMode: FileDialog.OpenFile
        nameFilters: ["Профиль подключения (*.json)", "JSON (*.json)", "Все файлы (*)"]
        onAccepted: root.applyParsed(Backend.parseConnectionBundle(Backend.urlToLocalPath(selectedFile)))
    }
    FileDialog {
        id: paramsImageDialog
        title: "Выбрать изображение QR"
        fileMode: FileDialog.OpenFile
        nameFilters: ["Изображения (*.png *.jpg *.jpeg *.bmp *.webp)", "Все файлы (*)"]
        onAccepted: {
            const decoded = QrCodeUtils.decodeFromImage(Backend.urlToLocalPath(selectedFile))
            if (!decoded.ok) { root.importFeedback = decoded.error || "QR-код не прочитан."; return }
            root.applyBundleText(decoded.text)
        }
    }
    FileDialog {
        id: corpBundleDialog
        title: "Выбрать корпоративный бандл"
        fileMode: FileDialog.OpenFile
        nameFilters: ["Paranoia bundle (*.json)", "JSON (*.json)", "Все файлы (*)"]
        onAccepted: {
            const res = Backend.importProfile(Backend.urlToLocalPath(selectedFile))
            if (res.ok) root.importFeedback = "Бандл импортирован, выполняется вход…"
            else        root.importFeedback = res.error || "Ошибка импорта бандла."
        }
    }

    Loader {
        id: cameraScanLoader
        anchors.fill: parent
        z: 1000
        active: false
        source: active ? "QrScanPage.qml" : ""
        onLoaded: {
            item.title = "Сканировать профиль подключения"
            item.instructions = "Наведите камеру на QR-код параметров сервера."
            item.back.connect(function () { cameraScanLoader.active = false })
            item.qrScanned.connect(function (text) {
                root.applyBundleText(text)
                cameraScanLoader.active = false
            })
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing:      0

        ParaHeader {
            Layout.fillWidth: true
            title:            "Регистрация"
            onBackClicked:    root.back()
        }

        Flickable {
            Layout.fillWidth:  true
            Layout.fillHeight: true
            contentHeight:     content.implicitHeight + 32
            clip:              true

            ColumnLayout {
                id:             content
                width:          parent.width
                anchors.margins: 24
                anchors.left:   parent.left
                anchors.right:  parent.right
                spacing:        16

                Item { Layout.preferredHeight: 8 }

                // ── Выбор источника параметров ───────────────────────
                // По умолчанию — QR/файл + «Ввести вручную». После импорта или
                // выбора ручного ввода этот блок скрывается (см. chooseVisible).
                ColumnLayout {
                    Layout.fillWidth: true
                    visible: root.chooseVisible
                    spacing: 12

                    Text {
                        Layout.fillWidth: true
                        Layout.leftMargin: 24
                        Layout.rightMargin: 24
                        text: "Загрузите профиль подключения (QR/файл от администратора) — адрес сервера и параметры подставятся автоматически. Либо введите адрес сервера вручную."
                        color: Theme.textSecondary
                        font.pixelSize: Theme.fontXs
                        font.family: Theme.fontFamily
                        wrapMode: Text.WordWrap
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.leftMargin: 24
                        Layout.rightMargin: 24
                        spacing: 8

                        ParaButton {
                            Layout.fillWidth: true
                            Layout.minimumWidth: 0
                            secondary: true
                            text: "Сканировать QR"
                            onClicked: root.openParamsQrReader()
                        }
                        ParaButton {
                            Layout.fillWidth: true
                            Layout.minimumWidth: 0
                            secondary: true
                            text: "Выбрать файл"
                            onClicked: paramsFileDialog.open()
                        }
                    }

                    ParaButton {
                        Layout.fillWidth: true
                        Layout.leftMargin: 24
                        Layout.rightMargin: 24
                        secondary: true
                        text: "Ввести вручную"
                        onClicked: root.manualMode = true
                    }
                }

                // Бейдж тарифа.
                Rectangle {
                    Layout.fillWidth: true
                    Layout.leftMargin: 24
                    Layout.rightMargin: 24
                    visible: root.tariff.length > 0
                    implicitHeight: 32
                    radius: Theme.radiusSm
                    color: Theme.accentDim
                    Text {
                        anchors.centerIn: parent
                        text: "Тариф: " + root.tariffLabel(root.tariff)
                        color: Theme.textPrimary
                        font.pixelSize: Theme.fontSm
                        font.family: Theme.fontFamily
                        font.weight: Font.DemiBold
                    }
                }

                Text {
                    Layout.fillWidth: true
                    Layout.leftMargin: 24
                    Layout.rightMargin: 24
                    visible: root.importFeedback.length > 0
                    text: root.importFeedback
                    color: Theme.textSecondary
                    font.pixelSize: Theme.fontXs
                    font.family: Theme.fontFamily
                    wrapMode: Text.WordWrap
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.leftMargin: 24
                    Layout.rightMargin: 24
                    Layout.preferredHeight: 1
                    color: Theme.border
                    visible: !root.chooseVisible
                }

                // Generating indicator
                Rectangle {
                    Layout.fillWidth: true
                    Layout.leftMargin: 24
                    Layout.rightMargin: 24
                    height: 44
                    radius: Theme.radiusMd
                    color:  Theme.bgSecondary
                    visible: root.generating && !root.chooseVisible

                    Text {
                        anchors.centerIn: parent
                        text:  "Генерация ключей…"
                        color: Theme.textSecondary
                        font.pixelSize: Theme.fontSm
                        font.family:    Theme.fontFamily
                    }
                }

                // ════════════ КОРПОРАТИВНЫЙ ТАРИФ ════════════
                // Идентичность выдаёт админ: пользователь передаёт ключ устройства,
                // получает шифрованный бандл и импортирует его.
                ColumnLayout {
                    Layout.fillWidth: true
                    visible: root.isCorporate
                    spacing: 16

                    CopyablePublicKeyBlock {
                        Layout.fillWidth: true
                        Layout.leftMargin: 24
                        Layout.rightMargin: 24
                        title: "Передайте администратору ваш ключ устройства — он пришлёт ваш корпоративный бандл:"
                        keyText: Backend.devicePubkey
                    }

                    QrCodeBox {
                        Layout.alignment: Qt.AlignHCenter
                        boxSize: Math.min(240, Math.max(180, content.width - 48))
                        payload: Backend.devicePubkey
                        caption: Backend.devicePubkey.length > 0 ? Backend.devicePubkey.substring(0, 12) + "..." : ""
                    }

                    ParaButton {
                        Layout.fillWidth: true
                        Layout.leftMargin: 24
                        Layout.rightMargin: 24
                        text: "Импортировать корпоративный бандл"
                        onClicked: corpBundleDialog.open()
                    }
                }

                // ════════════ ЧАСТНЫЙ / КОММЕРЧЕСКИЙ / РУЧНОЙ ════════════
                ColumnLayout {
                    Layout.fillWidth: true
                    visible: root.entryVisible
                    spacing: 16

                    CopyablePublicKeyBlock {
                        Layout.fillWidth: true
                        Layout.leftMargin: 24
                        Layout.rightMargin: 24
                        title: "Передайте ваш публичный ключ администратору сервера"
                        keyText: root.publicKey
                    }

                    QrCodeBox {
                        Layout.alignment: Qt.AlignHCenter
                        boxSize: Math.min(240, Math.max(180, content.width - 48))
                        payload: root.registrationQrPayload()
                        caption: root.publicKey.length > 0 ? root.publicKey.substring(0, 12) + "..." : ""
                    }

                    Text {
                        Layout.alignment:   Qt.AlignHCenter
                        text:               "Или дайте администратору отсканировать этот QR-код. Ключ сохранён локально и восстановится после перезапуска."
                        color:              Theme.textSecondary
                        font.pixelSize:     Theme.fontXs
                        font.family:        Theme.fontFamily
                        wrapMode:           Text.WordWrap
                        horizontalAlignment: Text.AlignHCenter
                        Layout.fillWidth:   true
                        Layout.leftMargin: 24
                        Layout.rightMargin: 24
                    }

                    ParaInput {
                        id: endpointInput
                        Layout.fillWidth: true
                        Layout.leftMargin: 24
                        Layout.rightMargin: 24
                        Layout.minimumWidth: 0
                        label: "Адрес сервера"
                        placeholder: "https://example.com"
                    }

                    ParaInput {
                        id: reserveEndpointInput
                        Layout.fillWidth: true
                        Layout.leftMargin: 24
                        Layout.rightMargin: 24
                        Layout.minimumWidth: 0
                        label: "Резервный адрес сервера"
                        placeholder: "https://cdn.example.com (опционально)"
                    }

                    ParaInput {
                        id: usernameInput
                        Layout.fillWidth: true
                        Layout.leftMargin: 24
                        Layout.rightMargin: 24
                        Layout.minimumWidth: 0
                        label: "Имя пользователя"
                        placeholder: "username"
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.leftMargin: 24
                        Layout.rightMargin: 24
                        implicitHeight: errorText.implicitHeight + 20
                        radius: Theme.radiusSm
                        color: Theme.errorBg
                        visible: root.errorMsg !== ""

                        Text {
                            id: errorText
                            anchors.fill: parent
                            anchors.margins: 10
                            text: root.errorMsg
                            color: Theme.error
                            font.pixelSize: Theme.fontSm
                            font.family: Theme.fontFamily
                            wrapMode: Text.WordWrap
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }

                    ParaButton {
                        Layout.fillWidth: true
                        Layout.leftMargin: 24
                        Layout.rightMargin: 24
                        text:             root.isLoading ? "Вход…" : "Я передал ключ, войти"
                        enabled:          !root.generating && !root.isLoading
                        onClicked: {
                            const server = endpointInput.text.trim()
                            const username = usernameInput.text.trim()
                            if (server === "" || username === "") {
                                root.errorMsg = "Укажите сервер и имя пользователя."
                                return
                            }
                            if (root.privateKey === "") {
                                root.errorMsg = "Ключи ещё не сгенерированы."
                                return
                            }
                            root.errorMsg = ""
                            root.isLoading = true
                            Backend.loginClientWithMeta(server, reserveEndpointInput.text.trim(), username,
                                                        root.privateKey, root.tariff, root.importedMaskingUrl,
                                                        "", root.importedMaskingTrusted)
                        }
                    }
                }

                Item { Layout.preferredHeight: 16 }
            }
        }
    }
}
