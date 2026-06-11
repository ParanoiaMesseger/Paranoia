import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import ParanoiaUiClient
import "emojidata.js" as EmojiData

// INLINE эмодзи-панель (НЕ popup): встаёт на место клавиатуры в поле ввода
// (вместо неё). Поиск по тексту (рус/eng ключевые слова), табы категорий,
// сетка. Эмитит picked(emoji). Высоту/видимость контролирует родитель (ChatPage).
Rectangle {
    id: panel

    signal picked(string emoji)

    color: Theme.bgDark
    clip: true

    property int currentCategory: 0
    // Живой поиск: включаем preeditText — на Android предиктивный ввод держит
    // набранное в preedit до коммита (Enter/пробел), и без него фильтр обновлялся
    // бы только по Enter (юзер так и заметил). Биндинг на id ниже по документу ок.
    readonly property string query: searchField.text + searchField.preeditText

    // Категории с эмодзи. Каждый элемент: {e: символ, k: "ключевые слова рус eng"}.
    // k используется для поиска; tab — иконка вкладки.
    // Полный CLDR-набор эмодзи (рус. метки/теги) — автоген emojidata.js (#42).
    readonly property var categories: EmojiData.categories

    // Плоский результат поиска по query (или null если поиска нет).
    readonly property var searchResults: {
        const q = query.trim().toLowerCase()
        if (q.length === 0) return null
        const out = []
        for (let c = 0; c < categories.length; ++c) {
            const items = categories[c].items
            for (let i = 0; i < items.length; ++i) {
                if (items[i].e === q || items[i].k.indexOf(q) >= 0)
                    out.push(items[i])
            }
        }
        return out
    }

    readonly property var shownItems: searchResults !== null
        ? searchResults
        : categories[currentCategory].items

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // Строка поиска
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 44
            color: Theme.bgDark
            Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: Theme.separator }

            Rectangle {
                anchors.fill: parent
                anchors.margins: 6
                radius: Theme.radiusSm
                color: Theme.bgInput
                border.width: 1
                border.color: Theme.border

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 6
                    spacing: 6

                    Text {
                        text: "🔍"
                        font.pixelSize: 16
                        font.family: Theme.fontFamily
                    }
                    TextField {
                        id: searchField
                        Layout.fillWidth: true
                        color: Theme.textPrimary
                        font.pixelSize: Theme.fontMd
                        font.family: Theme.fontFamily
                        background: null
                        leftPadding: 0
                        rightPadding: 0
                        // query — биндинг на text+preeditText (см. выше), отдельный
                        // onTextChanged не нужен.

                        // Кастомный плейсхолдер с guard по preeditText — встроенный на
                        // Android при предиктивном вводе не прячется и наезжает на текст.
                        Text {
                            anchors.fill: parent
                            verticalAlignment: Text.AlignVCenter
                            visible: searchField.text.length === 0 && searchField.preeditText.length === 0
                            text: qsTr("Поиск эмодзи…")
                            color: Theme.textHint
                            font: searchField.font
                            elide: Text.ElideRight
                        }
                    }
                    Rectangle {
                        Layout.preferredWidth: 26; Layout.preferredHeight: 26
                        radius: 13
                        visible: panel.query.length > 0
                        color: clearArea.containsMouse ? Theme.bgCard : "transparent"
                        Text { anchors.centerIn: parent; text: "✕"; color: Theme.textSecondary; font.pixelSize: 14 }
                        MouseArea {
                            id: clearArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            // clear() сбрасывает text И preedit → биндинг query обнулится.
                            onClicked: { searchField.clear(); Qt.inputMethod.reset() }
                        }
                    }
                }
            }
        }

        // Сетка эмодзи (категория или результаты поиска)
        GridView {
            id: grid
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.margins: 6
            clip: true
            cellWidth: Math.floor(width / Math.max(1, Math.floor(width / 46)))
            cellHeight: 46
            model: panel.shownItems
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}

            // Пустой результат поиска.
            Text {
                anchors.centerIn: parent
                visible: panel.searchResults !== null && panel.searchResults.length === 0
                text: qsTr("Ничего не найдено")
                color: Theme.textHint
                font.pixelSize: Theme.fontMd
                font.family: Theme.fontFamily
            }

            delegate: Item {
                id: cell
                required property var modelData
                width: grid.cellWidth
                height: grid.cellHeight

                Rectangle {
                    anchors.centerIn: parent
                    width: 40; height: 40
                    radius: Theme.radiusSm
                    color: cellArea.containsMouse ? Theme.bgInput : "transparent"

                    // Эмодзи как КАРТИНКА (через image://emoji/ провайдер), а не Text —
                    // обходит цветной glyph-кэш scene-graph, который на Android
                    // переполнялся (пропадали эмодзи/целые вкладки). sourceSize 2x —
                    // чёткость на hiDPI; cache:true — QML-кэш переживает скролл.
                    Image {
                        anchors.centerIn: parent
                        width: 26; height: 26
                        sourceSize.width: 52
                        sourceSize.height: 52
                        smooth: true
                        cache: true
                        asynchronous: true
                        fillMode: Image.PreserveAspectFit
                        source: "image://emoji/" + encodeURIComponent(cell.modelData.e)
                    }

                    MouseArea {
                        id: cellArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: panel.picked(cell.modelData.e)
                    }
                }
            }
        }

        // Полоса категорий (скрыта при активном поиске)
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: panel.searchResults !== null ? 0 : 46
            visible: panel.searchResults === null
            color: Theme.bgDark

            Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: Theme.separator }

            Row {
                anchors.centerIn: parent
                spacing: 2
                Repeater {
                    model: panel.categories
                    delegate: Rectangle {
                        required property int index
                        required property var modelData
                        width: 36; height: 36
                        radius: Theme.radiusSm
                        color: panel.currentCategory === index ? Theme.accentDim
                             : tabArea.containsMouse ? Theme.bgInput : "transparent"
                        border.width: panel.currentCategory === index ? 1 : 0
                        border.color: Theme.accent

                        Image {
                            anchors.centerIn: parent
                            width: 22; height: 22
                            sourceSize.width: 44
                            sourceSize.height: 44
                            smooth: true
                            cache: true
                            fillMode: Image.PreserveAspectFit
                            source: "image://emoji/" + encodeURIComponent(modelData.tab)
                        }
                        MouseArea {
                            id: tabArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                panel.currentCategory = index
                                grid.positionViewAtBeginning()
                            }
                        }
                    }
                }
            }
        }
    }
}
