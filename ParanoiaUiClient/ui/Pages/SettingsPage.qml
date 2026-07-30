import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import ParanoiaUiClient

Rectangle {
    id: root
    color: Theme.bgPrimary

    signal back()
    signal openMasking()
    signal openChangePin()
    signal openVersionInfo()
    signal openDataManagement()

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        ParaHeader {
            Layout.fillWidth: true
            title: qsTr("Настройки")
            onBackClicked: root.back()
        }

        Flickable {
            id: formFlick
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentHeight: Math.max(formFlick.height, contentCol.implicitHeight + 48)
            contentWidth: width
            boundsBehavior: Flickable.StopAtBounds
            clip: true

            ColumnLayout {
                id: contentCol
                width: Math.min(parent.width - 48, 560)
                anchors.horizontalCenter: parent.horizontalCenter
                y: 24
                spacing: 16

                // ── Язык приложения ──────────────────────────────────────
                Text {
                    Layout.fillWidth: true
                    text: qsTr("Язык приложения")
                    color: Theme.textPrimary
                    font.pixelSize: Theme.fontMd
                    font.family: Theme.fontFamily
                    font.weight: Font.DemiBold
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Repeater {
                        model: I18n.availableLanguages

                        delegate: Rectangle {
                            required property var modelData
                            Layout.fillWidth: true
                            Layout.preferredHeight: 36
                            radius: height / 2
                            readonly property bool current: I18n.language === modelData.code
                            color: current ? Theme.accent
                                           : (langArea.containsMouse ? Theme.bgCard : Theme.bgSecondary)
                            border.width: 1
                            border.color: current ? Theme.accent : Theme.border
                            Behavior on color { ColorAnimation { duration: 120 } }

                            Text {
                                anchors.centerIn: parent
                                text: modelData.name
                                color: parent.current ? Theme.bgDark : Theme.textPrimary
                                font.pixelSize: Theme.fontSm
                                font.family: Theme.fontFamily
                                font.weight: parent.current ? Font.DemiBold : Font.Normal
                            }

                            MouseArea {
                                id: langArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: I18n.setLanguage(parent.modelData.code)
                            }
                        }
                    }
                }

                // ── Фоновые уведомления ──────────────────────────────────
                Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.separator }

                Text {
                    Layout.fillWidth: true
                    text: qsTr("Фоновые уведомления")
                    color: Theme.textPrimary
                    font.pixelSize: Theme.fontMd
                    font.family: Theme.fontFamily
                    font.weight: Font.DemiBold
                }

                SegmentedToggle {
                    Layout.fillWidth: true
                    options: PollMode.availablePollModes
                    currentCode: PollMode.pollMode
                    onSelected: function (code) { PollMode.setPollMode(code) }
                }

                // Предупреждение для режима "off"
                Text {
                    Layout.fillWidth: true
                    visible: PollMode.pollMode === "off"
                    text: qsTr("Уведомления и звонки приходят только при открытом приложении")
                    color: Theme.warning
                    font.pixelSize: Theme.fontXs
                    font.family: Theme.fontFamily
                    wrapMode: Text.WordWrap
                }

                // ── Прочие настройки ─────────────────────────────────────
                Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.separator }

                ParaButton {
                    Layout.fillWidth: true
                    text: qsTr("Маскировка трафика")
                    secondary: true
                    onClicked: root.openMasking()
                }

                ParaButton {
                    Layout.fillWidth: true
                    text: qsTr("Сменить PIN-код")
                    secondary: true
                    onClicked: root.openChangePin()
                }

                ParaButton {
                    Layout.fillWidth: true
                    text: qsTr("Версия приложения")
                    secondary: true
                    onClicked: root.openVersionInfo()
                }

                ParaButton {
                    Layout.fillWidth: true
                    text: qsTr("Управление данными")
                    secondary: true
                    onClicked: root.openDataManagement()
                }

                Item { Layout.preferredHeight: 8 }
            }
        }
    }
}
