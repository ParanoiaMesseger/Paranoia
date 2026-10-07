import QtQuick
import ParanoiaUiClient

// Заглушка на месте изображения, которое приехало целым, но не декодируется
// (формат без плагина QImage, битые байты). Без неё плитка остаётся пустой и
// отказ выглядит как «ничего не пришло».
Column {
    id: root

    property bool showText: true

    spacing: 6

    AppIcon {
        anchors.horizontalCenter: parent.horizontalCenter
        width: 22; height: 22
        name: "image"
        iconColor: Theme.textHint
    }

    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.showText
        text: qsTr("Не удалось отобразить")
        color: Theme.textSecondary
        font.pixelSize: Theme.fontSm
        font.family: Theme.fontFamily
    }
}
