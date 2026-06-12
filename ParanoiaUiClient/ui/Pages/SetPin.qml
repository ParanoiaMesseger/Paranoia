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
    property bool showBack: false
    /// Заголовок страницы — переопределяется, например, при reuse в ChangePin.
    property string title: qsTr("Установите PIN-код")
    /// Показывать панель с уровнем защищённости (комбинации/энтропия/время взлома).
    /// При confirm-шаге или при вводе старого PIN'а — скрываем.
    property bool showStrength: true
    /// Опциональное предупреждение/ошибка над клавиатурой (например,
    /// «PIN'ы не совпадают» в подтверждении ChangePin).
    property string banner: ""
    readonly property int maxDigits: 20
    readonly property int minDigits: 4
    readonly property int contentMargin: Math.min(24, Math.max(14, Math.round(width * 0.05)))

    readonly property double combinations: pin.length > 0 ? Math.pow(10, pin.length) : 0
    readonly property double entropy: pin.length * 3.32
    readonly property double attackSecsAvg: combinations > 0 ? (combinations / 2) / 100 : 0
    readonly property double attackSecsFull: combinations > 0 ? combinations / 100 : 0
    readonly property double meterPct: pin.length > 0 ? Math.min(1.0, (pin.length / 16) * 0.90 + 0.05) : 0

    readonly property int level: {
        if (pin.length === 0) return 0
        if (pin.length < 4) return 1
        if (pin.length <= 5) return 2
        if (pin.length <= 8) return 3
        if (pin.length <= 11) return 4
        return 5
    }

    readonly property color levelColor: {
        switch (level) {
        case 1:
        case 2:
            return Theme.error
        case 3:
            return Theme.warning
        case 4:
            return Theme.accent
        case 5:
            return Theme.accentHover
        default:
            return Theme.textHint
        }
    }

    readonly property string levelLabel: {
        switch (level) {
        case 1:
            return qsTr("Слишком короткий")
        case 2:
            return qsTr("Очень слабый")
        case 3:
            return qsTr("Средний")
        case 4:
            return qsTr("Надёжный")
        case 5:
            return qsTr("Параноидальный")
        default:
            return qsTr("введите PIN")
        }
    }

    readonly property string attackIcon: {
        switch (level) {
        case 1: return "✗"
        case 2:
            return "⚠"
        case 3:
            return "◉"
        case 4:
            return "✓"
        case 5:
            return "✦"
        default:
            return "·"
        }
    }

    readonly property string confirmText: {
        if (pin.length === 0) return qsTr("Подтвердить")
        if (pin.length < minDigits) return qsTr("Минимум %1 цифры").arg(minDigits)
        return qsTr("Подтвердить PIN")
    }

    signal back()
    signal accepted(string pin)

    onPinChanged: {
        const sanitized = sanitizePin(pin)
        if (sanitized !== pin) {
            pin = sanitized
            return
        }
        if (pinInput.text !== pin)
            pinInput.text = pin
    }

    function sanitizePin(value) {
        return String(value).replace(/[^0-9]/g, "").slice(0, maxDigits)
    }

    function levelRgba(alpha) {
        return Qt.rgba(levelColor.r, levelColor.g, levelColor.b, alpha)
    }

    function appendDigit(digit) {
        pin = sanitizePin(pin + digit)
    }

    function removeDigit() {
        if (pin.length > 0)
            pin = pin.slice(0, -1)
    }

    function confirmPin() {
        if (pin.length < minDigits)
            return

        root.accepted(pin)
    }

    function fmtTime(secs) {
        if (secs <= 0) return "-"
        if (secs < 60) return qsTr("%1 сек").arg(Math.round(secs))
        if (secs < 3600) return qsTr("%1 мин").arg(Math.round(secs / 60))
        if (secs < 86400) return qsTr("%1 ч").arg((secs / 3600).toFixed(1))
        if (secs < 86400 * 365) return qsTr("%1 сут").arg(Math.round(secs / 86400))

        var y = secs / (86400 * 365.25)
        if (y < 1000) return qsTr("%1 лет").arg(Math.round(y))
        if (y < 1e6) return qsTr("%1 тыс. лет").arg(Math.round(y / 1000))
        if (y < 1e9) return qsTr("%1 млн. лет").arg(Math.round(y / 1e6))
        return qsTr("практически вечность")
    }

    function fmtCombo(n) {
        if (n === 0) return "-"
        if (n < 1e3) return n.toString()
        if (n < 1e6) return (n / 1e3).toFixed(0) + "K"
        if (n < 1e9) return (n / 1e6).toFixed(0) + "M"
        if (n < 1e12) return (n / 1e9).toFixed(0) + "B"
        return (n / 1e12).toFixed(0) + "T+"
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        ParaHeader {
            Layout.fillWidth: true
            title: root.title
            showBack: root.showBack
            onBackClicked: root.back()
        }

        Flickable {
            id: pinFlick
            Layout.fillWidth: true
            Layout.fillHeight: true
            // Контент-область не ниже вьюпорта — для вертикального центрирования
            // короткого контента; на узком экране растёт под скролл.
            contentHeight: Math.max(pinFlick.height, contentCol.implicitHeight + root.contentMargin * 2)
            boundsBehavior: Flickable.StopAtBounds
            clip: true

            ColumnLayout {
                id: contentCol
                // По горизонтали — по центру с ограничением ширины; по ВЕРТИКАЛИ —
                // по центру вьюпорта (тянуться вверх неудобно). Контент выше экрана
                // — прижимаемся к верху и скроллим.
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
                    hasError: root.pin.length > 0 && root.pin.length < root.minDigits
                    errorText: ""

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
                    visible: root.showStrength
                    color: Theme.bgCard
                    border.color: Theme.border
                    border.width: 1
                    radius: Theme.radiusMd
                    implicitHeight: strengthCol.implicitHeight + 28

                    ColumnLayout {
                        id: strengthCol
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: 14
                        spacing: 10

                        RowLayout {
                            Layout.fillWidth: true

                            Text {
                                text: qsTr("Надёжность")
                                color: Theme.textSecondary
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSm
                            }

                            Item { Layout.fillWidth: true }

                            Rectangle {
                                radius: 20
                                color: root.levelRgba(0.15)
                                implicitWidth: badgeText.implicitWidth + 18
                                implicitHeight: 22

                                Text {
                                    id: badgeText
                                    anchors.centerIn: parent
                                    text: root.levelLabel
                                    color: root.levelColor
                                    font.family: Theme.fontFamily
                                    font.pixelSize: 12
                                    font.weight: Font.DemiBold

                                    Behavior on color { ColorAnimation { duration: 200 } }
                                }

                                Behavior on color { ColorAnimation { duration: 200 } }
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 4
                            radius: 2
                            color: Theme.separator

                            Rectangle {
                                width: parent.width * root.meterPct
                                height: parent.height
                                radius: parent.radius
                                color: root.levelColor

                                Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                                Behavior on color { ColorAnimation { duration: 200 } }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8

                            Rectangle {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 52
                                radius: Theme.radiusSm
                                color: Theme.bgInput

                                ColumnLayout {
                                    anchors.fill: parent
                                    anchors.margins: 10
                                    spacing: 3

                                    Text {
                                        text: qsTr("КОМБИНАЦИЙ")
                                        color: Theme.textHint
                                        font.family: Theme.fontFamily
                                        font.pixelSize: 10
                                        font.capitalization: Font.AllUppercase
                                        font.letterSpacing: 0.5
                                    }

                                    Text {
                                        text: root.fmtCombo(root.combinations)
                                        color: root.levelColor
                                        font.family: Theme.monoFamily
                                        font.pixelSize: 14
                                        font.weight: Font.DemiBold

                                        Behavior on color { ColorAnimation { duration: 200 } }
                                    }
                                }
                            }

                            Rectangle {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 52
                                radius: Theme.radiusSm
                                color: Theme.bgInput

                                ColumnLayout {
                                    anchors.fill: parent
                                    anchors.margins: 10
                                    spacing: 3

                                    Text {
                                        text: qsTr("ЭНТРОПИЯ")
                                        color: Theme.textHint
                                        font.family: Theme.fontFamily
                                        font.pixelSize: 10
                                        font.capitalization: Font.AllUppercase
                                        font.letterSpacing: 0.5
                                    }

                                    Text {
                                        text: root.pin.length > 0 ? qsTr("%1 бит").arg(root.entropy.toFixed(1)) : "-"
                                        color: root.levelColor
                                        font.family: Theme.monoFamily
                                        font.pixelSize: 14
                                        font.weight: Font.DemiBold

                                        Behavior on color { ColorAnimation { duration: 200 } }
                                    }
                                }
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 50
                            radius: Theme.radiusSm
                            color: root.levelRgba(0.07)

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 12
                                anchors.rightMargin: 12
                                spacing: 10

                                Text {
                                    text: root.attackIcon
                                    font.pixelSize: 18
                                    color: Theme.success
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 2

                                    Text {
                                        Layout.fillWidth: true
                                        text: qsTr("Время взлома (1 GPU, Argon2id)")
                                        color: root.levelRgba(0.7)
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontXs
                                        elide: Text.ElideRight
                                    }

                                    Text {
                                        Layout.fillWidth: true
                                        text: root.pin.length > 0
                                            ? qsTr("В среднем: %1  ·  Полный: %2").arg(root.fmtTime(root.attackSecsAvg)).arg(root.fmtTime(root.attackSecsFull))
                                            : qsTr("Введите PIN для оценки")
                                        color: Theme.textPrimary
                                        font.family: Theme.fontFamily
                                        font.pixelSize: 12
                                        font.weight: Font.Medium
                                        elide: Text.ElideRight
                                    }
                                }
                            }
                        }
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
                                enabled: keypadButton.modelData !== ""
                                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                onClicked: keypadButton.modelData === "backspace" ? root.removeDigit() : root.appendDigit(keypadButton.modelData)
                            }
                        }
                    }
                }

                Text {
                    Layout.fillWidth: true
                    visible: root.banner.length > 0
                    text: root.banner
                    color: Theme.error
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSm
                    font.weight: Font.DemiBold
                    wrapMode: Text.WordWrap
                    horizontalAlignment: Text.AlignHCenter
                }

                ParaButton {
                    Layout.fillWidth: true
                    text: root.confirmText
                    enabled: root.pin.length >= root.minDigits
                    onClicked: root.confirmPin()
                }
            }
        }
    }
}
