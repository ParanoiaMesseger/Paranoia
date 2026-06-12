import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import ParanoiaUiClient

// Кастомный эмодзи-пикер. Переиспользуется для вставки эмодзи в поле ввода
// и для настройки списка быстрых реакций. Эмитит picked(emoji) при выборе.
Popup {
    id: picker

    signal picked(string emoji)

    // Заголовок над сеткой (например, "Добавить реакцию"). Пусто — скрыт.
    property string heading: ""
    // Закрывать пикер сразу после выбора (для вставки — да, для набора
    // нескольких реакций подряд можно выставить false).
    property bool closeOnPick: true

    implicitWidth: 360
    implicitHeight: 420
    padding: 0
    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    property int currentCategory: 0

    readonly property var categories: [
        { tab: "🙂", emojis: [
            "😀","😃","😄","😁","😆","😅","🤣","😂","🙂","🙃","😉","😊","😇","🥰","😍","🤩",
            "😘","😗","😚","😙","😋","😛","😜","🤪","😝","🤑","🤗","🤭","🤫","🤔","🤐","🤨",
            "😐","😑","😶","😏","😒","🙄","😬","😮‍💨","🤥","😌","😔","😪","🤤","😴","😷","🤒",
            "🤕","🤢","🤮","🥵","🥶","🥴","😵","🤯","🤠","🥳","😎","🤓","🧐","😕","😟","🙁",
            "😮","😯","😲","😳","🥺","😦","😧","😨","😰","😥","😢","😭","😱","😖","😣","😞",
            "😓","😩","😫","🥱","😤","😡","😠","🤬","😈","👿","💀","💩","🤡","👻","👽","🤖"
        ] },
        { tab: "👍", emojis: [
            "👍","👎","👌","🤌","🤏","✌️","🤞","🤟","🤘","🤙","👈","👉","👆","👇","☝️","✋",
            "🤚","🖐️","🖖","👋","🤝","👏","🙌","👐","🤲","🙏","✍️","💅","🤳","💪","🦾","👀",
            "👁️","👅","👄","🫦","🦷","👂","👃","🫶","🤲","🖕"
        ] },
        { tab: "❤️", emojis: [
            "❤️","🧡","💛","💚","💙","💜","🖤","🤍","🤎","💔","❣️","💕","💞","💓","💗","💖",
            "💘","💝","💟","♥️","💯","💢","💥","💫","💦","💨","🕳️","💬","💭","🔥","⭐","🌟",
            "✨","💫","🎉","🎊"
        ] },
        { tab: "🐶", emojis: [
            "🐶","🐱","🐭","🐹","🐰","🦊","🐻","🐼","🐨","🐯","🦁","🐮","🐷","🐸","🐵","🐔",
            "🐧","🐦","🐤","🦆","🦅","🦉","🐺","🐗","🐴","🦄","🐝","🐛","🦋","🐌","🐞","🐢",
            "🐍","🐙","🦑","🦀","🐠","🐟","🐬","🐳","🐋","🦈","🐊","🐅","🐆","🦓","🦍","🐘"
        ] },
        { tab: "🍏", emojis: [
            "🍏","🍎","🍐","🍊","🍋","🍌","🍉","🍇","🍓","🫐","🍈","🍒","🍑","🥭","🍍","🥥",
            "🥝","🍅","🍆","🥑","🥦","🥬","🥒","🌶️","🌽","🥕","🧄","🧅","🥔","🍠","🥐","🍞",
            "🧀","🍳","🥓","🍔","🍟","🍕","🌭","🥪","🌮","🌯","🍣","🍰","🎂","🍫","🍬","☕"
        ] },
        { tab: "⚽", emojis: [
            "⚽","🏀","🏈","⚾","🥎","🎾","🏐","🏉","🎱","🏓","🏸","🥅","🏒","🏑","🏏","⛳",
            "🎯","🪁","🎮","🎲","🎰","🧩","🎸","🎺","🎻","🥁","🎹","🎤","🎧","🎬","🎨","🚗",
            "✈️","🚀","⛵","🏆","🥇","🥈","🥉","🏅"
        ] },
        { tab: "💡", emojis: [
            "⌚","📱","💻","⌨️","🖥️","🖨️","🖱️","💽","💾","📀","📷","📸","🎥","📺","🔋","🔌",
            "💡","🔦","📡","💸","💵","💰","💳","🔑","🔒","🔓","🔨","🪛","🔧","⚙️","🧲","🔭",
            "🔬","💉","💊","🚪","🛏️","🚽","🧻","📚","✏️","📌","📎","✂️","📅","✅","❌","⚠️"
        ] },
        { tab: "🔣", emojis: [
            "❗","❓","‼️","⁉️","💲","➕","➖","➗","✖️","🟰","♾️","✔️","☑️","🔘","🔴","🟠",
            "🟡","🟢","🔵","🟣","⚫","⚪","🟥","🟧","🟨","🟩","🟦","🟪","⬛","⬜","🔶","🔷",
            "🔺","🔻","💠","🔄","➡️","⬅️","⬆️","⬇️","↗️","↘️","🔝","🆗","🆕","🔞","♻️","®️"
        ] }
    ]

    background: Rectangle {
        color: Theme.bgCard
        radius: Theme.radiusMd
        border.width: 1
        border.color: Theme.border
    }

    contentItem: ColumnLayout {
        spacing: 0

        // Заголовок (опциональный)
        Text {
            Layout.fillWidth: true
            Layout.margins: 10
            Layout.bottomMargin: 4
            visible: picker.heading.length > 0
            text: picker.heading
            color: Theme.textPrimary
            font.pixelSize: Theme.fontMd
            font.family: Theme.fontFamily
            font.weight: Font.Medium
            elide: Text.ElideRight
        }

        // Сетка эмодзи выбранной категории
        GridView {
            id: grid
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.margins: 8
            clip: true
            cellWidth: Math.floor(width / Math.max(1, Math.floor(width / 46)))
            cellHeight: 46
            model: picker.categories[picker.currentCategory].emojis
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}

            delegate: Item {
                id: cell
                required property string modelData
                width: grid.cellWidth
                height: grid.cellHeight

                Rectangle {
                    anchors.centerIn: parent
                    width: 40; height: 40
                    radius: height / 2          // круглые кнопки эмодзи
                    color: cellArea.containsMouse ? Theme.bgInput : "transparent"

                    Text {
                        anchors.centerIn: parent
                        text: cell.modelData
                        font.pixelSize: 24
                        font.family: Theme.fontFamily
                    }

                    MouseArea {
                        id: cellArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            picker.picked(cell.modelData)
                            if (picker.closeOnPick) picker.close()
                        }
                    }
                }
            }
        }

        // Полоса категорий
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 46
            color: Theme.bgDark
            radius: Theme.radiusMd

            Rectangle {
                anchors.top: parent.top
                width: parent.width; height: 1
                color: Theme.separator
            }

            Row {
                anchors.centerIn: parent
                spacing: 2
                Repeater {
                    model: picker.categories
                    delegate: Rectangle {
                        required property int index
                        required property var modelData
                        width: 36; height: 36
                        radius: height / 2          // круглые табы категорий
                        color: picker.currentCategory === index ? Theme.accentDim
                             : tabArea.containsMouse ? Theme.bgInput : "transparent"
                        border.width: picker.currentCategory === index ? 1 : 0
                        border.color: Theme.accent

                        Text {
                            anchors.centerIn: parent
                            text: modelData.tab
                            font.pixelSize: 20
                            font.family: Theme.fontFamily
                        }
                        MouseArea {
                            id: tabArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                picker.currentCategory = index
                                grid.positionViewAtBeginning()
                            }
                        }
                    }
                }
            }
        }
    }
}
