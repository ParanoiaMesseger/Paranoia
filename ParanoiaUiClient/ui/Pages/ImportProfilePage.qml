import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import ParanoiaUiClient

// Отдельная страница импорта (первый запуск, HelloPage). Сама логика импорта —
// в общем компоненте ImportProfilePanel (тот же используется во вкладке «Импорт»
// страницы Экспорт/Импорт), чтобы не дублировать.
Rectangle {
    id: root
    color: Theme.bgPrimary
    signal back()
    signal profileImported()

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        ParaHeader {
            Layout.fillWidth: true
            title: "Импорт"
            onBackClicked: root.back()
        }

        ScrollView {
            id: importScroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: availableWidth
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            // Вертикальное центрирование короткого контента (не липнет к верху).
            topPadding: Math.max(0, (height - importCol.implicitHeight) / 2)

            ColumnLayout {
                id: importCol
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.min(parent.width - 32, 560)
                spacing: 16

                Item { Layout.preferredHeight: 8 }

                ImportProfilePanel {
                    Layout.fillWidth: true
                    Layout.leftMargin: 24
                    Layout.rightMargin: 24
                    onProfileImported: root.profileImported()
                }

                Item { Layout.preferredHeight: 24 }
            }
        }
    }
}
