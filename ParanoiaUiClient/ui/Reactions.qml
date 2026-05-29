pragma Singleton
import QtQuick
import QtCore

// Глобальный, настраиваемый пользователем список быстрых реакций.
// Сохраняется в QtCore Settings (категория "reactions") и используется
// в меню сообщения (ChatPage). Редактируется через EmojiPicker.
QtObject {
    id: root

    readonly property var defaults: ["👍", "🔥", "🤡", "💩", "❤️", "😂", "😢"]

    // Текущий список. При первом запуске (пустые настройки) — defaults.
    property var list: root._normalize(_settings.reactions)

    function _normalize(arr) {
        const clean = []
        if (arr) {
            for (let i = 0; i < arr.length; ++i) {
                const e = String(arr[i] || "").trim()
                if (e.length > 0 && clean.indexOf(e) < 0) clean.push(e)
            }
        }
        return clean.length > 0 ? clean : root.defaults.slice()
    }

    function setList(arr) {
        const clean = root._normalize(arr)
        root.list = clean
        _settings.reactions = clean
    }

    function add(emoji) {
        const e = String(emoji || "").trim()
        if (e.length === 0) return
        const a = root.list.slice()
        if (a.indexOf(e) >= 0) return
        a.push(e)
        root.setList(a)
    }

    function removeAt(index) {
        if (index < 0 || index >= root.list.length) return
        const a = root.list.slice()
        a.splice(index, 1)
        root.setList(a)
    }

    function reset() {
        root.setList(root.defaults.slice())
    }

    property Settings _settings: Settings {
        category: "reactions"
        property var reactions: []
    }
}
