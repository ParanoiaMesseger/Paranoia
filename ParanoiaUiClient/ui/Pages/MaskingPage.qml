import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Dialogs
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
            case "checking": return "сверка с нодой…"
            case "verified": return "сверено, без изменений ✓"
            case "updated":  return "обновлено и применено ✓"
            case "error":    return "ошибка сверки"
            default:         return "встроенная маска"
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

    FileDialog {
        id: profileFileDialog
        title: "Выбрать профиль маскировки"
        fileMode: FileDialog.OpenFile
        nameFilters: ["Профиль маскировки (*.json)", "JSON (*.json)", "Все файлы (*)"]
        onAccepted: {
            const path = Backend.urlToLocalPath(selectedFile)
            root.pendingUnsignedPath = ""
            const res = Backend.applyMaskingFromFile(path, false)
            if (res.ok) {
                root.feedbackError = false
                root.feedback = "Профиль применён: " + (res.profileName || "")
            } else if (res.unsigned) {
                // Профиль без подписи — спросить подтверждение.
                root.pendingUnsignedPath = path
                root.feedbackError = true
                root.feedback = res.error
            } else {
                root.feedbackError = true
                root.feedback = res.error || "Ошибка применения"
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        ParaHeader {
            Layout.fillWidth: true
            title: "Маскировка трафика"
            onBackClicked: root.back()
        }

        Flickable {
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentHeight: contentCol.implicitHeight + 32
            clip: true

            ColumnLayout {
                id: contentCol
                width: parent.width
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: 24
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
                            text: "Текущая маска"
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
                    text: "Маскировка раздаётся нодой и сверяется при каждом входе. При смене профиля на сервере он применяется автоматически."
                    color: Theme.textSecondary
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    wrapMode: Text.WordWrap
                }

                ParaButton {
                    Layout.fillWidth: true
                    visible: root.hasUrl
                    text: root.state === "checking" ? "Обновление…" : "Обновить с ноды"
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
                    text: "Note: Для selfhosted-сервера можно применить профиль из файла без проверки подписи."
                    color: Theme.textSecondary
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    wrapMode: Text.WordWrap
                }

                ParaButton {
                    Layout.fillWidth: true
                    secondary: true
                    text: "Загрузить из файла"
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
                            text: "Профиль без подписи. Применять только если вы доверяете источнику файла."
                            color: Theme.error
                            font.pixelSize: Theme.fontSm
                            font.family: Theme.fontFamily
                            wrapMode: Text.WordWrap
                        }
                        ParaButton {
                            Layout.fillWidth: true
                            implicitHeight: 36
                            text: "Применить без проверки"
                            onClicked: {
                                const res = Backend.applyMaskingFromFile(root.pendingUnsignedPath, true)
                                root.pendingUnsignedPath = ""
                                root.feedbackError = !res.ok
                                root.feedback = res.ok ? ("Профиль применён: " + (res.profileName || ""))
                                                       : (res.error || "Ошибка применения")
                            }
                        }
                        ParaButton {
                            Layout.fillWidth: true
                            implicitHeight: 36
                            secondary: true
                            text: "Отмена"
                            onClicked: { root.pendingUnsignedPath = ""; root.feedback = "" }
                        }
                    }
                }

                // ── Сброс ────────────────────────────────────────────
                ParaButton {
                    Layout.fillWidth: true
                    secondary: true
                    text: "Вернуть встроенную маску"
                    onClicked: {
                        const res = Backend.resetMasking()
                        root.feedbackError = !res.ok
                        root.feedback = res.ok ? "Возвращена встроенная маска" : (res.error || "Ошибка")
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
