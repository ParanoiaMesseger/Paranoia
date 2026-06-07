import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import ParanoiaUiClient

// Трёхшаговый flow смены PIN. На каждом шаге показываем SetPin — это даёт
// единый UX (тот же keypad, тот же inputMethodHints) и переиспользует
// strength-визуализацию из SetPin для шага «новый PIN».
Rectangle {
    id: root
    implicitWidth: 420
    implicitHeight: 780
    width: parent ? parent.width : implicitWidth
    height: parent ? parent.height : implicitHeight
    color: Theme.bgPrimary

    // 0 — ввод текущего PIN, 1 — ввод нового PIN, 2 — подтверждение нового PIN.
    property int step: 0
    property string oldPin: ""
    property string newPin: ""
    property bool busy: false
    property string errorText: ""

    signal back()
    signal changed()

    Timer {
        id: changePinTimer
        interval: 80
        repeat: false
        onTriggered: Backend.vaultChangePin(root.oldPin, root.newPin)
    }

    Connections {
        target: Backend
        function onVaultChangePinResult(result) {
            changePinTimer.stop()
            root.busy = false
            switch (result) {
                case 0:
                    root.errorText = ""
                    root.changed()
                    return
                case 1:
                    // Старый PIN не подошёл — обратно на шаг 0 с баннером.
                    root.errorText = qsTr("Неверный текущий PIN")
                    root.oldPin = ""
                    root.newPin = ""
                    root.step = 0
                    return
                default:
                    root.errorText = qsTr("Не удалось сменить PIN. Подробности — в логах.")
            }
        }
    }

    StackLayout {
        anchors.fill: parent
        currentIndex: root.step
        enabled: !root.busy

        // Шаг 0: текущий PIN. Без strength-панели — это просто авторизация.
        SetPin {
            title: qsTr("Введите текущий PIN-код")
            showStrength: false
            showBack: true
            banner: root.step === 0 ? root.errorText : ""
            onBack: root.back()
            onAccepted: function(pin) {
                root.oldPin = pin
                root.errorText = ""
                root.step = 1
            }
        }

        // Шаг 1: новый PIN. Полная strength-визуализация — пользователь
        // осознанно выбирает длину/стойкость.
        SetPin {
            title: qsTr("Установите новый PIN-код")
            showStrength: true
            showBack: true
            onBack: { root.step = 0 }
            onAccepted: function(pin) {
                root.newPin = pin
                root.step = 2
            }
        }

        // Шаг 2: подтверждение. Без strength-панели; на mismatch — баннер.
        SetPin {
            title: qsTr("Подтвердите новый PIN-код")
            showStrength: false
            showBack: true
            banner: root.step === 2 ? root.errorText : ""
            onBack: { root.step = 1; root.errorText = "" }
            onAccepted: function(pin) {
                if (pin !== root.newPin) {
                    root.errorText = qsTr("PIN'ы не совпадают")
                    return
                }
                if (root.busy) return
                root.busy = true
                root.errorText = ""
                changePinTimer.restart()
            }
        }
    }

    // Busy-overlay поверх stack'а во время Argon2 + rekey. Перехватывает
    // тапы (через MouseArea), чтобы пользователь не мог нажимать кнопки
    // под полупрозрачной заливкой.
    Rectangle {
        anchors.fill: parent
        visible: root.busy
        color: Qt.rgba(0, 0, 0, 0.55)
        z: 1000

        MouseArea {
            anchors.fill: parent
            // Глотаем все события — пока идёт rekey ничего нажимать нельзя.
            onClicked: {}
            onPressed: {}
            onWheel: function(event) { event.accepted = true }
        }

        Column {
            anchors.centerIn: parent
            spacing: 14
            BusyIndicator {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 48; height: 48
                running: root.busy
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: qsTr("Перешифровка профилей…")
                color: Theme.textPrimary
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontMd
                font.weight: Font.DemiBold
            }
        }
    }
}
