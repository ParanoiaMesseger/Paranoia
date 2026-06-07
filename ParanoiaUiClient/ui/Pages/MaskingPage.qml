import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import ParanoiaUiClient

// Управление маскировкой трафика активного профиля.
//   commercial/corporate — профиль раздаётся нодой (подписанный), сверяется и
//                          применяется при входе; здесь — ручное «Обновить».
//   private              — нет API: применение профиля из файла (с подписью,
//                          если задан доверенный ключ, иначе с предупреждением).
Rectangle {
    id: root
    color: Theme.bgPrimary

    signal back()

    property var status: ({})
    property string pendingUnsignedPath: ""
    property string feedback: ""
    property bool feedbackError: false

    readonly property string tariff:   status.tariff || ""
    readonly property bool   hasUrl:    status.hasUrl || false
    readonly property string state:     status.state || ""
    readonly property string profileName: status.profileName || ""

    function refresh() { root.status = Backend.maskingStatus() }

    function stateText(s) {
        switch (s) {
            case "checking": return qsTr("сверка с нодой…")
            case "verified": return qsTr("сверено, без изменений ✓")
            case "updated":  return qsTr("обновлено и применено ✓")
            case "error":    return qsTr("ошибка сверки")
            default:         return qsTr("встроенная маска")
        }
    }
    function stateColor(s) {
        if (s === "verified" || s === "updated") return Theme.success
        if (s === "error") return Theme.error
        return Theme.textSecondary
    }

    Component.onCompleted: root.refresh()

    Connections {
        target: Backend
        function onMaskingStateChanged() { root.refresh() }
        function onMaskingApplied(ok, message) {
            root.feedbackError = !ok
            root.feedback = message
        }
    }

    ParaFileDialog {
        id: profileFileDialog
        title: qsTr("Выбрать профиль маскировки")
        mode: "open"
        nameFilters: [qsTr("Профиль маскировки (*.json)"), qsTr("JSON (*.json)"), qsTr("Все файлы (*)")]
        onAccepted: {
            const path = Backend.urlToLocalPath(selectedFile)
            root.pendingUnsignedPath = ""
            const res = Backend.applyMaskingFromFile(path, false)
            if (res.ok) {
                root.feedbackError = false
                root.feedback = qsTr("Профиль применён: %1").arg(res.profileName || "")
            } else if (res.unsigned) {
                // Профиль без подписи — спросить подтверждение.
                root.pendingUnsignedPath = path
                root.feedbackError = true
                root.feedback = res.error
            } else {
                root.feedbackError = true
                root.feedback = res.error || qsTr("Ошибка применения")
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        ParaHeader {
            Layout.fillWidth: true
            title: qsTr("Маскировка трафика")
            onBackClicked: root.back()
        }

        Flickable {
            id: maskFlick
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentHeight: Math.max(maskFlick.height, contentCol.implicitHeight + 48)
            clip: true

            ColumnLayout {
                id: contentCol
                width: Math.min(parent.width - 48, 560)
                anchors.horizontalCenter: parent.horizontalCenter
                // По вертикали — по центру вьюпорта (высокий контент — от верха).
                y: Math.max(24, (maskFlick.height - implicitHeight) / 2)
                spacing: 16

                Item { Layout.preferredHeight: 8 }

                // ── Статус ───────────────────────────────────────────
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: statusCol.implicitHeight + 24
                    radius: Theme.radiusMd
                    color: Theme.bgSecondary
                    border.width: 1
                    border.color: Theme.border

                    ColumnLayout {
                        id: statusCol
                        anchors.fill: parent
                        anchors.margins: 12
                        spacing: 6

                        Text {
                            text: qsTr("Текущая маска")
                            color: Theme.textPrimary
                            font.pixelSize: Theme.fontMd
                            font.family: Theme.fontFamily
                            font.weight: Font.DemiBold
                        }
                        Text {
                            Layout.fillWidth: true
                            text: root.profileName.length > 0 ? root.profileName : "—"
                            color: Theme.textSecondary
                            font.pixelSize: Theme.fontSm
                            font.family: Theme.fontFamily
                            elide: Text.ElideRight
                        }
                        Text {
                            text: root.stateText(root.state)
                            color: root.stateColor(root.state)
                            font.pixelSize: Theme.fontSm
                            font.family: Theme.fontFamily
                            font.weight: Font.DemiBold
                        }
                    }
                }

                // ── Раздача нодой (commercial/corporate) ─────────────
                Text {
                    Layout.fillWidth: true
                    visible: root.hasUrl
                    text: qsTr("Маскировка раздаётся нодой и сверяется при каждом входе. При смене профиля на сервере он применяется автоматически.")
                    color: Theme.textSecondary
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    wrapMode: Text.WordWrap
                }

                ParaButton {
                    Layout.fillWidth: true
                    visible: root.hasUrl
                    text: root.state === "checking" ? qsTr("Обновление…") : qsTr("Обновить с ноды")
                    enabled: root.state !== "checking"
                    onClicked: {
                        root.feedback = ""
                        Backend.syncMaskingFromNode()
                    }
                }

                // ── Применение из файла (частное развёртывание) ──────
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 1
                    color: Theme.border
                }

                Text {
                    Layout.fillWidth: true
                    text: qsTr("Note: Для selfhosted-сервера можно применить профиль из файла без проверки подписи.")
                    color: Theme.textSecondary
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    wrapMode: Text.WordWrap
                }

                ParaButton {
                    Layout.fillWidth: true
                    secondary: true
                    text: qsTr("Загрузить из файла")
                    onClicked: {
                        root.feedback = ""
                        root.pendingUnsignedPath = ""
                        profileFileDialog.open()
                    }
                }

                // Баннер подтверждения применения без подписи.
                Rectangle {
                    Layout.fillWidth: true
                    visible: root.pendingUnsignedPath.length > 0
                    implicitHeight: unsignedCol.implicitHeight + 20
                    radius: Theme.radiusSm
                    color: Theme.errorBg
                    border.width: 1
                    border.color: Theme.error

                    ColumnLayout {
                        id: unsignedCol
                        anchors.fill: parent
                        anchors.margins: 10
                        spacing: 8

                        Text {
                            Layout.fillWidth: true
                            text: qsTr("Профиль без подписи. Применять только если вы доверяете источнику файла.")
                            color: Theme.error
                            font.pixelSize: Theme.fontSm
                            font.family: Theme.fontFamily
                            wrapMode: Text.WordWrap
                        }
                        ParaButton {
                            Layout.fillWidth: true
                            implicitHeight: 36
                            text: qsTr("Применить без проверки")
                            onClicked: {
                                const res = Backend.applyMaskingFromFile(root.pendingUnsignedPath, true)
                                root.pendingUnsignedPath = ""
                                root.feedbackError = !res.ok
                                root.feedback = res.ok ? (qsTr("Профиль применён: %1").arg(res.profileName || ""))
                                                       : (res.error || qsTr("Ошибка применения"))
                            }
                        }
                        ParaButton {
                            Layout.fillWidth: true
                            implicitHeight: 36
                            secondary: true
                            text: qsTr("Отмена")
                            onClicked: { root.pendingUnsignedPath = ""; root.feedback = "" }
                        }
                    }
                }

                // ── Сброс ────────────────────────────────────────────
                ParaButton {
                    Layout.fillWidth: true
                    secondary: true
                    text: qsTr("Вернуть встроенную маску")
                    onClicked: {
                        const res = Backend.resetMasking()
                        root.feedbackError = !res.ok
                        root.feedback = res.ok ? qsTr("Возвращена встроенная маска") : (res.error || qsTr("Ошибка"))
                    }
                }

                Text {
                    Layout.fillWidth: true
                    visible: root.feedback.length > 0
                    text: root.feedback
                    color: root.feedbackError ? Theme.error : Theme.success
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                }

                Item { Layout.preferredHeight: 16 }
            }
        }
    }
}
