import QtQuick
import QtQuick.Layouts
import ParanoiaUiClient

// Контейнер для «мелких» экранов/форм с 2–3 контролами: центрирует контент по
// горизонтали и ограничивает его максимальную ширину. На узком экране (телефон)
// контент занимает почти всю доступную ширину; на широком десктопе — не
// растягивается на всё окно, а остаётся компактным по центру (и ближе к зоне
// большого пальца на тач-экранах).
//
// Использование:
//   CenteredPane {
//       anchors.fill: parent
//       ParaButton { Layout.fillWidth: true; text: "..." }
//       ParaButton { Layout.fillWidth: true; text: "..." }
//   }
// Дочерние элементы кладутся во внутренний ColumnLayout — используйте Layout.*.
Item {
    id: pane

    default property alias content: column.data
    // Максимальная ширина контента на десктопе.
    property real maxContentWidth: 460
    // Боковые отступы на узких экранах (когда упираемся в ширину).
    property real sideMargin: 20
    property alias spacing: column.spacing
    // Qt.AlignTop — контент сверху (формы со скроллом); Qt.AlignVCenter — по центру
    // окна (короткие подтверждения из пары кнопок).
    property int contentVAlign: Qt.AlignTop

    implicitWidth: column.implicitWidth
    implicitHeight: column.implicitHeight

    ColumnLayout {
        id: column
        spacing: 16
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(pane.width - pane.sideMargin * 2, pane.maxContentWidth)
        y: pane.contentVAlign === Qt.AlignVCenter
           ? Math.max(0, (pane.height - implicitHeight) / 2)
           : 0
    }
}
