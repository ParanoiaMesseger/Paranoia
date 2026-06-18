import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import ParanoiaUiClient

Rectangle {
    id: root
    color: Theme.bgPrimary
    signal back()

    property var breakdown: []
    property real totalBytes: 0
    property bool destructing: false
    property bool clearingCache: false

    function refresh() {
        breakdown = Backend.storageBreakdown()
        var t = 0
        for (var i = 0; i < breakdown.length; ++i) t += breakdown[i].bytes
        totalBytes = t
        pie.requestPaint()
    }
    function fmtBytes(b) {
        b = b || 0
        if (b < 1024) return b + " Б"
        var u = ["КБ", "МБ", "ГБ", "ТБ"]; var i = -1
        do { b /= 1024; ++i } while (b >= 1024 && i < u.length - 1)
        return (b < 10 ? b.toFixed(1) : Math.round(b)) + " " + u[i]
    }

    Component.onCompleted: refresh()

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ── Header ──
        Rectangle {
            Layout.fillWidth: true
            height: 56
            color: Theme.bgDark
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 16
                spacing: 8
                Rectangle {
                    width: 40; height: 40; radius: Theme.radiusSm
                    color: backArea.containsMouse ? Theme.bgCard : "transparent"
                    AppIcon {
                        anchors.centerIn: parent
                        width: 24; height: 24; name: "chevronLeft"
                        iconColor: Theme.accentHover; strokeWidth: 2.2
                    }
                    MouseArea {
                        id: backArea
                        anchors.fill: parent; hoverEnabled: true
                        enabled: !root.destructing
                        onClicked: root.back()
                    }
                }
                Text {
                    Layout.fillWidth: true
                    text: qsTr("Управление данными")
                    color: Theme.textPrimary
                    font.pixelSize: Theme.fontLg
                    font.family: Theme.fontFamily
                    font.weight: Font.DemiBold
                }
            }
        }

        ScrollView {
            id: dataScroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ScrollBar.vertical: AppScrollBar { policy: ScrollBar.AsNeeded }
            contentWidth: availableWidth

            ColumnLayout {
                // Жёстко ограничиваем ширину вьюпортом → Text с fillWidth переносится
                // (иначе длинный Text задаёт implicitWidth и весь столбец вылазит).
                width: dataScroll.availableWidth
                spacing: 14

                // ── Память ──
                Text {
                    Layout.leftMargin: 16; Layout.topMargin: 14
                    text: qsTr("Использование памяти")
                    color: Theme.textPrimary
                    font.pixelSize: Theme.fontMd
                    font.family: Theme.fontFamily
                    font.weight: Font.DemiBold
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 16; Layout.rightMargin: 16
                    spacing: 18

                    // Кольцевая диаграмма.
                    Item {
                        Layout.preferredWidth: 140
                        Layout.preferredHeight: 140
                        Canvas {
                            id: pie
                            anchors.fill: parent
                            onPaint: {
                                var ctx = getContext("2d")
                                ctx.reset()
                                var cx = width / 2, cy = height / 2
                                var r = Math.min(cx, cy) - 4, inner = r * 0.6
                                var total = root.totalBytes
                                if (total <= 0) {
                                    ctx.beginPath(); ctx.arc(cx, cy, r, 0, 2 * Math.PI)
                                    ctx.arc(cx, cy, inner, 0, 2 * Math.PI, true)
                                    ctx.fillStyle = Theme.bgInput; ctx.fill()
                                    return
                                }
                                var a0 = -Math.PI / 2
                                for (var i = 0; i < root.breakdown.length; ++i) {
                                    var frac = root.breakdown[i].bytes / total
                                    if (frac <= 0) continue
                                    var a1 = a0 + frac * 2 * Math.PI
                                    ctx.beginPath()
                                    ctx.moveTo(cx, cy)
                                    ctx.arc(cx, cy, r, a0, a1)
                                    ctx.closePath()
                                    ctx.fillStyle = root.breakdown[i].color
                                    ctx.fill()
                                    a0 = a1
                                }
                                // вырез центра
                                ctx.beginPath(); ctx.arc(cx, cy, inner, 0, 2 * Math.PI)
                                ctx.fillStyle = Theme.bgPrimary; ctx.fill()
                            }
                        }
                        Column {
                            anchors.centerIn: parent
                            spacing: 0
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: root.fmtBytes(root.totalBytes)
                                color: Theme.textPrimary
                                font.pixelSize: Theme.fontMd
                                font.family: Theme.fontFamily
                                font.weight: Font.DemiBold
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: qsTr("всего")
                                color: Theme.textSecondary
                                font.pixelSize: Theme.fontXs
                                font.family: Theme.fontFamily
                            }
                        }
                    }

                    // Легенда.
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Repeater {
                            model: root.breakdown
                            delegate: RowLayout {
                                required property var modelData
                                Layout.fillWidth: true
                                spacing: 8
                                Rectangle {
                                    width: 12; height: 12; radius: 3
                                    color: modelData.color
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: modelData.label
                                    color: Theme.textPrimary
                                    font.pixelSize: Theme.fontSm
                                    font.family: Theme.fontFamily
                                }
                                Text {
                                    text: root.fmtBytes(modelData.bytes)
                                    color: Theme.textSecondary
                                    font.pixelSize: Theme.fontSm
                                    font.family: Theme.fontFamily
                                }
                            }
                        }
                    }
                }

                RowLayout {
                    Layout.leftMargin: 16
                    Layout.rightMargin: 16
                    Layout.fillWidth: true
                    spacing: 10
                    ParaButton {
                        text: qsTr("Обновить")
                        secondary: true
                        implicitWidth: 130
                        implicitHeight: 38
                        enabled: !root.clearingCache
                        onClicked: root.refresh()
                    }
                    ParaButton {
                        text: root.clearingCache ? qsTr("Очистка…") : qsTr("Очистить кэш")
                        secondary: true
                        implicitWidth: 150
                        implicitHeight: 38
                        enabled: !root.clearingCache
                        onClicked: { root.clearingCache = true; Backend.clearCaches() }
                    }
                }

                Rectangle { Layout.fillWidth: true; Layout.leftMargin: 16; Layout.rightMargin: 16; height: 1; color: Theme.separator }

                // ── Опасная зона ──
                Text {
                    Layout.leftMargin: 16
                    text: qsTr("Самоликвидация")
                    color: Theme.error
                    font.pixelSize: Theme.fontMd
                    font.family: Theme.fontFamily
                    font.weight: Font.DemiBold
                }
                Text {
                    Layout.fillWidth: true
                    Layout.leftMargin: 16; Layout.rightMargin: 16
                    wrapMode: Text.Wrap
                    text: qsTr("Безвозвратно удаляет все диалоги этого устройства со всех серверов загруженных профилей, затем затирает локальное хранилище по ГОСТ (3 прохода: случайные данные, единицы, нули) и уничтожает ключ хранилища (crypto-erase). После — приложение закроется как при первой установке.")
                    color: Theme.textSecondary
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                }
                Text {
                    Layout.fillWidth: true
                    Layout.leftMargin: 16; Layout.rightMargin: 16
                    Layout.bottomMargin: 18
                    wrapMode: Text.Wrap
                    text: qsTr("⚠️ На flash-памяти (телефоны/SSD) перезапись не гарантирует физического стирания из-за wear-leveling — реальную невосстановимость даёт уничтожение ключа шифрования.")
                    color: Theme.textHint
                    font.pixelSize: Theme.fontXs
                    font.family: Theme.fontFamily
                }
                ParaButton {
                    Layout.leftMargin: 16
                    Layout.bottomMargin: 24
                    text: qsTr("Самоликвидация")
                    destructive: true
                    onClicked: confirmPopup.open()
                }
            }
        }
    }

    // ── Подтверждение ──
    Popup {
        id: confirmPopup
        anchors.centerIn: Overlay.overlay
        width: Math.min(360, root.width - 40)
        modal: true
        padding: 18
        closePolicy: Popup.CloseOnEscape
        background: Rectangle { color: Theme.bgCard; radius: Theme.radiusLg; border.width: 1; border.color: Theme.error }
        ColumnLayout {
            anchors.fill: parent
            spacing: 14
            Text {
                Layout.fillWidth: true
                text: qsTr("Уничтожить все данные?")
                color: Theme.error
                font.pixelSize: Theme.fontLg
                font.family: Theme.fontFamily
                font.weight: Font.DemiBold
            }
            Text {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: qsTr("Это действие НЕОБРАТИМО. Все диалоги, профили, ключи и вложения на этом устройстве будут удалены, а диалоги — стёрты с серверов.")
                color: Theme.textPrimary
                font.pixelSize: Theme.fontSm
                font.family: Theme.fontFamily
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                ParaButton {
                    Layout.fillWidth: true
                    text: qsTr("Отмена")
                    secondary: true
                    onClicked: confirmPopup.close()
                }
                ParaButton {
                    Layout.fillWidth: true
                    text: qsTr("Уничтожить")
                    destructive: true
                    onClicked: {
                        confirmPopup.close()
                        root.destructing = true
                        Backend.selfDestruct()
                    }
                }
            }
        }
    }

    // ── Прогресс уничтожения (модально, без отмены) ──
    Popup {
        id: progressPopup
        anchors.centerIn: Overlay.overlay
        width: Math.min(340, root.width - 40)
        modal: true
        padding: 22
        closePolicy: Popup.NoAutoClose
        visible: root.destructing
        background: Rectangle { color: Theme.bgCard; radius: Theme.radiusLg; border.width: 1; border.color: Theme.border }
        ColumnLayout {
            anchors.fill: parent
            spacing: 14
            BusyIndicator { Layout.alignment: Qt.AlignHCenter; running: root.destructing; width: 36; height: 36 }
            Text {
                id: progressLabel
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: qsTr("Уничтожение данных…")
                color: Theme.textPrimary
                font.pixelSize: Theme.fontMd
                font.family: Theme.fontFamily
            }
        }
    }

    Connections {
        target: Backend
        function onSelfDestructProgress(phase, fraction) {
            progressLabel.text = phase === "server"
                ? qsTr("Удаление диалогов с серверов… %1%").arg(Math.round(fraction * 100))
                : qsTr("Затирание хранилища… %1%").arg(Math.round(fraction * 100))
        }
        function onSelfDestructFinished() {
            Qt.quit()
        }
        function onCachesCleared() {
            root.clearingCache = false
            root.refresh()
        }
    }
}
