import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.VectorImage
import QtCore
import ParanoiaUiClient

Rectangle {
    id: root
    color: Theme.bgPrimary
    signal back()

    property string releasesUrl: VersionInfo.releasePageUrl

    Component.onCompleted: VersionInfo.checkForUpdates()

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

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
                    width: 40
                    height: 40
                    radius: Theme.radiusSm
                    color: backArea.containsMouse ? Theme.bgCard : "transparent"
                    AppIcon {
                        anchors.centerIn: parent
                        width: 24
                        height: 24
                        name: "chevronLeft"
                        iconColor: Theme.accentHover
                        strokeWidth: 2.2
                    }
                    MouseArea {
                        id: backArea
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: root.back()
                    }
                }

                Text {
                    Layout.fillWidth: true
                    text: qsTr("Версия приложения")
                    color: Theme.textPrimary
                    font.pixelSize: Theme.fontLg
                    font.family: Theme.fontFamily
                    font.weight: Font.DemiBold
                }
            }
        }

        ScrollView {
            id: versionScroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: availableWidth
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            // Вертикальное центрирование: короткий контент по центру вьюпорта
            // (не липнет к верху); высокий — обычный скролл (padding → 0).
            topPadding: Math.max(0, (height - versionCol.implicitHeight) / 2)

            ColumnLayout {
                id: versionCol
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.min(versionScroll.availableWidth - 32, 560)
                spacing: 14

                Item { Layout.preferredHeight: 20 }

                VectorImage {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.leftMargin: 20
                    Layout.rightMargin: 20
                    Layout.preferredWidth: 220
                    Layout.preferredHeight: 64
                    source: "qrc:/logo_lockup_animated.svg"
                    fillMode: VectorImage.PreserveAspectFit
                    preferredRendererType: VectorImage.CurveRenderer
                    animations.loops: Animation.Infinite
                    assumeTrustedSource: true
                }

                Text {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.leftMargin: 20
                    Layout.rightMargin: 20
                    text: qsTr("Версия: ") + Qt.application.version
                    color: Theme.textPrimary
                    font.pixelSize: Theme.fontMd
                    font.family: Theme.fontFamily
                }

                Text {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.leftMargin: 20
                    Layout.rightMargin: 20
                    text: qsTr("Платформа: ") + Qt.platform.os
                    color: Theme.textSecondary
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                }

                Text {
                    Layout.fillWidth: true
                    Layout.leftMargin: 20
                    Layout.rightMargin: 20
                    text: VersionInfo.updateStatus
                    color: VersionInfo.updateAvailable ? Theme.accentHover : Theme.textSecondary
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    visible: text.length > 0
                }

                ParaButton {
                    Layout.fillWidth: true
                    Layout.leftMargin: 20
                    Layout.rightMargin: 20
                    Layout.topMargin: 10
                    text: VersionInfo.updateCheckInProgress ? qsTr("Проверка…") : qsTr("Проверить обновления")
                    enabled: !VersionInfo.updateCheckInProgress
                    secondary: true
                    onClicked: VersionInfo.checkForUpdates()
                }

                ParaButton {
                    Layout.fillWidth: true
                    Layout.leftMargin: 20
                    Layout.rightMargin: 20
                    text: VersionInfo.downloading
                          ? qsTr("Скачивание…")
                          : (VersionInfo.canInstallInApp ? qsTr("Скачать и установить") : qsTr("Скачать"))
                    visible: VersionInfo.updateAvailable && VersionInfo.downloadUrl.length > 0
                    enabled: !VersionInfo.downloading
                    // На Linux/Windows/Android — in-app скачивание+установка; иначе (iOS/macOS) — браузер/стор.
                    onClicked: VersionInfo.canInstallInApp ? VersionInfo.downloadAndInstall()
                                                           : VersionInfo.openDownloadUrl()
                }

                ProgressBar {
                    Layout.fillWidth: true
                    Layout.leftMargin: 20
                    Layout.rightMargin: 20
                    visible: VersionInfo.downloading
                    from: 0; to: 1
                    value: VersionInfo.downloadProgress
                }

                Text {
                    Layout.fillWidth: true
                    Layout.leftMargin: 20
                    Layout.rightMargin: 20
                    text: VersionInfo.downloadStatus
                    visible: text.length > 0
                    color: Theme.textSecondary
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                }

                ParaButton {
                    Layout.fillWidth: true
                    Layout.leftMargin: 20
                    Layout.rightMargin: 20
                    text: qsTr("Отменить скачивание")
                    visible: VersionInfo.downloading
                    secondary: true
                    onClicked: VersionInfo.cancelDownload()
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 20
                    Layout.rightMargin: 20
                    Layout.topMargin: 2
                    spacing: 10

                    ParaButton {
                        Layout.fillWidth: true
                        secondary: true
                        text: qsTr("GitHub")
                        onClicked: Qt.openUrlExternally("https://github.com/ParanoiaMesseger/Paranoia")
                    }

                    ParaButton {
                        Layout.fillWidth: true
                        secondary: true
                        text: qsTr("Сайт Paranoia.run")
                        onClicked: Qt.openUrlExternally("https://paranoia.run/")
                    }
                }

                Item { Layout.preferredHeight: 20 }
            }
        }
    }
}
