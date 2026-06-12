import QtQuick
import QtQuick.Layouts
import ParanoiaUiClient

Rectangle {
    id: root
    implicitWidth: 420
    implicitHeight: 780
    width: parent ? parent.width : implicitWidth
    height: parent ? parent.height : implicitHeight
    color: Theme.bgPrimary

    property string pin: ""
    readonly property int maxDigits: 20
    readonly property int minDigits: 4
    readonly property int contentMargin: Math.min(24, Math.max(14, Math.round(width * 0.05)))

    property int lastResult: -2  // -2=ничего, -1=internal, 0=ok, 1=wrong, 2=locked_out, 3=not_init
    property string errorText: ""
    property bool busy: false
    property int lockoutSeconds: 0

    signal accepted(string pin)

    Timer {
        id: lockoutTicker
        interval: 1000
        repeat: true
        running: root.lockoutSeconds > 0
        onTriggered: {
            const remaining = Backend.vaultLockoutSeconds()
            root.lockoutSeconds = remaining
            if (remaining === 0) {
                root.errorText = ""
                root.lastResult = -2
            }
        }
    }

    function refreshLockout() {
        root.lockoutSeconds = Backend.vaultLockoutSeconds()
    }

    Component.onCompleted: refreshLockout()

    Connections {
        target: Backend
        function onVaultUnlockResult(result) {
            root.busy = false
            root.lastResult = result
            switch (result) {
                case 0:
                    root.errorText = ""
                    break
                case 1:
                    root.errorText = qsTr("Неверный PIN")
                    root.pin = ""
                    pinInput.text = ""
                    root.refreshLockout()
                    break
                case 2:
                    root.errorText = qsTr("Слишком много неверных попыток — подождите")
                    root.refreshLockout()
                    break
                case 3:
                    root.errorText = qsTr("PIN ещё не установлен")
                    break
                default:
                    root.errorText = qsTr("Внутренняя ошибка")
            }
        }
    }

    function sanitizePin(value) {
        return String(value).replace(/[^0-9]/g, "").slice(0, maxDigits)
    }

    function appendDigit(digit) {
        if (root.busy || root.lockoutSeconds > 0) return
        root.pin = sanitizePin(root.pin + digit)
    }

    function removeDigit() {
        if (root.busy || root.lockoutSeconds > 0) return
        if (root.pin.length > 0)
            root.pin = root.pin.slice(0, -1)
    }

    function confirmPin() {
        if (root.busy || root.lockoutSeconds > 0) return
        if (root.pin.length < root.minDigits) return
        root.busy = true
        root.errorText = ""
        root.accepted(root.pin)
    }

    function fmtLockout(secs) {
        if (secs <= 0) return ""
        if (secs < 60) return qsTr("%1 сек").arg(secs)
        if (secs < 3600) return qsTr("%1 мин").arg(Math.ceil(secs / 60))
        return qsTr("%1 ч").arg(Math.ceil(secs / 3600))
    }

    onPinChanged: {
        if (pinInput.text !== pin)
            pinInput.text = pin
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        ParaHeader {
            Layout.fillWidth: true
            title: qsTr("Введите PIN-код")
            showBack: false
        }

        Flickable {
            id: pinFlick
            Layout.fillWidth: true
            Layout.fillHeight: true
            // Контент-область не ниже вьюпорта — чтобы можно было центрировать
            // короткий контент; на узком экране (мобилка) растёт под скролл.
            contentHeight: Math.max(pinFlick.height, contentCol.implicitHeight + root.contentMargin * 2)
            boundsBehavior: Flickable.StopAtBounds
            clip: true

            ColumnLayout {
                id: contentCol
                // Центрируем по горизонтали и ограничиваем ширину; по ВЕРТИКАЛИ —
                // по центру вьюпорта (тянуться вверх неудобно). Если контент выше
                // экрана — прижимаемся к верху с отступом и скроллим.
                anchors.horizontalCenter: parent.horizontalCenter
                y: Math.max(root.contentMargin, (pinFlick.height - implicitHeight) / 2)
                width: Math.min(parent.width - root.contentMargin * 2, 460)
                spacing: 18

                ParaInput {
                    id: pinInput
                    Layout.fillWidth: true
                    label: qsTr("PIN-код")
                    placeholder: qsTr("Минимум %1 цифры").arg(root.minDigits)
                    echoMode: TextInput.Password
                    // На мобильных гасим виртуальную клавиатуру Qt — ввод PIN
                    // идёт только через собственный экранный keypad ниже.
                    readOnly: Qt.platform.os === "android" || Qt.platform.os === "ios"
                    hasError: root.errorText.length > 0
                    errorText: root.errorText
                    enabled: !root.busy && root.lockoutSeconds === 0

                    Binding {
                        target: pinInput
                        property: "inputMethodHints"
                        value: Qt.ImhDigitsOnly | Qt.ImhSensitiveData | Qt.ImhNoPredictiveText
                    }

                    Binding {
                        target: pinInput
                        property: "showPasteButton"
                        value: false
                    }

                    onTextChanged: {
                        const sanitized = root.sanitizePin(pinInput.text)
                        if (sanitized !== pinInput.text) {
                            pinInput.text = sanitized
                            return
                        }
                        root.pin = sanitized
                    }
                    onAccepted: root.confirmPin()
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 48
                    radius: Theme.radiusSm
                    color: Theme.bgCard
                    border.color: Theme.border
                    border.width: 1
                    visible: root.lockoutSeconds > 0

                    Text {
                        anchors.centerIn: parent
                        text: qsTr("Подождите ещё %1").arg(root.fmtLockout(root.lockoutSeconds))
                        color: Theme.error
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSm
                        font.weight: Font.DemiBold
                    }
                }

                Grid {
                    Layout.fillWidth: true
                    columns: 3
                    spacing: 10

                    Repeater {
                        model: ["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "backspace"]

                        Rectangle {
                            id: keypadButton

                            required property string modelData

                            width: (parent.width - 20) / 3
                            height: 54
                            radius: height / 2          // скруглённые «пилюли»
                            color: keypadButton.modelData === "" ? "transparent" : pressArea.pressed ? Theme.accentDim : Theme.bgCard
                            border.color: keypadButton.modelData === "" ? "transparent" : Theme.border
                            border.width: keypadButton.modelData === "" ? 0 : 1
                            opacity: (root.busy || root.lockoutSeconds > 0) ? 0.4 : 1.0

                            Behavior on color { ColorAnimation { duration: 120 } }

                            Text {
                                anchors.centerIn: parent
                                text: keypadButton.modelData
                                visible: keypadButton.modelData !== "backspace"
                                color: Theme.textPrimary
                                font.family: Theme.fontFamily
                                font.pixelSize: 22
                                font.weight: Font.Medium
                            }

                            AppIcon {
                                anchors.centerIn: parent
                                width: 22
                                height: 22
                                visible: keypadButton.modelData === "backspace"
                                name: "backspace"
                                iconColor: Theme.textSecondary
                                strokeWidth: 1.8
                            }

                            MouseArea {
                                id: pressArea
                                anchors.fill: parent
                                enabled: keypadButton.modelData !== "" && !root.busy && root.lockoutSeconds === 0
                                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                onClicked: keypadButton.modelData === "backspace" ? root.removeDigit() : root.appendDigit(keypadButton.modelData)
                            }
                        }
                    }
                }

                ParaButton {
                    Layout.fillWidth: true
                    text: root.busy ? qsTr("Проверка...") : qsTr("Разблокировать")
                    enabled: !root.busy && root.lockoutSeconds === 0 && root.pin.length >= root.minDigits
                    onClicked: root.confirmPin()
                }
            }
        }
    }
}
