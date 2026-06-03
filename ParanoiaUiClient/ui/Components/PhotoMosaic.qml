import QtQuick
import ParanoiaUiClient

// Мозаика фото-группы: плитки + опциональная подпись. Плитки с непустым `key`
// (ещё загружаются) показывают кольцо прогресса поверх локального превью.
// Готовые (committed) плитки кликабельны — открывают просмотрщик-галерею.
//
// Внутри — ListModel с ИНКРЕМЕНТАЛЬНОЙ синхронизацией (syncTiles): при появлении
// превью одной плитки обновляется ТОЛЬКО её строка (set), остальные Image не
// пересоздаются — иначе вся мозаика мигала бы (cache=false → перезагрузка всех).
Item {
    id: mosaic

    // [{id, source, name, key, status}]; key!="" → оптимистичная (грузится).
    property var photos: []
    property string caption: ""
    property real maxWidth: 260
    property real spacing: 3
    // Прогресс загрузки: progressMap[key] ∈ [0..1]; tick форсирует перевычисление.
    property var progressMap: ({})
    property int progressTick: 0

    signal tileClicked(string id, string source, string name)

    readonly property int count: photos ? photos.length : 0
    readonly property int columns: count <= 1 ? 1 : (count === 2 ? 2 : (count === 4 ? 2 : 3))
    readonly property int rows: count > 0 ? Math.ceil(count / columns) : 0
    readonly property real cell: count > 0 ? (maxWidth - spacing * (columns - 1)) / columns : maxWidth

    function tileProgress(key) {
        void progressTick // зависимость для биндинга
        if (!key || key.length === 0) return 1
        const p = progressMap[key]
        return (p === undefined) ? 0 : p
    }

    // Синхронизировать tilesModel с photos «по-минимуму»: лишние удалить, новые
    // добавить, изменившиеся обновить in-place. Неизменившиеся плитки не трогаем
    // → их Image не пересоздаётся (нет мигания при подгрузке превью соседа).
    function syncTiles() {
        var arr = mosaic.photos || []
        while (tilesModel.count > arr.length)
            tilesModel.remove(tilesModel.count - 1)
        for (var i = 0; i < arr.length; ++i) {
            var p = arr[i]
            var row = { mid: p.id || "", source: p.source || "",
                        name: p.name || "", tkey: p.key || "", status: p.status || "" }
            if (i >= tilesModel.count) {
                tilesModel.append(row)
            } else {
                var cur = tilesModel.get(i)
                if (cur.mid !== row.mid || cur.source !== row.source || cur.tkey !== row.tkey
                        || cur.name !== row.name || cur.status !== row.status)
                    tilesModel.set(i, row)
            }
        }
    }

    onPhotosChanged: mosaic.syncTiles()
    Component.onCompleted: mosaic.syncTiles()

    ListModel { id: tilesModel }

    implicitWidth: maxWidth
    // Высота корня = высота колонки (Grid/Text — позиционеры, их implicit-размер
    // read-only и считается из детей; собственный implicit на них задавать нельзя).
    implicitHeight: contentColumn.implicitHeight

    Column {
        id: contentColumn
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 6

        Grid {
            id: grid
            columns: mosaic.columns
            spacing: mosaic.spacing
            // implicitWidth/Height у Grid read-only — размер берётся из плиток
            // (каждая width=height=mosaic.cell), columns задаёт раскладку.

            Repeater {
                model: tilesModel

                Rectangle {
                    id: tile
                    required property string mid
                    required property string source
                    required property string name
                    required property string tkey
                    width: mosaic.cell
                    height: mosaic.cell
                    radius: Theme.radiusSm
                    clip: true
                    color: Theme.bgInput

                    // Прогресс отправки плитки. ЯВНО читаем mosaic.progressTick и
                    // mosaic.progressMap прямо в биндинге (не через void-трюк в функции)
                    // — иначе зависимость от тика могла не отслеживаться и prog застывал
                    // на 0 («кольцо есть, прогресс не идёт»).
                    readonly property real prog: {
                        const _tick = mosaic.progressTick            // реактивная зависимость
                        if (tkey.length === 0) return 1
                        const p = mosaic.progressMap[tkey]
                        return (p === undefined) ? 0 : p
                    }
                    readonly property bool loading: tkey.length > 0 && prog < 0.999

                    // Committed-плитка без превью (ленивая загрузка) — запросить
                    // расшифровку; по готовности syncTiles обновит ТОЛЬКО эту строку,
                    // плитка получит source (image://secure/<id>). Триггер РЕАКТИВНЫЙ
                    // (не только onCompleted): плитка может стать committed уже после
                    // создания — оптимистичная (tkey!="") переходит в committed через
                    // set() (mid появляется, tkey/ source обнуляются), а onCompleted
                    // тогда уже не сработает. ensureImagePreview сам дедупит повторы.
                    function maybeRequestPreview() {
                        if (tkey.length === 0 && mid.length > 0 && source.length === 0)
                            Chat.ensureImagePreview(mid)
                    }
                    Component.onCompleted: maybeRequestPreview()
                    onMidChanged: maybeRequestPreview()
                    onTkeyChanged: maybeRequestPreview()
                    onSourceChanged: maybeRequestPreview()

                    Image {
                        anchors.fill: parent
                        source: tile.source
                        visible: source.toString().length > 0
                        asynchronous: true
                        cache: false
                        fillMode: Image.PreserveAspectCrop
                        sourceSize.width: Math.round(mosaic.cell * 2)
                        sourceSize.height: Math.round(mosaic.cell * 2)
                    }

                    // Плейсхолдер для committed-плитки без превью (ленивая загрузка).
                    AppIcon {
                        anchors.centerIn: parent
                        width: 22; height: 22
                        visible: tile.source.length === 0 && !tile.loading
                        name: "image"
                        iconColor: Theme.textHint
                    }

                    // Затемнение + кольцо прогресса во время загрузки.
                    Rectangle {
                        anchors.fill: parent
                        visible: tile.loading
                        color: "#66020103"
                    }
                    Canvas {
                        id: ring
                        anchors.centerIn: parent
                        width: Math.min(40, tile.width * 0.5)
                        height: width
                        visible: tile.loading
                        // Детерминированный прогресс отправки плитки ∈ [0..1]. Плавная
                        // анимация сглаживает грубые скачки по чанкам в текущее заполнение
                        // (БЕЗ вращения — это честный ring-progress, а не спиннер).
                        property real value: tile.prog
                        Behavior on value { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                        onValueChanged: requestPaint()
                        onPaint: {
                            const ctx = getContext("2d")
                            ctx.reset()
                            const cx = width / 2, cy = height / 2, r = width / 2 - 3
                            ctx.lineWidth = 3
                            // Фоновая дорожка (полный круг) — видно «сколько осталось».
                            ctx.strokeStyle = "#55FFFFFF"
                            ctx.beginPath(); ctx.arc(cx, cy, r, 0, Math.PI * 2); ctx.stroke()
                            // Дуга прогресса от 12ч по часовой; минимум ~3% — стартовая риска.
                            ctx.strokeStyle = "#FFFFFF"
                            ctx.lineCap = "round"
                            ctx.beginPath()
                            ctx.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * Math.max(0.03, value))
                            ctx.stroke()
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: tile.loading ? Qt.ArrowCursor : Qt.PointingHandCursor
                        enabled: !tile.loading && tile.mid.length > 0
                        onClicked: mosaic.tileClicked(tile.mid, tile.source, tile.name)
                    }
                }
            }
        }

        Text {
            id: captionText
            width: parent.width
            visible: mosaic.caption.length > 0
            text: mosaic.caption
            color: Theme.textPrimary
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontMd
            wrapMode: Text.Wrap
        }
    }
}
