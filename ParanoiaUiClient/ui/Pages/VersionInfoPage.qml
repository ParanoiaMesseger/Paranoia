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
                    Text {
                        anchors.centerIn: parent
                        text: "‹"
                        color: Theme.accentHover
                        font.pixelSize: 24
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
                    text: "Версия приложения"
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

            ColumnLayout {
                width: versionScroll.availableWidth
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
                    text: "Версия: " + Qt.application.version
                    color: Theme.textPrimary
                    font.pixelSize: Theme.fontMd
                    font.family: Theme.fontFamily
                }

                Text {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.leftMargin: 20
                    Layout.rightMargin: 20
                    text: "Платформа: " + Qt.platform.os
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
                    text: VersionInfo.updateCheckInProgress ? "Проверка…" : "Проверить обновления"
                    enabled: !VersionInfo.updateCheckInProgress
                    secondary: true
                    onClicked: VersionInfo.checkForUpdates()
                }

                ParaButton {
                    Layout.fillWidth: true
                    Layout.leftMargin: 20
                    Layout.rightMargin: 20
                    text: VersionInfo.updateAvailable ? "Скачать и установить" : "Открыть страницу релизов"
                    onClicked: VersionInfo.updateAvailable && VersionInfo.downloadUrl.length > 0
                               ? VersionInfo.openDownloadUrl()
                               : VersionInfo.openReleasePage()
                }

                Item { Layout.preferredHeight: 20 }
            }
        }
    }
}
