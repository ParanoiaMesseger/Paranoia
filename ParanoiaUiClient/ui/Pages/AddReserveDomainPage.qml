import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import ParanoiaUiClient

// Страница «Резерв» — тонкая обёртка над переиспользуемым ReserveTurnEditor
// (тот же редактор встроен в «Настройки профиля», чтобы не плодить окна).
Rectangle {
    id: root
    color: Theme.bgPrimary

    required property string targetType
    required property string targetId
    required property string primaryDomain

    signal back()

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        ParaHeader {
            Layout.fillWidth: true
            title: root.targetType === "client" ? qsTr("Резерв клиента") : qsTr("Резерв админа")
            onBackClicked: root.back()
        }

        Flickable {
            id: formFlick
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentHeight: Math.max(formFlick.height, editorCol.implicitHeight + 48)
            clip: true

            ColumnLayout {
                id: editorCol
                width: Math.min(parent.width - 48, 560)
                anchors.horizontalCenter: parent.horizontalCenter
                y: 24
                spacing: 16

                Text {
                    Layout.fillWidth: true
                    text: qsTr("Основной адрес: %1").arg(root.primaryDomain)
                    color: Theme.textSecondary
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    elide: Text.ElideRight
                }

                ReserveTurnEditor {
                    Layout.fillWidth: true
                    targetType: root.targetType
                    targetId: root.targetId
                    primaryDomain: root.primaryDomain
                }
            }
        }
    }
}
