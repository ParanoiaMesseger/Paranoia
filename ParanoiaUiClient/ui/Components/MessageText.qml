import QtQuick
import ParanoiaUiClient

// Тело текстового сообщения. Делит текст на сегменты по фенсед-блокам ``` ``` ```:
//  • обычный текст     → Text (MarkdownText, либо RichText если есть inline-код);
//  • многострочный код → нативный Rectangle с подсветкой (НЕ полагаемся на фон
//    <pre>/<table> в Qt RichText, который красит только первую строку);
//  • inline `код`      → кликабельный «чип» (копируется по клику).
//
// ВАЖНО про ширину: корень — Item, а НЕ Column. У Column implicitWidth = ширина
// детей; если привязать детей к ширине самого Column (= ширине пузыря), получается
// вырожденная петля и пузырь схлопывается в 1 символ. Поэтому implicitWidth тут
// считается по «естественной» ширине через скрытые измерители, независимо от
// собственной width (как это делает обычный Text).
Item {
    id: body

    property string raw: ""
    property bool outgoing: false
    property color textColor: Theme.textPrimary

    signal linkActivated(string url)   // настоящие ссылки
    signal copyRequested(string text)  // клик по inline/блоку кода

    implicitWidth: Math.max(measureText.implicitWidth,
                            measureCode.text.length > 0 ? measureCode.implicitWidth + 24 : 0)
    implicitHeight: col.implicitHeight
    height: implicitHeight

    // ── Сегменты ─────────────────────────────────────────────────────────
    readonly property var _segs: _segments(raw)
    // Крупный эмодзи только для «чистых» эмодзи-сообщений без кода.
    readonly property real _emojiScale:
        (_segs.length === 1 && _segs[0].type === "text" && !_hasInline(_segs[0].content))
            ? _emojiOnlyScale(raw) : 1

    function _segments(rawText) {
        const text = rawText || ""
        let segs = []
        const re = /```[ \t]*([A-Za-z0-9+#._-]*)[ \t]*\r?\n?([\s\S]*?)```/g
        let last = 0, m
        while ((m = re.exec(text)) !== null) {
            if (m.index > last)
                segs.push({ type: "text", content: text.substring(last, m.index) })
            segs.push({ type: "code", content: m[2].replace(/\n+$/, ""), lang: m[1] || "" })
            last = re.lastIndex
        }
        if (last < text.length) segs.push({ type: "text", content: text.substring(last) })
        segs = segs.map(function(s) {
            if (s.type === "text") s.content = s.content.replace(/^\n+/, "").replace(/\n+$/, "")
            return s
        }).filter(function(s) { return s.type === "code" || s.content.length > 0 })
        if (segs.length === 0) segs.push({ type: "text", content: "" })
        return segs
    }

    // Плоский текст для измерения естественной ширины (без переноса).
    function _measurePlain() {
        return _segs.filter(function(s) { return s.type === "text" })
                    .map(function(s) { return s.content.replace(/`([^`\n]+)`/g, "$1") })
                    .join("\n")
    }
    function _measureCodePlain() {
        return _segs.filter(function(s) { return s.type === "code" })
                    .map(function(s) { return s.content })
                    .join("\n")
    }

    // ── Хелперы рендера ──────────────────────────────────────────────────
    function _esc(s) {
        return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    }
    function _hasInline(s) { return /`[^`\n]+`/.test(s || "") }

    // Нужен ли сегменту дорогой RichText (QTextDocument + HTML-раскладка), или
    // хватит дешёвого PlainText. RichText шейпится HarfBuzz'ом в разы дороже —
    // именно он давал ~1.8с фриз на инкубации делегатов сообщений. Большинство
    // сообщений — простой текст без разметки → PlainText. RichText включаем только
    // при реальной разметке: inline-код, ссылки/картинки, **жирный**/*курсив*/~~~~,
    // или увеличение эмодзи (<span font-size>, только когда не emoji-only).
    function _segNeedsRich(s) {
        s = s || ""
        if (_hasInline(s)) return true
        if (/https?:\/\/\S/.test(s)) return true   // голый URL → автолинк (RichText)
        if (/\*\*[^*]+\*\*|__[^_]+__|(^|[^*])\*[^*\n]+\*|~~[^~]+~~|\[[^\]]+\]\([^)\s]+\)|!\[[^\]]*\]\([^)]+\)/.test(s))
            return true
        if (_emojiScale === 1 && _emojiRe) { _emojiRe.lastIndex = 0; if (_emojiRe.test(s)) return true }
        return false
    }

    readonly property var _codeKeywords: {
        const list = ("function return if else for while do switch case break continue var let const new "
            + "class struct enum public private protected static void int float double bool char string auto "
            + "import from export default def elif try catch except finally throw raise with as in is and or not "
            + "true false null nil none undefined this self super async await yield lambda fn impl trait pub mut "
            + "match use package namespace template typename typedef extends implements interface override final "
            + "abstract print println echo foreach func type go defer chan map range select").split(" ")
        let s = {}
        for (let i = 0; i < list.length; ++i) s[list[i]] = true
        return s
    }

    function _highlightCode(code) {
        const escaped = _esc(code)
        const re = /(\/\/[^\n]*|#[^\n]*|\/\*[\s\S]*?\*\/)|("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|(\b\d+(?:\.\d+)?\b)|([A-Za-z_]\w*)/g
        const KW = _codeKeywords
        function span(color, t) { return '<span style="color:' + color + '">' + t + '</span>' }
        return escaped.replace(re, function(m, comment, str, num, word) {
            if (comment) return span(Theme.codeComment, comment)
            if (str) return span(Theme.codeString, str)
            if (num) return span(Theme.codeNumber, num)
            if (word) return KW[word] ? span(Theme.codeKeyword, word) : word
            return m
        })
    }
    function _codeHtml(code) {
        let html = '<span style="font-family:' + Theme.monoFamily + ';color:' + Theme.codeText + '">'
                 + _highlightCode(code) + '</span>'
        // НЕ используем <pre> — он задаёт white-space:pre и запрещает перенос, из-за
        // чего длинные строки уезжали за экран. Пробелы/переводы строк меняем ТОЛЬКО
        // в текстовых узлах (между > и <), чтобы не разрушить разметку тегов:
        // &nbsp; сохраняет отступы, <br> — строки, а wrapMode:WrapAnywhere переносит
        // слишком длинные строки внутри блока.
        return html.replace(/>([^<]*)</g, function(m, txt) {
            return ">" + txt.replace(/ /g, "&nbsp;").replace(/\n/g, "<br>") + "<"
        })
    }

    // Текстовый сегмент → RichText. Поддержка: inline-код (ссылка copy: с
    // фоном-чипом), картинки [alt], ссылки, **жирный**, *курсив*, ~~зачёркнутый~~,
    // переносы строк. Каждый эмодзи внутри текста увеличивается на 15% через
    // <span font-size> — но НЕ для эмодзи-сообщений (_emojiScale>1), где шрифт
    // уже масштабирован целиком.
    function _richText(rawText) {
        let text = rawText || ""
        let chips = []
        text = text.replace(/`([^`\n]+)`/g, function(m, code) {
            // ВАЖНО: цвет ЯВНО через inline-style. Text.linkColor в Qt 6.10 к этим
            // <a> НЕ применяется (рендерится дефолтным синим — «светло-синий на
            // белом»), а вот style="color:" на самом <a> работает. Inline-код
            // красим в codeText на фоне-чипе codeBg (как блок кода) → читаемо в
            // обеих темах и отличимо от обычных ссылок.
            chips.push('<a href="copy:' + encodeURIComponent(code)
                     + '" style="background-color:' + Theme.codeBg + ';color:' + Theme.codeText + '">'
                     + _esc(code) + '</a>')
            return "\x01" + (chips.length - 1) + "\x01"
        })
        text = _esc(text)
        text = text.replace(/!\[([^\]]*)\]\([^)]+\)/g, function(m, alt) {
            return alt && alt.length > 0 ? "[" + alt + "]" : "[image]"
        })
        // Цвет ссылки тоже задаём явно (linkColor в Qt 6.10 игнорируется, иначе
        // дефолтный синий): акцентный цвет темы.
        text = text.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g,
                            '<a href="$2" style="color:' + Theme.accentHover + '">$1</a>')
        // Автолинк голых http(s)-URL. Уже готовые <a>…</a> (markdown-ссылки выше)
        // прячем в плейсхолдеры \x02, чтобы не линковать URL внутри href/текста
        // повторно, линкуем остальные, восстанавливаем. Хвостовую пунктуацию
        // (.,;:!?)»"') в ссылку не включаем. & к этому моменту уже &amp; (после _esc).
        {
            let _anchors = []
            text = text.replace(/<a\b[^>]*>[\s\S]*?<\/a>/g, function(m) {
                _anchors.push(m); return "\x02" + (_anchors.length - 1) + "\x02"
            })
            text = text.replace(/https?:\/\/[^\s<]*[^\s<.,;:!?)\]»"']/g, function(url) {
                return '<a href="' + url + '" style="color:' + Theme.accentHover + '">' + url + '</a>'
            })
            text = text.replace(/\x02(\d+)\x02/g, function(m, i) { return _anchors[parseInt(i)] })
        }
        text = text.replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>").replace(/__([^_]+)__/g, "<b>$1</b>")
        text = text.replace(/(^|[^*])\*([^*\n]+)\*/g, "$1<i>$2</i>")
        text = text.replace(/~~([^~]+)~~/g, "<s>$1</s>")
        text = text.replace(/\n/g, "<br>")
        if (_emojiScale === 1 && _emojiRe) {
            _emojiRe.lastIndex = 0
            text = text.replace(_emojiRe, '<span style="font-size:115%">$&</span>')
        }
        return text.replace(/\x01(\d+)\x01/g, function(m, i) { return chips[parseInt(i)] })
    }

    // Крупный эмодзи: один → 3.5×, до трёх → 2×. V4 не поддерживает \p{...}.
    readonly property var _emojiRe: {
        try {
            const RI = "\\u{1F1E6}-\\u{1F1FF}"
            const SKIN = "\\u{1F3FB}-\\u{1F3FF}"
            const BASE = "[\\u{1F300}-\\u{1FAFF}\\u{1F000}-\\u{1F0FF}\\u{2600}-\\u{27BF}\\u{2B00}-\\u{2BFF}\\u{2300}-\\u{23FF}\\u{2194}-\\u{21AA}\\u{2122}\\u{2139}\\u{24C2}\\u{3030}\\u{303D}\\u{3297}\\u{3299}\\u{00A9}\\u{00AE}\\u{203C}\\u{2049}]"
            const cluster = "(?:[" + RI + "][" + RI + "]|[0-9#*]\\uFE0F?\\u20E3|"
                          + BASE + "(?:\\uFE0F|\\u200D" + BASE + "|[" + SKIN + "])*)"
            return new RegExp(cluster, "gu")
        } catch (e) { return null }
    }
    function _emojiOnlyScale(rawText) {
        if (!_emojiRe) return 1
        const t = (rawText || "").trim()
        if (t.length === 0) return 1
        _emojiRe.lastIndex = 0
        const matches = t.match(_emojiRe)
        if (!matches) return 1
        if (matches.join("") !== t.replace(/\s+/g, "")) return 1
        if (matches.length === 1) return 6.0
        if (matches.length <= 3) return 3.0
        return 1
    }

    // Вернуть URL ссылки в точке (px,py) в координатах body, либо "" если ссылки нет.
    // Зачем: в ChatPage MouseArea пузыря лежит ПОВЕРХ текста и перехватывает клики,
    // из-за чего onLinkActivated самого Text не срабатывал — ссылки «не открывались»
    // (#28). MouseArea теперь спрашивает linkAt и сам открывает ссылку. Маппим точку
    // в нужный сегмент-Text и делегируем его встроенному linkAt.
    function linkAt(px, py) {
        for (let i = 0; i < col.children.length; ++i) {
            const seg = col.children[i]
            if (!seg || !seg.item || !seg.item.linkAt) continue   // Repeater/код-блок — пропускаем
            const p = body.mapToItem(seg.item, px, py)
            if (p.x >= 0 && p.y >= 0 && p.x <= seg.item.width && p.y <= seg.item.height) {
                const link = seg.item.linkAt(p.x, p.y)
                if (link && link.length > 0) return link
            }
        }
        return ""
    }

    // ── Скрытые измерители естественной ширины ──────────────────────────
    Text {
        id: measureText
        visible: false
        textFormat: Text.PlainText
        wrapMode: Text.NoWrap
        font.family: Theme.fontFamily
        font.pixelSize: body._emojiScale > 1
                        ? Math.round(Theme.fontMd * body._emojiScale) : Theme.fontMd
        text: body._measurePlain()
    }
    Text {
        id: measureCode
        visible: false
        textFormat: Text.PlainText
        wrapMode: Text.NoWrap
        font.family: Theme.monoFamily
        font.pixelSize: Theme.fontSm
        text: body._measureCodePlain()
    }

    // ── Рендер сегментов ─────────────────────────────────────────────────
    Column {
        id: col
        width: body.width
        spacing: 6

        Repeater {
            model: body._segs

            delegate: Loader {
                required property var modelData
                width: body.width
                sourceComponent: modelData.type === "code" ? codeComp : textComp

                Component {
                    id: textComp
                    Text {
                        // RichText только при реальной разметке (см. _segNeedsRich) —
                        // иначе PlainText с сырым текстом: тот же результат, но без
                        // дорогой QTextDocument-раскладки (фикс ~1.8с фриза).
                        readonly property bool _rich: body._segNeedsRich(modelData.content)
                        width: body.width
                        text: _rich ? body._richText(modelData.content) : modelData.content
                        textFormat: _rich ? Text.RichText : Text.PlainText
                        color: body.textColor
                        linkColor: Theme.accentHover
                        font.pixelSize: body._emojiScale > 1
                                        ? Math.round(Theme.fontMd * body._emojiScale) : Theme.fontMd
                        font.family: Theme.fontFamily
                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                        lineHeight: body._emojiScale > 1 ? 1.1 : 1.3
                        onLinkActivated: function(link) {
                            if (link.indexOf("copy:") === 0)
                                body.copyRequested(decodeURIComponent(link.substring(5)))
                            else
                                body.linkActivated(link)
                        }
                    }
                }

                Component {
                    id: codeComp
                    Rectangle {
                        // Во всю ширину пузыря: пузырь уже отмерен по самой длинной
                        // строке кода (measureCode) с ограничением 72%, а длинные
                        // строки переносятся внутри (см. _codeHtml + WrapAnywhere).
                        implicitWidth: body.width
                        width: body.width
                        implicitHeight: codeText.implicitHeight + 20
                        radius: Theme.radiusSm
                        color: Theme.codeBg
                        border.color: Theme.codeBorder
                        border.width: 1

                        Text {
                            id: codeText
                            x: 12; y: 10
                            width: Math.max(1, body.width - 24)
                            text: body._codeHtml(modelData.content)
                            textFormat: Text.RichText
                            color: Theme.codeText
                            font.family: Theme.monoFamily
                            font.pixelSize: Theme.fontSm
                            // КРИТИЧНО (фикс «namertvo»-фриза в диалогах с кодом): при
                            // создании делегата ListView body.width кратковременно ~0
                            // (измеритель ещё не разложен) → width≈0; WrapAnywhere при
                            // нулевой ширине раздувает высоту блока до гигантской
                            // (каждый символ на строку) → contentHeight подскакивает →
                            // автоскролл onContentHeightChanged→positionViewAtEnd
                            // пересоздаёт делегат → снова width≈0 → бесконечный цикл,
                            // UI виснет намертво (воспроизводилось на всех платформах).
                            // Пока ширина невалидна — НЕ переносим (NoWrap: высота =
                            // числу строк, без взрыва); WrapAnywhere включаем, когда
                            // ширина пузыря уже посчитана. Порог 40 — реальные код-
                            // пузыри всегда шире (код задаёт ширину пузыря).
                            wrapMode: body.width > 40 ? Text.WrapAnywhere : Text.NoWrap
                        }

                        AppIcon {
                            anchors.top: parent.top; anchors.right: parent.right
                            anchors.margins: 6
                            width: 16; height: 16
                            name: codeCopyArea.copied ? "check" : "copy"
                            iconColor: Theme.codeComment
                            fillColor: Theme.codeBg
                            secondaryColor: Theme.codeBg
                            strokeWidth: 1.5
                            opacity: 0.8
                        }

                        MouseArea {
                            id: codeCopyArea
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            property bool copied: false
                            onClicked: {
                                body.copyRequested(modelData.content)
                                copied = true
                                copyResetTimer.restart()
                            }
                            Timer { id: copyResetTimer; interval: 1200; onTriggered: codeCopyArea.copied = false }
                        }
                    }
                }
            }
        }
    }
}
