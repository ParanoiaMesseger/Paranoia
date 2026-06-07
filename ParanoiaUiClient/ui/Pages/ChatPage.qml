import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtCore
import ParanoiaUiClient

Rectangle {
    id: root
    color: Theme.bgPrimary
    readonly property bool isMobileOs: (Qt.platform.os === "android" || Qt.platform.os === "ios")
    required property string peer
    property string pendingDownloadId: ""
    property string pendingDownloadName: "attachment.bin"
    property string downloadingAttachmentId: ""
    property bool sendLocked: false
    property bool messagesLoaded: false
    property string pendingReplyId: ""
    property string pendingReplySender: ""
    property string pendingReplyAuthor: ""
    property string pendingReplyText: ""
    readonly property bool hasPendingReply: pendingReplyId.length > 0
    property bool searchActive: false
    property string searchQuery: ""
    property int searchCurrentIndex: -1
    property var searchMatchIndices: []
    // Фото-группы (мозаики) в процессе отправки: groupId -> {caption, ts, photos:[{key,source,name}]}.
    property var pendingGroups: ({})
    // ВРЕМЕННО: диагностика мозаики (гирлянда/attachment_not_found). Снять после фикса.
    property bool _mosaicDebug: false
    // Прогресс загрузки фото по ключу (groupId:idx) ∈ [0..1]; tick форсирует биндинги.
    property var uploadProgress: ({})
    property int uploadTick: 0
    // Режим множественного выбора (ranged-delete).
    property bool selectionMode: false
    property var selectedIds: ({})  // объект как Set: { [messageId]: true }
    property int selectionCount: 0
    // Drag-select состояние (Telegram-style).
    property int _dragStartIndex: -1
    property int _dragLastIndex: -1
    property real _dragMouseY: 0
    property int _dragScrollDirection: 0
    property bool _dragSelectActive: false   // true пока зажат чекбокс/идёт drag — отключает flicking
    property bool _dragSelectMode: true      // true = добавляем, false = снимаем
    property var _dragInitialSelection: ({}) // снимок selectedIds на старте drag'а
    // Share-target: данные из системного share-sheet'а, переданные при пуше
    // ChatPage из Main.qml. Применяются один раз на Component.onCompleted.
    property string shareTextInitial: ""
    property var shareFilesInitial: []

    signal back()

    // CallPage.qml тянет QtMultimedia — её нет в сборках без VoIP, поэтому
    // компонент создаётся динамически только при VoIPAvailable=true.
    property var callPageComponent: null

    Timer {
        id: sendUnlockTimer
        interval: 700
        onTriggered: root.sendLocked = false
    }

    // Drag-select автоскролл: триггерится ТОЛЬКО когда палец вышел за края
    // окна сообщений. Скорость пропорциональна тому, насколько далеко
    // палец от края (1 px за краем — еле едет, 200 px и дальше — на полной).
    Timer {
        id: dragSelectScrollTimer
        interval: 16
        repeat: true
        running: root._dragScrollDirection !== 0 && root.selectionMode
        onTriggered: {
            // Дистанция от пальца до края viewport'а (всегда > 0 пока тикаем).
            let distance = 0
            if (root._dragScrollDirection < 0) distance = -root._dragMouseY
            else distance = root._dragMouseY - listView.height
            if (distance <= 0) {
                root._dragScrollDirection = 0
                return
            }
            const speedFactor = Math.min(1, distance / 180)
            // Базовый шаг 2 px (минимум, как только вышли за край), потолок 16 px.
            const delta = root._dragScrollDirection * Math.max(2, Math.round(16 * speedFactor))
            const newY = root.clampListContentY(listView.contentY + delta)
            if (newY === listView.contentY) {
                // Упёрлись в край списка — всё равно применяем mode к крайнему.
                const clamp = root._dragScrollDirection < 0 ? 0 : msgModel.count - 1
                if (clamp >= 0 && clamp !== root._dragLastIndex) {
                    root.applyDragRange(root._dragStartIndex, clamp,
                                        root._dragSelectMode, root._dragInitialSelection)
                    root._dragLastIndex = clamp
                }
                return
            }
            listView.contentY = newY
            let idx = listView.indexAt(2, listView.contentY + root._dragMouseY)
            if (idx < 0) {
                idx = root._dragScrollDirection < 0 ? 0 : (msgModel.count - 1)
            }
            if (idx >= 0 && idx !== root._dragLastIndex) {
                root.applyDragRange(root._dragStartIndex, idx,
                                    root._dragSelectMode, root._dragInitialSelection)
                root._dragLastIndex = idx
            }
        }
    }

    function formatTime(ts) {
        let d = new Date(ts)
        return d.getHours().toString().padStart(2, '0') + ':'
             + d.getMinutes().toString().padStart(2, '0')
    }

    function deliveryStatusColor(status) {
        if (status === "read") return Theme.messageMetaOutgoing
        if (status === "delivered") return Theme.messageMetaOutgoing
        if (status === "failed") return Theme.error
        return Theme.messageMetaOutgoing
    }

    function replySummary(raw) {
        let text = (raw || "").replace(/\s+/g, " ").trim()
        return text.length > 120 ? text.substring(0, 120) + "..." : text
    }

    function replyAuthor(isMe, senderName) {
        if (isMe) return qsTr("Вы")
        if (senderName && senderName.length > 0) return senderName
        return root.peer
    }

    function fileNameFor(message) {
        if (message.filename && message.filename.length > 0) return message.filename
        if (message.text && message.text.length > 0) return message.text
        return "attachment.bin"
    }

    function formatFileSize(size) {
        let bytes = Number(size)
        if (!isFinite(bytes) || bytes < 0) return ""
        const units = [qsTr("Б"), qsTr("КБ"), qsTr("МБ"), qsTr("ГБ")]
        let unit = 0
        while (bytes >= 1024 && unit < units.length - 1) {
            bytes /= 1024
            ++unit
        }
        return (unit === 0 ? Math.round(bytes).toString() : bytes.toFixed(bytes >= 10 ? 1 : 2)) + " " + units[unit]
    }

    // Срок доступности эфемерного файла (unix-секунды) в читаемом виде.
    function formatEphemeralExpiry(ts) {
        var t = Number(ts)
        if (!isFinite(t) || t <= 0) return ""
        return new Date(t * 1000).toLocaleString(Qt.locale(), "dd.MM HH:mm")
    }

    function isImageMessage(kind, mimeType) {
        return kind === "image" || ((mimeType || "").indexOf("image/") === 0)
    }

    function openSaveDialog(messageId, filename) {
        root.pendingDownloadId = messageId
        root.pendingDownloadName = filename && filename.length > 0 ? filename : "attachment.bin"
        Chat.requestFileAccessPermissions()
        saveDialog.open()
    }

    // Собрать все уже загруженные (с готовым превью) фото-вложения диалога —
    // для листания в просмотрщике. Порядок — как в ленте. Учитывает и одиночные
    // image-сообщения, и плитки внутри мозаик (photo_group свёрнут composeMessages).
    function buildImageGallery() {
        var list = []
        for (var i = 0; i < msgModel.count; ++i) {
            var m = msgModel.get(i)
            if (m.kind === "photo_group") {
                var photos = []
                try { photos = JSON.parse(m.photos_json || "[]") } catch (e) { photos = [] }
                for (var j = 0; j < photos.length; ++j) {
                    var p = photos[j]
                    // Только committed-плитки с готовым превью (id + image://-source).
                    if (!p.id || p.id.length === 0) continue
                    if (!p.source || p.source.length === 0) continue
                    list.push({ source: p.source, id: p.id,
                                filename: (p.name && p.name.length > 0) ? p.name : "attachment.bin" })
                }
                continue
            }
            if (!isImageMessage(m.kind, m.mime_type)) continue
            var src = m.preview_source || ""
            if (src.length === 0) continue
            list.push({ source: src,
                        id: m.id,
                        filename: (m.filename && m.filename.length > 0) ? m.filename : "attachment.bin" })
        }
        return list
    }

    function openPhoto(source, messageId, filename) {
        if (source && source.length > 0) {
            var name = filename && filename.length > 0 ? filename : "attachment.bin"
            var gallery = buildImageGallery()
            var idx = -1
            for (var i = 0; i < gallery.length; ++i) {
                if (gallery[i].id === messageId) { idx = i; break }
            }
            if (idx >= 0)
                photoViewer.openGallery(gallery, idx)
            else
                photoViewer.open(source, messageId, name) // не в списке — одиночно
            return
        }
        Chat.ensureImagePreview(messageId)
        errorText.text = qsTr("Загрузка превью фото…")
        errorBar.visible = true
        errorTimer.restart()
    }

    // Маршрутизация выбранных фото: одно без подписи — обычной отправкой; иначе —
    // фото-группой (мозаика) с подписью из поля ввода.
    function sendSelectedPhotos(files) {
        if (!files || files.length === 0) return
        var paths = []
        for (var i = 0; i < files.length; ++i) paths.push(files[i].toString())
        var caption = msgInput.text
        if (paths.length === 1 && caption.trim().length === 0) {
            Chat.sendFile(paths[0])
            return
        }
        Chat.sendPhotoGroup(paths, caption)
        msgInput.clear()
        root.saveDraft()
    }

    // Свернуть пришедший плоский список в модель с мозаиками: image-сообщения с
    // group_id собираются в плитки сообщения-заголовка photo_group; ещё не
    // отправленные группы добавляются оптимистично из pendingGroups.
    function composeMessages(messages) {
        if (root._mosaicDebug) {
            var rawd = []
            for (var di = 0; di < messages.length; ++di) {
                var dm = messages[di]
                if (dm.kind === "image" || dm.kind === "photo_group")
                    rawd.push(dm.kind + " id=" + String(dm.id || "").slice(0, 8)
                              + " gid=" + String(dm.group_id || "∅").slice(0, 8)
                              + " seq=" + (dm.seq || 0))
            }
            console.log("[mosaic] IN n=" + messages.length + " imgs/pg=" + rawd.length
                        + " pending=" + Object.keys(root.pendingGroups).length + "\n  " + rawd.join("\n  "))
        }
        var groups = {}   // groupId -> ссылка на строку photo_group
        var committedCount = {}
        var out = []
        for (var i = 0; i < messages.length; ++i) {
            var m = messages[i]
            var gid = m.group_id || ""
            if (m.kind === "photo_group") {
                var row = {}
                for (var k in m) row[k] = m[k]
                row.photos = []
                groups[m.group_id] = row
                committedCount[m.group_id] = 0
                out.push(row)
            } else if (m.kind === "image" && gid.length > 0) {
                if (!groups[gid]) {
                    var synth = { kind: "photo_group", group_id: gid, caption: "", text: "",
                                  id: "grp:" + gid, sender: m.sender, sender_name: m.sender_name,
                                  isMe: m.isMe, status: m.status, ts: m.ts, seq: m.seq,
                                  reactions_json: "[]", photos: [] }
                    groups[gid] = synth
                    committedCount[gid] = 0
                    out.push(synth)
                }
                // Свои фото — локальный исходник (мгновенно, без image://secure/
                // скачивания и без мигания при коммите); чужие — через провайдер.
                groups[gid].photos.push({ id: m.id, source: m.local_preview || m.preview_source || "",
                                          name: m.filename || "", key: "", status: m.status })
                committedCount[gid] = (committedCount[gid] || 0) + 1
            } else {
                out.push(m)
            }
        }
        // Оптимистичные/частично-отправленные группы.
        for (var pgid in root.pendingGroups) {
            var pg = root.pendingGroups[pgid]
            var total = pg.photos.length
            var committed = committedCount[pgid] || 0
            if (groups[pgid]) {
                // Группа уже видна (часть фото committed) — дорисовываем хвост из ещё
                // не отправленных плиток (по порядку).
                if (committed >= total) { delete root.pendingGroups[pgid]; continue }
                for (var t = committed; t < total; ++t)
                    groups[pgid].photos.push({ id: "", source: pg.photos[t].source,
                                               name: pg.photos[t].name, key: pg.photos[t].key,
                                               status: "sending" })
                if (groups[pgid].caption.length === 0 && pg.caption.length > 0)
                    groups[pgid].caption = pg.caption
            } else {
                // Группа ещё не пришла из стора — целиком оптимистично.
                var tiles = []
                for (var j = 0; j < total; ++j)
                    tiles.push({ id: "", source: pg.photos[j].source, name: pg.photos[j].name,
                                 key: pg.photos[j].key, status: "sending" })
                out.push({ kind: "photo_group", group_id: pgid, caption: pg.caption, text: pg.caption,
                           id: "pending:" + pgid, sender: "", sender_name: qsTr("Вы"), isMe: true,
                           status: "sending", ts: pg.ts, seq: 0, reactions_json: "[]", photos: tiles })
            }
        }
        // Сериализуем плитки в JSON-строку (ListModel плохо хранит вложенные массивы).
        for (var n = 0; n < out.length; ++n) {
            if (out[n].kind === "photo_group") {
                out[n].photos_json = JSON.stringify(out[n].photos || [])
                delete out[n].photos
            }
        }
        if (root._mosaicDebug) {
            var pgRows = []
            for (var z = 0; z < out.length; ++z) {
                if (out[z].kind !== "photo_group") continue
                var ph = []
                try { ph = JSON.parse(out[z].photos_json || "[]") } catch (e) { ph = [] }
                var tids = []
                for (var y = 0; y < ph.length; ++y)
                    tids.push((ph[y].id ? String(ph[y].id).slice(0, 8) : "∅") + (ph[y].status === "sending" ? "·s" : ""))
                pgRows.push("PG id=" + String(out[z].id || "").slice(0, 12)
                            + " gid=" + String(out[z].group_id || "∅").slice(0, 8)
                            + " n=" + ph.length + " [" + tids.join(",") + "]")
            }
            console.log("[mosaic] OUT rows=" + out.length + " photo_groups=" + pgRows.length + "\n  " + pgRows.join("\n  "))
        }
        return out
    }

    function handleBackButton(): bool {
        if (photoViewer.visible) {
            photoViewer.close()
            return true
        }
        if (messageMenu.opened) {
            messageMenu.close()
            return true
        }
        if (root.selectionMode) {
            root.exitSelection()
            return true
        }
        if (root.searchActive) {
            root.closeSearch()
            return true
        }
        return false
    }

    function openSearch() {
        root.searchActive = true
        root.searchQuery = ""
        root.searchMatchIndices = []
        root.searchCurrentIndex = -1
        searchField.forceActiveFocus()
    }

    function closeSearch() {
        root.searchActive = false
        root.searchQuery = ""
        root.searchMatchIndices = []
        root.searchCurrentIndex = -1
    }

    function beginSelection(messageId) {
        root.selectedIds = {}
        root.selectionCount = 0
        root.selectionMode = true
        if (messageId && messageId.length > 0) root.toggleSelection(messageId)
    }

    function toggleSelection(messageId) {
        if (!messageId || messageId.length === 0) return
        // ВАЖНО: создаём НОВЫЙ объект, иначе QML не увидит изменения
        // (selectedIds остаётся той же ссылкой → bindings не пересчитываются).
        const next = Object.assign({}, root.selectedIds)
        if (next[messageId]) delete next[messageId]
        else next[messageId] = true
        root.selectedIds = next
        root.selectionCount = Object.keys(next).length
        if (root.selectionCount === 0) root.exitSelection()
    }

    function exitSelection() {
        root.selectionMode = false
        root.selectedIds = {}
        root.selectionCount = 0
        root._dragStartIndex = -1
        root._dragLastIndex = -1
        root._dragScrollDirection = 0
        root._dragSelectActive = false
    }

    // Применить drag к диапазону [min(startIdx, currentIdx), max(...)] поверх
    // baseline-снимка selectedIds, который был на момент начала drag'а.
    // mode === true → добавляем сообщения в выделение, false → снимаем.
    // Сообщения ВНЕ диапазона возвращаются к baseline-состоянию — поэтому
    // когда юзер сжимает диапазон обратно, лишние сообщения откатываются.
    function applyDragRange(startIdx, currentIdx, mode, baseline) {
        if (startIdx < 0 || currentIdx < 0) return
        const a = Math.min(startIdx, currentIdx)
        const b = Math.max(startIdx, currentIdx)
        const next = Object.assign({}, baseline)
        for (let i = a; i <= b; ++i) {
            const m = msgModel.get(i)
            if (!m || !m.id) continue
            if (mode) next[m.id] = true
            else delete next[m.id]
        }
        root.selectedIds = next
        root.selectionCount = Object.keys(next).length
    }

    // Расширить список id для удаления: photo_group (мозаика) свёрнут — под его
    // строкой скрыты отдельные image-сообщения. Удаляем и заголовок группы, и все
    // её плитки, иначе фото остаются (и мозаика «возрождается» синтетически).
    function expandDeleteIds(ids) {
        var rowById = {}
        for (var i = 0; i < msgModel.count; ++i) {
            var m = msgModel.get(i)
            rowById[m.id] = m
        }
        var out = {}
        for (var k = 0; k < ids.length; ++k) {
            var id = ids[k]
            var row = rowById[id]
            if (row && row.kind === "photo_group") {
                // Реальный заголовок (не синтетический "grp:"/оптимистичный "pending:").
                if (id.indexOf("grp:") !== 0 && id.indexOf("pending:") !== 0)
                    out[id] = true
                var photos = []
                try { photos = JSON.parse(row.photos_json || "[]") } catch (e) { photos = [] }
                for (var j = 0; j < photos.length; ++j)
                    if (photos[j].id && photos[j].id.length > 0) out[photos[j].id] = true
            } else {
                out[id] = true
            }
        }
        return Object.keys(out)
    }

    function confirmDeleteSelection() {
        const ids = root.expandDeleteIds(Object.keys(root.selectedIds))
        if (ids.length === 0) {
            root.exitSelection()
            return
        }
        Chat.deleteMessages(ids)
        root.exitSelection()
    }

    function messageMatchesQuery(message, queryLower) {
        if (!message || queryLower.length === 0) return false
        const text = String(message.text || "")
        if (text.length > 0 && text.toLowerCase().indexOf(queryLower) >= 0) return true
        const filename = String(message.filename || "")
        if (filename.length > 0 && filename.toLowerCase().indexOf(queryLower) >= 0) return true
        const senderName = String(message.sender_name || "")
        if (senderName.length > 0 && senderName.toLowerCase().indexOf(queryLower) >= 0) return true
        return false
    }

    function recomputeSearchMatches() {
        if (!root.searchActive || root.searchQuery.trim().length === 0) {
            root.searchMatchIndices = []
            root.searchCurrentIndex = -1
            return
        }
        const queryLower = root.searchQuery.trim().toLowerCase()
        const matches = []
        for (let i = 0; i < msgModel.count; ++i) {
            if (messageMatchesQuery(msgModel.get(i), queryLower)) matches.push(i)
        }
        root.searchMatchIndices = matches
        if (matches.length === 0) {
            root.searchCurrentIndex = -1
        } else {
            // Самое свежее совпадение (внизу) первым — обычно интереснее всего.
            root.searchCurrentIndex = matches.length - 1
            listView.positionViewAtIndex(matches[root.searchCurrentIndex], ListView.Center)
        }
    }

    function searchStep(delta) {
        if (root.searchMatchIndices.length === 0) return
        let next = root.searchCurrentIndex + delta
        if (next < 0) next = root.searchMatchIndices.length - 1
        if (next >= root.searchMatchIndices.length) next = 0
        root.searchCurrentIndex = next
        listView.positionViewAtIndex(root.searchMatchIndices[next], ListView.Center)
    }

    function openMessageMenu(sender, senderName, isMe, text, messageId, imageMessage, downloading, filename, item, localX, localY) {
        messageMenu.messageSender = sender || ""
        messageMenu.messageAuthor = root.replyAuthor(isMe, senderName)
        messageMenu.messageText = text || ""
        messageMenu.messageId = messageId || ""
        messageMenu.imageMessage = imageMessage === true
        messageMenu.downloading = downloading === true
        messageMenu.filename = filename && filename.length > 0 ? filename : "attachment.bin"

        const point = item.mapToItem(root, localX, localY)
        messageMenu.x = Math.max(8, Math.min(root.width - messageMenu.width - 8, point.x))
        messageMenu.y = Math.max(8, Math.min(root.height - messageMenu.height - 8, point.y))
        messageMenu.open()
    }

    function replyTo(messageId, sender, author, text) {
        pendingReplyId = messageId || ""
        pendingReplySender = sender || ""
        pendingReplyAuthor = author && author.length > 0 ? author : qsTr("Сообщение")
        pendingReplyText = replySummary(text)
        msgInput.forceActiveFocus()
    }

    function clearPendingReply() {
        pendingReplyId = ""
        pendingReplySender = ""
        pendingReplyAuthor = ""
        pendingReplyText = ""
    }

    function copyMessageText(text) {
        copyClipboard.text = text || ""
        copyClipboard.selectAll()
        copyClipboard.copy()
        copyToast.opacity = 1
        copyToastTimer.restart()
    }

    function hasValidDraftKey() {
        return (root.peer || "").length > 0
    }

    // Гейт сохранения: TextArea во время своей конструкции может выстрелить
    // textChanged с пустым текстом — это уничтожает только что прочитанный
    // черновик. Включаем сохранение только ПОСЛЕ того, как restoreDraft
    // (включая отложенную установку через draftRestoreTimer) отработал.
    property bool _saveDraftEnabled: false

    function saveDraft() {
        if (!_saveDraftEnabled) return
        if (!hasValidDraftKey()) return
        Chat.setDraft(root.peer, msgInput.text)
    }

    function clearDraft() {
        if (!hasValidDraftKey()) return
        Chat.clearDraft(root.peer)
    }

    // Хранится между restoreDraft() и срабатыванием draftRestoreTimer.
    property string _pendingDraft: ""
    // Отметка, что мы уже применили (или попытались) восстановить черновик
    // в этом инстансе ChatPage. Защищает от повторного применения, если
    // несколько триггеров (Component.onCompleted + Timer) сработают подряд.
    property bool _draftApplied: false

    function restoreDraft() {
        if (root._draftApplied) return
        if (!hasValidDraftKey()) return
        const saved = Chat.getDraft(root.peer)
        if (typeof saved !== "string" || saved.length === 0) {
            root._draftApplied = true
            // Включаем сохранение даже если черновика не было — пользователь
            // только что зашёл, дальнейший ввод нужно сохранять.
            root._saveDraftEnabled = true
            return
        }
        root._pendingDraft = saved
        draftRestoreTimer.restart()
    }

    // Откладываем установку текста до тех пор, пока TextArea внутри
    // ScrollView точно дотянет свои биндинги. На Linux + Qt 6.10 прямое
    // присвоение из Component.onCompleted иногда «съедалось» (msgInput
    // оставался пуст). 50ms — достаточно, чтобы первая отрисовка
    // отработала и TextArea стал «настоящим» редактором.
    Timer {
        id: draftRestoreTimer
        interval: 50
        repeat: false
        onTriggered: {
            const saved = root._pendingDraft
            if (!saved || saved.length === 0) { root._saveDraftEnabled = true; return }
            // clear() + insert() надёжнее, чем `text = saved`: явно
            // прокидывает изменение через QTextDocument, минуя возможные
            // конфликты с биндингом property text.
            msgInput.clear()
            msgInput.insert(0, saved)
            msgInput.cursorPosition = saved.length
            root._pendingDraft = ""
            root._draftApplied = true
            // Включаем save только ПОСЛЕ того, как restored-text применён,
            // иначе onTextChanged внутри clear() пройдёт через save и затрёт
            // только что восстановленные данные пустотой (clear() → text="").
            root._saveDraftEnabled = true
        }
    }

    function messageKey(message) {
        if (!message) return ""
        // Фото-группа: ключуем по СТАБИЛЬНОМУ group_id, а не по id строки. id
        // меняется при переходе оптимистичная("pending:"+gid) → committed(id
        // заголовка); если ключевать по нему, updateMessageModel посчитает порядок
        // изменившимся и пересоберёт ВСЮ модель (clear+append) → пересоздание всех
        // делегатов → все Image(cache:false) разом дёргают провайдер → LRU-кэш
        // (64МБ) вытесняет часть → «Failed to get image» + мерцание всех плиток +
        // «гирлянда» дублей мозаик. По group_id ключ стабилен → set()-путь.
        if (message.kind === "photo_group") {
            const gid = String(message.group_id || "")
            if (gid.length > 0) return "grp:" + gid
        }
        const id = String(message.id || "")
        if (id.length > 0) return "id:" + id
        const seq = Number(message.seq || 0)
        return seq > 0 ? "seq:" + seq : ""
    }

    function updateMessageModel(messages) {
        if (msgModel.count === messages.length) {
            let sameOrder = true
            for (let i = 0; i < messages.length; ++i) {
                if (messageKey(msgModel.get(i)) !== messageKey(messages[i])) {
                    sameOrder = false
                    break
                }
            }
            if (sameOrder) {
                for (let i = 0; i < messages.length; ++i)
                    msgModel.set(i, messages[i])
                return true
            }
        }

        msgModel.clear()
        for (let i = 0; i < messages.length; ++i)
            msgModel.append(messages[i])
        return false
    }

    function isListAtEnd() {
        if (listView.contentHeight <= listView.height) return true
        return listView.contentY >= root.listMaxContentY() - 24
    }

    function listMaxContentY() {
        const minY = listView.originY
        return Math.max(minY, minY + listView.contentHeight - listView.height)
    }

    function clampListContentY(y) {
        return Math.min(Math.max(y, listView.originY), root.listMaxContentY())
    }

    function visibleMessageAnchor() {
        const maxProbeY = Math.min(listView.height - 1, 160)
        for (let y = 1; y <= maxProbeY; y += 24) {
            const index = listView.indexAt(1, listView.contentY + y)
            if (index < 0) continue
            const item = listView.itemAtIndex(index)
            return {
                key: messageKey(msgModel.get(index)),
                offset: item ? listView.contentY - item.y : 0
            }
        }
        return { key: "", offset: 0 }
    }

    function scrollToMessageId(messageId) {
        if (!messageId || messageId.length === 0) return false
        for (let i = 0; i < msgModel.count; ++i) {
            if (msgModel.get(i).id === messageId) {
                listView.positionViewAtIndex(i, ListView.Center)
                return true
            }
        }
        return false
    }

    function restoreVisibleMessageAnchor(anchor) {
        if (!anchor || anchor.key.length === 0) return false
        for (let i = 0; i < msgModel.count; ++i) {
            if (messageKey(msgModel.get(i)) !== anchor.key) continue
            listView.positionViewAtIndex(i, ListView.Beginning)
            Qt.callLater(function() {
                const item = listView.itemAtIndex(i)
                if (!item) return
                const targetY = item.y + anchor.offset
                listView.contentY = root.clampListContentY(targetY)
            })
            return true
        }
        return false
    }

    Connections {
        target: Chat
        function onMessagesReceived(peer, messages) {
            if (peer !== root.peer) return
            root.messagesLoaded = true
            messages = root.composeMessages(messages)
            const wasEmpty = msgModel.count === 0
            const wasAtEnd = root.isListAtEnd()
            const anchor = wasEmpty || wasAtEnd ? null : root.visibleMessageAnchor()
            const previousContentY = listView.contentY
            if (root.updateMessageModel(messages)) {
                if (wasAtEnd) Qt.callLater(function() { if (listView) listView.positionViewAtEnd() })
                if (root.searchActive) root.recomputeSearchMatches()
                return
            }
            Qt.callLater(function() {
                if (!listView) return // страница могла быть разрушена до отложенного вызова
                if (wasEmpty || wasAtEnd) {
                    listView.positionViewAtEnd()
                    return
                }

                if (root.restoreVisibleMessageAnchor(anchor)) return

                listView.contentY = root.clampListContentY(previousContentY)
            })
            if (root.searchActive) root.recomputeSearchMatches()
        }
        function onSendError(msg) {
            errorText.text = msg
            errorBar.visible = true
            errorTimer.restart()
        }
        function onPhotoGroupStarted(groupId, caption, photos) {
            // Сохраняем оптимистичную группу и сразу показываем мозаику.
            var pg = root.pendingGroups
            pg[groupId] = { caption: caption, ts: Date.now(), photos: photos }
            root.pendingGroups = pg
            // СИНХРОННО перерисовываем из текущего кэша → все превью видны мгновенно
            // (локальные file://), без ожидания сетевого fetchMessages.
            Chat.emitCachedMessages()
        }
        function onFileProgress(transferKey, chunkIndex, total) {
            // НОВЫЙ объект — иначе переприсваивание той же ссылки не уведомляет
            // биндинг progressMap в PhotoMosaic (QML сравнивает var по ссылке).
            var up = Object.assign({}, root.uploadProgress)
            up[transferKey] = total > 0 ? Math.min(1, chunkIndex / total) : 0
            root.uploadProgress = up
            root.uploadTick++
        }
        function onAttachmentsPicked(uris) {
            // Мобильный нативный пикер фото — тот же путь, что мультивыбор на
            // десктопе: подпись берётся из поля ввода, 1 фото → обычно, >1 → группа.
            root.sendSelectedPhotos(uris)
        }
        function onReceiveError(msg) {
            root.downloadingAttachmentId = ""
            errorText.text = msg
            errorBar.visible = true
            errorTimer.restart()
        }
        function onAttachmentSaved(path) {
            root.downloadingAttachmentId = ""
            errorText.text = qsTr("Файл сохранён")
            errorBar.visible = true
            errorTimer.restart()
        }
        function onServerHistoryCleared(peer) {
            if (peer !== root.peer) return
            errorText.text = qsTr("Сообщения удалены")
            errorBar.visible = true
            errorTimer.restart()
        }
        function onServerHistoryError(msg) {
            errorText.text = msg
            errorBar.visible = true
            errorTimer.restart()
        }
    }

    Component.onCompleted: {
        Chat.openChat(root.peer)
        restoreDraft()
        applyShareTarget()
        if (VoIPAvailable) {
            root.callPageComponent = Qt.createComponent(
                Qt.resolvedUrl("CallPage.qml"), Component.PreferSynchronous);
            if (root.callPageComponent.status === Component.Error)
                console.warn("CallPage load error:", root.callPageComponent.errorString());
        }
    }

    function applyShareTarget() {
        if (root.shareTextInitial && root.shareTextInitial.length > 0) {
            const separator = (msgInput.text.length > 0 && !msgInput.text.endsWith("\n")) ? "\n" : ""
            msgInput.text = msgInput.text + separator + root.shareTextInitial
            root.shareTextInitial = ""
            saveDraft()
            msgInput.forceActiveFocus()
        }
        if (root.shareFilesInitial && root.shareFilesInitial.length > 0) {
            Chat.requestFileAccessPermissions()
            const files = root.shareFilesInitial
            root.shareFilesInitial = []
            let sent = 0
            for (let i = 0; i < files.length; ++i) {
                const candidate = files[i] ? String(files[i]) : ""
                if (candidate.length > 0) {
                    Chat.sendFile(candidate)
                    ++sent
                }
            }
            // Видимая обратная связь: даже если sendFile позже упадёт в
            // sendError, пользователь знает, что share-данные дошли до ChatPage.
            if (sent > 0) {
                errorText.text = qsTr("Получено вложений: %1 — идёт отправка").arg(sent)
                errorBar.visible = true
                errorTimer.restart()
            }
        }
    }
    Component.onDestruction: {
        saveDraft()
        Chat.stopChat()
    }

    ParaFileDialog {
        id: attachDialog
        title: qsTr("Выберите файл")
        mode: "open"
        onAccepted: Chat.sendFile(selectedFile)
    }

    ParaFileDialog {
        id: photoDialog
        title: qsTr("Выберите фото")
        // Мультивыбор: несколько фото уходят одной мозаикой-группой с подписью.
        mode: "openMultiple"
        nameFilters: [qsTr("Изображения (*.png *.jpg *.jpeg *.gif *.webp *.bmp *.tiff *.heic *.heif)"), qsTr("Все файлы (*)")]
        onAccepted: root.sendSelectedPhotos(selectedFiles)
    }

    ParaFileDialog {
        id: videoDialog
        title: qsTr("Выберите видео")
        mode: "open"
        nameFilters: [qsTr("Видео (*.mp4 *.mov *.mkv *.webm *.avi *.m4v *.3gp *.ogv)"), qsTr("Все файлы (*)")]
        onAccepted: Chat.sendFile(selectedFile)
    }

    ParaFileDialog {
        id: saveDialog
        mode: "folder"
        title: qsTr("Выберите папку для сохранения")
        onAccepted: {
            root.downloadingAttachmentId = root.pendingDownloadId
            Chat.saveAttachment(root.pendingDownloadId, selectedFolder)
        }
    }

    TextEdit {
        id: copyClipboard
        visible: false
    }

    Popup {
        id: messageMenu
        width: 274
        height: menuColumn.implicitHeight + topPadding + bottomPadding
        padding: 6
        modal: false
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        z: 900

        property string messageSender: ""
        property string messageAuthor: ""
        property string messageText: ""
        property string messageId: ""
        property bool imageMessage: false
        property bool downloading: false
        property string filename: "attachment.bin"

        background: Rectangle {
            color: Theme.bgCard
            radius: Theme.radiusMd
            border.width: 1
            border.color: Theme.border
        }

        contentItem: Column {
            id: menuColumn
            width: 284
            spacing: 2

            // Список быстрых реакций (настраиваемый синглтон Reactions).
            // Раскладывается в несколько строк (Flow); по достижении 3 строк
            // включается вертикальное пролистывание.
            Rectangle {
                id: reactionsContainer
                width: menuColumn.width
                radius: Theme.radiusSm
                color: "transparent"

                readonly property int cellSize: 30
                readonly property int cellSpacing: 6
                readonly property int maxRows: 3
                readonly property int maxFlowHeight: maxRows * cellSize + (maxRows - 1) * cellSpacing
                height: Math.min(reactionsFlowMenu.implicitHeight, maxFlowHeight) + 8

                Flickable {
                    id: reactionsFlick
                    anchors.fill: parent
                    anchors.margins: 4
                    clip: true
                    contentWidth: width
                    contentHeight: reactionsFlowMenu.implicitHeight
                    interactive: contentHeight > height
                    flickableDirection: Flickable.VerticalFlick
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                    Flow {
                        id: reactionsFlowMenu
                        width: reactionsFlick.width
                        spacing: reactionsContainer.cellSpacing

                        Repeater {
                            model: Reactions.list
                            delegate: Rectangle {
                                required property string modelData
                                width: reactionsContainer.cellSize
                                height: reactionsContainer.cellSize
                                radius: Theme.radiusSm
                                color: reactionArea.containsMouse ? Theme.bgInput : Theme.bgSecondary
                                border.width: 1
                                border.color: Theme.border
                                Text {
                                    anchors.centerIn: parent
                                    text: modelData
                                    font.pixelSize: 16
                                    font.family: Theme.fontFamily
                                }
                                MouseArea {
                                    id: reactionArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    enabled: messageMenu.messageId.length > 0
                                    onClicked: {
                                        messageMenu.close()
                                        Chat.sendReaction(messageMenu.messageId, modelData)
                                    }
                                }
                            }
                        }

                        // Кнопка настройки списка реакций (открывает эмодзи-пикер).
                        Rectangle {
                            width: reactionsContainer.cellSize
                            height: reactionsContainer.cellSize
                            radius: Theme.radiusSm
                            color: editReactionArea.containsMouse ? Theme.bgInput : Theme.bgSecondary
                            border.width: 1
                            border.color: Theme.border
                            AppIcon {
                                anchors.centerIn: parent
                                width: 16; height: 16
                                name: "plus"
                                iconColor: Theme.accentHover
                                strokeWidth: 2.2
                            }
                            MouseArea {
                                id: editReactionArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    messageMenu.close()
                                    reactionsConfig.open()
                                }
                            }
                        }
                    }
                }
            }

            Rectangle {
                width: menuColumn.width
                height: 34
                radius: Theme.radiusSm
                color: replyMenuArea.containsMouse ? Theme.bgInput : "transparent"
                Text {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    text: qsTr("Ответить")
                    color: Theme.textPrimary
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    elide: Text.ElideRight
                }
                MouseArea {
                    id: replyMenuArea
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: {
                        messageMenu.close()
                        root.replyTo(messageMenu.messageId, messageMenu.messageSender, messageMenu.messageAuthor,
                                     messageMenu.messageText)
                    }
                }
            }

            Rectangle {
                width: menuColumn.width
                height: 34
                radius: Theme.radiusSm
                color: copyMenuArea.containsMouse && copyMenuArea.enabled ? Theme.bgInput : "transparent"
                Text {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    text: qsTr("Скопировать")
                    color: messageMenu.messageText.length > 0 ? Theme.textPrimary : Theme.textHint
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    elide: Text.ElideRight
                }
                MouseArea {
                    id: copyMenuArea
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: messageMenu.messageText.length > 0
                    onClicked: {
                        messageMenu.close()
                        root.copyMessageText(messageMenu.messageText)
                    }
                }
            }

            Rectangle {
                width: menuColumn.width
                height: visible ? 34 : 0
                visible: messageMenu.imageMessage
                radius: Theme.radiusSm
                color: savePhotoMenuArea.containsMouse && savePhotoMenuArea.enabled ? Theme.bgInput : "transparent"
                Text {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    text: qsTr("Сохранить фото")
                    color: savePhotoMenuArea.enabled ? Theme.accentHover : Theme.textHint
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    elide: Text.ElideRight
                }
                MouseArea {
                    id: savePhotoMenuArea
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: !messageMenu.downloading
                    onClicked: {
                        messageMenu.close()
                        root.openSaveDialog(messageMenu.messageId, messageMenu.filename)
                    }
                }
            }

            Rectangle {
                width: menuColumn.width
                height: 1
                color: Theme.separator
            }

            Rectangle {
                width: menuColumn.width
                height: 34
                radius: Theme.radiusSm
                color: deleteMenuArea.containsMouse && deleteMenuArea.enabled ? Theme.bgInput : "transparent"
                Text {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    text: qsTr("Удалить")
                    color: deleteMenuArea.enabled ? Theme.error : Theme.textHint
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    elide: Text.ElideRight
                }
                MouseArea {
                    id: deleteMenuArea
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: messageMenu.messageId.length > 0
                    onClicked: {
                        const id = messageMenu.messageId
                        messageMenu.close()
                        if (id.length > 0) Chat.deleteMessages(root.expandDeleteIds([id]))
                    }
                }
            }
        }
    }

    Popup {
        id: inputMenu
        // Базовая ширина для «Очистить/Копировать/Вставить» — 100; при наличии
        // орфографии добавляется компактный пункт «Орфография ▸» (подсказки — в
        // подменё, чтобы основное меню не разрасталось и не сбивалось позицией).
        width: (hasSpellSuggestions && !root.isMobileOs) ? 150 : 100
        height: inputMenuColumn.implicitHeight + topPadding + bottomPadding
        padding: 6
        modal: false
        focus: false
        // Пока открыто подменю — НЕ закрываемся по клику снаружи (иначе клик по
        // подсказке в подменю закрывал бы основное меню раньше, чем сработает
        // выбор). По Escape закрываемся всегда. Флаг (а не прямая ссылка на
        // spellSubmenu.opened) — т.к. spellSubmenu объявлен ниже и forward-ссылка
        // в биндинге, вычисляемом при создании, кидает ReferenceError.
        property bool submenuOpen: false
        closePolicy: submenuOpen
                     ? Popup.CloseOnEscape
                     : (Popup.CloseOnEscape | Popup.CloseOnPressOutside)
        z: 901
        onClosed: spellSubmenu.close()

        // Якорь = точка правого клика (в координатах root). x/y — РЕАКТИВНЫЕ
        // биндинги от якоря и фактических width/height: когда появляется пункт
        // «Орфография» и высота растёт, позиция пересчитывается сама (раньше
        // высота читалась до layout'а → меню «уезжало»).
        property real anchorX: 0
        property real anchorY: 0
        x: {
            var tx = anchorX - width
            if (tx < 8) tx = 8
            if (tx + width > root.width - 8) tx = root.width - width - 8
            return Math.max(8, tx)
        }
        y: {
            var ty = anchorY - height
            if (ty < 8) ty = Math.min(anchorY + 8, root.height - height - 8)
            return Math.max(8, ty)
        }

        // Контекст misspelled-word'а, выставляется перед открытием меню в TextArea.onPressed.
        property int spellStart: -1
        property int spellLength: 0
        property string spellWord: ""
        property var spellSuggestions: []
        readonly property bool hasSpellSuggestions: spellStart >= 0 && spellSuggestions && spellSuggestions.length > 0

        function applySuggestion(replacement) {
            if (spellStart < 0 || spellLength <= 0) return
            msgInput.remove(spellStart, spellStart + spellLength)
            msgInput.insert(spellStart, replacement)
            spellStart = -1
            spellLength = 0
            spellWord = ""
            spellSuggestions = []
            // Закрываем сами оба меню отсюда (из scope inputMenu spellSubmenu
            // виден; изнутри его собственного делегата id не резолвится — QML-кварк
            // с contentItem). close() → onClosed → spellSubmenu.close().
            close()
        }

        background: Rectangle {
            color: Theme.bgCard
            radius: Theme.radiusMd
            border.width: 1
            border.color: Theme.border
        }
        contentItem: Column {
            id: inputMenuColumn
            width: inputMenu.width - inputMenu.leftPadding - inputMenu.rightPadding
            spacing: 2

            // Пункт «Орфография ▸» (только ПК): открывает подменю с подсказками.
            // Подсказки вынесены в подменю, чтобы основное меню оставалось
            // компактным и не «уезжало» с позиции при их появлении.
            Rectangle {
                visible: inputMenu.hasSpellSuggestions && !root.isMobileOs
                width: inputMenuColumn.width
                height: visible ? 34 : 0
                radius: Theme.radiusSm
                color: spellSubmenuArea.containsMouse ? Theme.bgInput : "transparent"
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.leftMargin: 10
                    text: qsTr("Орфография")
                    color: Theme.textPrimary
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                }
                AppIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.right: parent.right
                    anchors.rightMargin: 8
                    width: 15; height: 15
                    name: "chevronRight"
                    iconColor: Theme.textSecondary
                    strokeWidth: 2
                }
                MouseArea {
                    id: spellSubmenuArea
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: spellSubmenu.openBeside(inputMenu)
                }
            }

            Rectangle {
                visible: inputMenu.hasSpellSuggestions && !root.isMobileOs
                width: inputMenuColumn.width
                height: visible ? 1 : 0
                color: Theme.separator
            }

            Repeater {
                model: [qsTr("Очистить"), qsTr("Копировать"), qsTr("Вставить")]
                delegate: Rectangle {
                    required property int index
                    required property string modelData
                    width: inputMenuColumn.width
                    height: 34
                    radius: Theme.radiusSm
                    color: inputMenuArea.containsMouse ? Theme.bgInput : "transparent"
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: 10
                        text: modelData
                        color: Theme.textPrimary
                        font.pixelSize: Theme.fontSm
                        font.family: Theme.fontFamily
                    }
                    MouseArea {
                        id: inputMenuArea
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: {
                            inputMenu.close()
                            if (index === 0) msgInput.clear()
                            else if (index === 1) {
                                if (msgInput.selectedText.length == 0) msgInput.selectAll()
                                msgInput.copy()
                            }
                            else  msgInput.paste()
                        }
                    }
                }
            }
        }
    }

    // Подменю «Орфография» (ПК): список подсказок, открывается сбоку от inputMenu.
    Popup {
        id: spellSubmenu
        width: 200
        height: spellSubmenuColumn.implicitHeight + topPadding + bottomPadding
        padding: 6
        modal: false
        focus: false
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        z: 902
        onOpened: inputMenu.submenuOpen = true
        onClosed: inputMenu.submenuOpen = false

        function openBeside(menu) {
            // Справа от основного меню; если не влезает по ширине — слева.
            var gx = menu.x + menu.width + 4
            if (gx + width > root.width - 8) gx = menu.x - width - 4
            x = Math.max(8, gx)
            // По вертикали выравниваем по верху меню, но не вылезаем за низ экрана.
            y = Math.max(8, Math.min(menu.y, root.height - height - 8))
            open()
        }

        background: Rectangle {
            color: Theme.bgCard
            radius: Theme.radiusMd
            border.width: 1
            border.color: Theme.border
        }
        contentItem: Column {
            id: spellSubmenuColumn
            width: spellSubmenu.width - spellSubmenu.leftPadding - spellSubmenu.rightPadding
            spacing: 2
            Repeater {
                model: inputMenu.spellSuggestions
                delegate: Rectangle {
                    required property string modelData
                    width: spellSubmenuColumn.width
                    height: 32
                    radius: Theme.radiusSm
                    color: spellSubArea.containsMouse ? Theme.bgInput : "transparent"
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        text: modelData
                        color: Theme.accentHover
                        font.pixelSize: Theme.fontSm
                        font.family: Theme.fontFamily
                        font.weight: Font.Medium
                        elide: Text.ElideRight
                    }
                    MouseArea {
                        id: spellSubArea
                        anchors.fill: parent
                        hoverEnabled: true
                        // applySuggestion сама закрывает оба меню (ссылка на
                        // spellSubmenu изнутри его делегата не резолвится — QML-кварк).
                        onClicked: inputMenu.applySuggestion(modelData)
                    }
                }
            }
        }
    }

    // Меню «+» рядом с полем ввода — выбор типа вложения.
    Popup {
        id: attachMenu
        width: 184
        height: attachMenuColumn.implicitHeight + topPadding + bottomPadding
        padding: 6
        modal: false
        focus: false
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        z: 901
        background: Rectangle {
            color: Theme.bgCard
            radius: Theme.radiusMd
            border.width: 1
            border.color: Theme.border
        }
        contentItem: Column {
            id: attachMenuColumn
            width: attachMenu.width - attachMenu.leftPadding - attachMenu.rightPadding
            spacing: 2

            Repeater {
                model: [
                    { label: qsTr("Файл"),   icon: "file"  },
                    { label: qsTr("Фото"),   icon: "image" },
                    { label: qsTr("Видео"),  icon: "video" }
                ]
                delegate: Rectangle {
                    required property int index
                    required property var modelData
                    width: attachMenuColumn.width
                    height: 38
                    radius: Theme.radiusSm
                    color: attachItemArea.containsMouse ? Theme.bgInput : "transparent"
                    Row {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        spacing: 10
                        AppIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 20; height: 20
                            name: modelData.icon
                            iconColor: Theme.accentHover
                            strokeWidth: 1.8
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: modelData.label
                            color: Theme.textPrimary
                            font.pixelSize: Theme.fontSm
                            font.family: Theme.fontFamily
                        }
                    }
                    MouseArea {
                        id: attachItemArea
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: {
                            attachMenu.close()
                            Chat.requestFileAccessPermissions()
                            if (index === 0) {
                                attachDialog.open()
                            } else if (index === 1) {
                                // На Android — системный photo picker (галерея),
                                // на desktop — обычный FileDialog с фильтром изображений.
                                if (Qt.platform.os === "android") Chat.pickPhotoFromGallery()
                                else photoDialog.open()
                            } else {
                                if (Qt.platform.os === "android") Chat.pickVideoFromGallery()
                                else videoDialog.open()
                            }
                        }
                    }
                }
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ── Header ────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            height: 56
            color: Theme.bgDark

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width; height: 2
                color: Theme.accentDim
            }

            // Селекшн-тулбар поверх обычной шапки.
            Rectangle {
                anchors.fill: parent
                color: Theme.bgDark
                visible: root.selectionMode
                z: 10
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 12
                    spacing: 8

                    Rectangle {
                        width: 40; height: 40
                        radius: Theme.radiusSm
                        color: cancelSelArea.containsMouse ? Theme.bgCard : "transparent"
                        border.width: 1
                        border.color: Theme.border
                        AppIcon {
                            anchors.centerIn: parent
                            width: 22; height: 22
                            name: "close"
                            iconColor: Theme.textPrimary
                            strokeWidth: 2.2
                        }
                        MouseArea {
                            id: cancelSelArea
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: root.exitSelection()
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        text: root.selectionCount + (root.selectionCount === 1 ? qsTr(" сообщение") : qsTr(" сообщений"))
                        color: Theme.textPrimary
                        font.pixelSize: Theme.fontMd
                        font.family: Theme.fontFamily
                        font.weight: Font.Medium
                        elide: Text.ElideRight
                    }

                    Rectangle {
                        width: 40; height: 40
                        radius: Theme.radiusSm
                        color: root.selectionCount > 0 ? Theme.accent : Theme.bgCard
                        border.width: 1
                        border.color: root.selectionCount > 0 ? Theme.accent : Theme.border
                        opacity: root.selectionCount > 0 ? 1 : 0.45
                        AppIcon {
                            anchors.centerIn: parent
                            width: 22; height: 22
                            name: "trash"
                            iconColor: root.selectionCount > 0 ? Theme.textPrimary : Theme.textSecondary
                            strokeWidth: 2.2
                        }
                        MouseArea {
                            id: deleteSelArea
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: root.selectionCount > 0
                            onClicked: deleteSelectionConfirm.open()
                        }
                    }
                }
            }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 16
                spacing: 8
                visible: !root.selectionMode

                // Back button
                Rectangle {
                    width: 40; height: 40
                    radius: Theme.radiusSm
                    color: backArea.containsMouse ? Theme.bgCard : "transparent"
                    border.width: backArea.containsMouse ? 1 : 0
                    border.color: Theme.border

                    AppIcon {
                        anchors.centerIn: parent
                        width: 24
                        height: 24
                        name: "chevronLeft"
                        iconColor: Theme.accentHover
                        strokeWidth: 2.2
                    }
                    MouseArea {
                        id: backArea
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: root.back()
                    }
                }

                // Avatar
                Rectangle {
                    width: 36; height: 36
                    radius: Theme.radiusSm
                    color: Theme.bgCard
                    border.width: 1
                    border.color: Theme.accentDim

                    Text {
                        anchors.centerIn: parent
                        text: root.peer.charAt(0).toUpperCase()
                        color: Theme.accentHover
                        font.pixelSize: Theme.fontMd
                        font.weight: Font.Bold
                    }
                }

                Column {
                    Layout.fillWidth: true
                    spacing: 2
                    Text {
                        text: root.peer
                        color: Theme.textPrimary
                        font.pixelSize: Theme.fontMd
                        font.family: Theme.fontFamily
                        font.weight: Font.Medium
                    }
                    Row {
                        spacing: 8
                        Toggle {
                            id: receiptsSwitch
                            width:  40
                            height: 20
                            anchors.verticalCenter: parent.verticalCenter
                            checked: Chat.readReceiptsEnabled
                            palette.text: Theme.controlText
                            onToggled: function(checked) { Chat.setReadReceiptsEnabled(checked) }
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: qsTr("Уведомлять о прочтении")
                            color: Theme.success
                            font.pixelSize: Theme.fontXs
                            font.family: Theme.fontFamily
                        }
                    }
                }

                // Поиск по диалогу
                Rectangle {
                    Layout.preferredWidth: 40
                    Layout.preferredHeight: 40
                    Layout.alignment: Qt.AlignVCenter
                    radius: Theme.radiusSm
                    color: searchHeaderArea.containsMouse ? Theme.bgCard : "transparent"
                    border.width: searchHeaderArea.containsMouse ? 1 : 0
                    border.color: Theme.border

                    AppIcon {
                        anchors.centerIn: parent
                        width: 22; height: 22
                        name: "search"
                        iconColor: root.searchActive ? Theme.accent : Theme.accentHover
                        strokeWidth: 2
                    }

                    MouseArea {
                        id: searchHeaderArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (root.searchActive) root.closeSearch()
                            else root.openSearch()
                        }
                    }
                }

                // Видна только если voip собран. Наличие master_key проверяется перед стартом вызова.
                CallButton {
                    visible: VoIPAvailable
                    onClicked: {
                        if (!VoIPAvailable) return
                        const mk = CallSignaling.masterKeyFor(root.peer)
                        if (mk.length === 0) {
                            console.warn("No master key for peer", root.peer)
                            return
                        }
                        if (!root.callPageComponent || root.callPageComponent.status !== Component.Ready) {
                            console.warn("CallPage component not ready")
                            return
                        }
                        if (!CallControl.startOutgoingCall(root.peer, mk)) {
                            console.warn("startOutgoingCall failed")
                            return
                        }
                        stackView.push(root.callPageComponent, { mode: "outgoing", peerName: root.peer })
                    }
                }
            }
        }

        // ── Search bar ────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: root.searchActive ? 48 : 0
            visible: root.searchActive
            color: Theme.bgSecondary

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width; height: 1
                color: Theme.separator
            }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                anchors.topMargin: 6
                anchors.bottomMargin: 6
                spacing: 6

                Rectangle {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    radius: Theme.radiusMd
                    color: Theme.bgInput
                    border.color: Theme.border
                    border.width: 1

                    TextField {
                        id: searchField
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        color: Theme.textPrimary
                        font.pixelSize: Theme.fontSm
                        font.family: Theme.fontFamily
                        background: null
                        verticalAlignment: TextInput.AlignVCenter
                        // Обнуляем паддинги, чтобы вводимый текст начинался
                        // ровно там же, где placeholder.
                        topPadding: 0
                        bottomPadding: 0
                        leftPadding: 0
                        rightPadding: 0
                        selectByMouse: true
                        text: root.searchQuery
                        onTextChanged: {
                            if (text === root.searchQuery) return
                            root.searchQuery = text
                            root.recomputeSearchMatches()
                        }
                        Keys.onEscapePressed: root.closeSearch()
                        Keys.onReturnPressed: root.searchStep(-1)

                        // Собственный placeholder: встроенный в Material-стиле
                        // (Android) всплывает вверх и наезжает на границу поля.
                        Text {
                            anchors.fill: parent
                            verticalAlignment: Text.AlignVCenter
                            visible: searchField.text.length === 0
                            text: qsTr("Поиск по диалогу…")
                            color: Theme.textHint
                            font: searchField.font
                            elide: Text.ElideRight
                        }
                    }
                }

                Text {
                    Layout.alignment: Qt.AlignVCenter
                    text: {
                        if (root.searchQuery.trim().length === 0) return ""
                        if (root.searchMatchIndices.length === 0) return "0"
                        return (root.searchCurrentIndex + 1) + "/" + root.searchMatchIndices.length
                    }
                    color: root.searchMatchIndices.length === 0 && root.searchQuery.trim().length > 0
                           ? Theme.error : Theme.textSecondary
                    font.pixelSize: Theme.fontXs
                    font.family: Theme.fontFamily
                }

                Rectangle {
                    Layout.preferredWidth: 32
                    Layout.preferredHeight: 32
                    Layout.alignment: Qt.AlignVCenter
                    radius: Theme.radiusSm
                    color: prevArea.containsMouse ? Theme.bgCard : "transparent"
                    border.width: 1
                    border.color: Theme.border
                    AppIcon {
                        anchors.centerIn: parent
                        width: 16; height: 16
                        name: "chevronLeft"
                        iconColor: Theme.accentHover
                        strokeWidth: 2
                        rotation: 90
                    }
                    MouseArea {
                        id: prevArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.searchStep(1)
                    }
                }

                Rectangle {
                    Layout.preferredWidth: 32
                    Layout.preferredHeight: 32
                    Layout.alignment: Qt.AlignVCenter
                    radius: Theme.radiusSm
                    color: nextArea.containsMouse ? Theme.bgCard : "transparent"
                    border.width: 1
                    border.color: Theme.border
                    AppIcon {
                        anchors.centerIn: parent
                        width: 16; height: 16
                        name: "chevronLeft"
                        iconColor: Theme.accentHover
                        strokeWidth: 2
                        rotation: -90
                    }
                    MouseArea {
                        id: nextArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.searchStep(-1)
                    }
                }

                Rectangle {
                    Layout.preferredWidth: 32
                    Layout.preferredHeight: 32
                    Layout.alignment: Qt.AlignVCenter
                    radius: Theme.radiusSm
                    color: searchCloseArea.containsMouse ? Theme.bgCard : "transparent"
                    border.width: 1
                    border.color: Theme.border
                    AppIcon {
                        anchors.centerIn: parent
                        width: 16; height: 16
                        name: "close"
                        iconColor: Theme.accentHover
                        strokeWidth: 2
                    }
                    MouseArea {
                        id: searchCloseArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.closeSearch()
                    }
                }
            }
        }

        // ── Message list ──────────────────────────────────────
        Item {
            id: messageListPane
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true

            ListView {
                id: listView
                anchors.fill: parent
                clip: true
                spacing: 4
                // Пока зажат чекбокс drag-select, отключаем встроенный Flickable, иначе
                // ListView перехватывает вертикальный жест и устраивает flick
                // (визуально это и был тот «телепорт на страницу»).
                interactive: !root._dragSelectActive

                model: ListModel { id: msgModel }

                ScrollBar.vertical: ScrollBar {}

                // «Прилипание к низу»: если пользователь стоит у последнего
                // сообщения, при изменении высоты вьюпорта (открытие/закрытие
                // виртуальной клавиатуры) список остаётся у низа, а не уезжает
                // за обрез. Флаг обновляется только когда жест пролистывания
                // действительно завершён, чтобы не сбрасываться во время скролла.
                property bool stickToBottom: true
                onHeightChanged: if (stickToBottom) Qt.callLater(positionViewAtEnd)
                // Высота делегатов с MessageText (Loader/Repeater/измерители) досчитывается
                // на несколько polish-проходов позже, чем у простого Text, поэтому
                // одиночного positionViewAtEnd после отправки мало — view встаёт на
                // «низ», который потом подрастает. Пока стоим у низа и нет жеста —
                // переставляем в конец при каждом росте contentHeight.
                onContentHeightChanged: if (stickToBottom && !moving) Qt.callLater(positionViewAtEnd)
                onMovementEnded: stickToBottom = root.isListAtEnd()
                onDraggingChanged: if (!dragging) stickToBottom = root.isListAtEnd()

                delegate: Item {
                    width: listView.width
                    height: bubble.implicitHeight + 8

                    readonly property int delegateIndex: index
                    readonly property bool isSearchMatch: root.searchActive && root.searchMatchIndices.indexOf(delegateIndex) >= 0
                    readonly property bool isSearchCurrent: isSearchMatch
                                                           && root.searchCurrentIndex >= 0
                                                           && root.searchMatchIndices[root.searchCurrentIndex] === delegateIndex
                    readonly property bool isMe: model.isMe === true
                    readonly property string mimeType: model.mime_type || ""
                    readonly property bool isImage: root.isImageMessage(model.kind, mimeType)
                    readonly property bool isPhotoGroup: model.kind === "photo_group"
                    readonly property var groupPhotos: {
                        if (!isPhotoGroup) return []
                        try { return JSON.parse(model.photos_json || "[]") } catch (e) { return [] }
                    }
                    readonly property bool hasAttachment: model.kind === "file" || model.kind === "image" || model.kind === "voice" || isImage
                    readonly property bool showMessageText: !hasAttachment && !isPhotoGroup && (model.text || "").length > 0
                    readonly property bool showFileCard: hasAttachment && !isImage
                    readonly property string attachmentName: root.fileNameFor(model)
                    readonly property string previewSource: model.preview_source || ""
                    readonly property bool hasReply: (model.reply_to_id || "").length > 0
                    readonly property bool isDownloading: root.downloadingAttachmentId === model.id
                    readonly property var reactions: {
                        const raw = model.reactions_json || ""
                        if (raw.length === 0) return []
                        try { return JSON.parse(raw) } catch (e) { return [] }
                    }
                    readonly property bool isSelected: root.selectionMode && root.selectedIds[model.id] === true

                // Чекбокс-индикатор сбоку от пузыря (снаружи).
                Rectangle {
                    id: selectionCheckbox
                    width: 24; height: 24
                    radius: 12
                    z: 60
                    anchors.verticalCenter: bubble.verticalCenter
                    anchors.right: isMe ? bubble.left : undefined
                    anchors.left:  isMe ? undefined  : bubble.right
                    anchors.rightMargin: isMe ? 8 : 0
                    anchors.leftMargin:  isMe ? 0 : 8
                    visible: root.selectionMode
                    color: isSelected ? Theme.accent : Theme.bgPrimary
                    border.width: 2
                    border.color: isSelected ? Theme.accent : Theme.border
                    AppIcon {
                        anchors.centerIn: parent
                        width: 18; height: 18
                        name: "check"
                        iconColor: "#FFFFFF"
                        strokeWidth: 3
                        visible: isSelected
                    }

                    // Tap по чекбоксу — тоггл выделения. Press-and-drag —
                    // Telegram-style: режим (add/remove) определяется тем, был
                    // ли стартовый чекбокс выбран в момент нажатия.
                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -8   // комфортная хит-зона
                        preventStealing: true
                        enabled: root.selectionMode
                        propagateComposedEvents: false
                        z: 70

                        property real pressScreenY: 0
                        property bool dragHappened: false

                        onPressed: function(mouse) {
                            listView.cancelFlick()
                            root._dragSelectActive = true
                            const p = mapToItem(listView, mouse.x, mouse.y)
                            pressScreenY = p.y
                            dragHappened = false
                            root._dragStartIndex = delegateIndex
                            root._dragLastIndex = delegateIndex
                            root._dragMouseY = p.y
                            root._dragScrollDirection = 0
                            // Режим drag'а определяется на старте: если start
                            // не выбран — drag добавляет, если выбран — снимает.
                            root._dragSelectMode = !isSelected
                            root._dragInitialSelection = Object.assign({}, root.selectedIds)
                        }
                        onPositionChanged: function(mouse) {
                            if (!pressed) return
                            const p = mapToItem(listView, mouse.x, mouse.y)
                            // Порог 8 px, чтобы случайные дрожания не превращали
                            // обычный тап в drag.
                            if (!dragHappened && Math.abs(p.y - pressScreenY) > 8) {
                                dragHappened = true
                                root._dragSelectActive = true
                                // Сразу применяем mode к стартовому сообщению.
                                root.applyDragRange(root._dragStartIndex, root._dragStartIndex,
                                                    root._dragSelectMode, root._dragInitialSelection)
                            }
                            root._dragMouseY = p.y
                            if (!dragHappened) return
                            const idx = listView.indexAt(2, listView.contentY + p.y)
                            if (idx >= 0 && idx !== root._dragLastIndex) {
                                root.applyDragRange(root._dragStartIndex, idx,
                                                    root._dragSelectMode, root._dragInitialSelection)
                                root._dragLastIndex = idx
                            }
                            if (p.y < 0) root._dragScrollDirection = -1
                            else if (p.y > listView.height) root._dragScrollDirection = 1
                            else root._dragScrollDirection = 0
                        }
                        onReleased: {
                            if (!dragHappened) root.toggleSelection(model.id)
                            root._dragStartIndex = -1
                            root._dragLastIndex = -1
                            root._dragScrollDirection = 0
                            root._dragSelectActive = false
                            dragHappened = false
                            // Если за время drag'а всё выделение убрали — выйти из режима.
                            if (root.selectionCount === 0) root.exitSelection()
                        }
                        onCanceled: {
                            root._dragStartIndex = -1
                            root._dragLastIndex = -1
                            root._dragScrollDirection = 0
                            root._dragSelectActive = false
                            dragHappened = false
                        }
                    }
                }

                // Перехватчик кликов в режиме выделения: тап по любой части
                // делегата тоггл'ит выделение, без открытия фото/файла/реакций.
                MouseArea {
                    anchors.fill: parent
                    visible: root.selectionMode
                    enabled: root.selectionMode
                    z: 50
                    hoverEnabled: false
                    onClicked: root.toggleSelection(model.id)
                }

                // На десктопе клик левой кнопкой мыши «напротив» пузыря (по
                // строке делегата, но не по самому пузырю) сразу входит в
                // режим выделения и выбирает это сообщение.
                // z:-1 — строго НИЖЕ пузыря: клики по изображению/мозаике/файлу
                // должны доходить до их MouseArea (открытие вьювера и т.п.), а
                // этот перехватчик ловит только пустую область строки вне пузыря.
                MouseArea {
                    anchors.fill: parent
                    visible: !root.selectionMode && !root.isMobileOs
                    enabled: !root.selectionMode && !root.isMobileOs
                    acceptedButtons: Qt.LeftButton
                    hoverEnabled: false
                    z: -1
                    onClicked: function(mouse) {
                        if (model.id && model.id.length > 0) root.beginSelection(model.id)
                    }
                }
                readonly property bool hasReactions: reactions && reactions.length > 0

                Component.onCompleted: {
                    if (isImage && previewSource.length === 0)
                        Chat.ensureImagePreview(model.id)
                }

                Rectangle {
                    id: bubble
                    anchors.right: isMe ? parent.right : undefined
                    anchors.left:  isMe ? undefined     : parent.left
                    anchors.rightMargin: isMe ? 12 : 0
                    anchors.leftMargin:  isMe ? 0  : 12
                    anchors.verticalCenter: parent.verticalCenter

                    width: Math.min(Math.max(showMessageText ? msgText.implicitWidth : 0,
                                             hasReply ? messageReplyPreview.implicitWidth : 0,
                                             isImage ? imagePreview.implicitWidth : 0,
                                             isPhotoGroup ? photoMosaic.implicitWidth : 0,
                                             showFileCard ? fileCard.implicitWidth : 0,
                                             hasReactions ? reactionsFlow.implicitWidth : 0,
                                             metaRow.implicitWidth,
                                             isMe ? 0 : senderLabel.implicitWidth) + 24,
                                      listView.width * 0.72)
                    implicitHeight: (isMe ? 0 : senderLabel.implicitHeight + 2)
                                  + (hasReply ? messageReplyPreview.implicitHeight + 6 : 0)
                                  + (showMessageText ? msgText.implicitHeight : 0)
                                  + (isImage ? imagePreview.implicitHeight + 6 : 0)
                                  + (isPhotoGroup ? photoMosaic.implicitHeight + 6 : 0)
                                  + (showFileCard ? fileCard.implicitHeight + 6 : 0)
                                  + (hasReactions ? reactionsFlow.implicitHeight + 6 : 0)
                                  + metaRow.implicitHeight + 16
                    radius: Theme.radiusMd
                    color: isMe ? Theme.bgButton : Theme.bgSecondary
                    border.width: isSearchMatch ? (isSearchCurrent ? 3 : 2) : 1
                    border.color: isSearchMatch
                                  ? (isSearchCurrent ? Theme.accent : Theme.accentHover)
                                  : (isMe ? Theme.accentDim : Theme.border)

                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        hoverEnabled: false
                        onClicked: function(mouse) {
                            if (mouse.button === Qt.RightButton || (root.isMobileOs && !root.selectionMode)) {
                                root.openMessageMenu(model.sender, model.sender_name, isMe, model.text, model.id,
                                                     isImage, isDownloading, attachmentName,
                                                     bubble, mouse.x, mouse.y)
                                return
                            }
                            // Десктоп: левый клик по пузырю входит в selection.
                            if (!root.isMobileOs && model.id && model.id.length > 0)
                                root.beginSelection(model.id)
                        }
                        // Мобилка: long-press — вход в режим множественного выделения.
                        onPressAndHold: function(mouse) {
                            if (root.isMobileOs && model.id && model.id.length > 0)
                                root.beginSelection(model.id)
                        }
                    }

                    // Sender label (only for incoming)
                    Text {
                        id: senderLabel
                        anchors.top: parent.top
                        anchors.left: parent.left
                        anchors.margins: 10
                        text: isMe ? "" : root.peer
                        color: Theme.accent
                        font.pixelSize: Theme.fontXs
                        font.family: Theme.fontFamily
                        font.weight: Font.Medium
                        visible: !isMe
                    }

                    ReplyPreview {
                        id: messageReplyPreview
                        anchors.top: isMe ? parent.top : senderLabel.bottom
                        anchors.topMargin: isMe ? 10 : 4
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        visible: hasReply
                        author: model.reply_sender_name || model.reply_sender || ""
                        previewText: root.replySummary(model.reply_text || "")
                        outgoing: isMe
                        interactive: hasReply
                        onClicked: root.scrollToMessageId(model.reply_to_id)
                    }

                    MessageText {
                        id: msgText
                        anchors.top: hasReply ? messageReplyPreview.bottom : (isMe ? parent.top : senderLabel.bottom)
                        anchors.topMargin: hasReply ? 6 : (isMe ? 10 : 2)
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        visible: showMessageText
                        raw: showMessageText ? model.text : ""
                        outgoing: isMe
                        textColor: isMe ? Theme.messageTextOutgoing : Theme.textPrimary
                        onLinkActivated: function(url) { Qt.openUrlExternally(url) }
                        onCopyRequested: function(t) { root.copyMessageText(t) }
                    }

                    PhotoMosaic {
                        id: photoMosaic
                        anchors.top: hasReply ? messageReplyPreview.bottom : (isMe ? parent.top : senderLabel.bottom)
                        anchors.topMargin: hasReply ? 6 : (isMe ? 10 : 6)
                        anchors.left: parent.left
                        anchors.leftMargin: 12
                        visible: isPhotoGroup
                        photos: groupPhotos
                        caption: isPhotoGroup ? (model.caption || "") : ""
                        maxWidth: Math.min(440, Math.max(240, listView.width * 0.55))
                        progressMap: root.uploadProgress
                        progressTick: root.uploadTick
                        onTileClicked: function(id, source, name) {
                            if (id && id.length > 0) root.openPhoto(source, id, name)
                        }
                    }

                    Rectangle {
                        id: imagePreview
                        anchors.top: showMessageText ? msgText.bottom : (hasReply ? messageReplyPreview.bottom : (isMe ? parent.top : senderLabel.bottom))
                        anchors.topMargin: showMessageText || hasReply ? 6 : (isMe ? 10 : 6)
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        height: isImage ? Math.min(340, Math.max(170, width * 0.66)) : 0
                        visible: isImage
                        radius: Theme.radiusMd
                        color: Theme.bgInput
                        border.width: previewSource.length > 0 ? 0 : 1
                        border.color: Theme.border
                        clip: true

                        // Растём с шириной окна (десктоп — крупнее, телефон — почти
                        // во всю ширину пузыря).
                        implicitWidth: Math.min(440, Math.max(240, listView.width * 0.55))
                        implicitHeight: height

                        Image {
                            anchors.fill: parent
                            source: previewSource
                            visible: previewSource.length > 0
                            asynchronous: true
                            // cache=false: расшифрованные превью идут через
                            // image://secure/<id>, держим их только в
                            // EncryptedImageProvider'е, без дисковых копий
                            // и без копий в QPixmapCache.
                            cache: false
                            fillMode: Image.PreserveAspectCrop
                            sourceSize.width: 640
                            sourceSize.height: 640
                        }

                        Column {
                            anchors.centerIn: parent
                            spacing: 6
                            visible: previewSource.length === 0
                            BusyIndicator {
                                anchors.horizontalCenter: parent.horizontalCenter
                                width: 28
                                height: 28
                                running: visible
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: qsTr("Загрузка превью")
                                color: Theme.textSecondary
                                font.pixelSize: Theme.fontSm
                                font.family: Theme.fontFamily
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: root.openPhoto(previewSource, model.id, attachmentName)
                        }

                        Rectangle {
                            width: 34
                            height: 34
                            anchors.top: parent.top
                            anchors.right: parent.right
                            anchors.margins: 8
                            radius: Theme.radiusSm
                            color: previewSaveArea.containsMouse ? Theme.bgCard : "#CC0B0F14"
                            border.width: 1
                            border.color: Theme.border
                            z: 3

                            AppIcon {
                                anchors.centerIn: parent
                                width: 18
                                height: 18
                                name: "download"
                                iconColor: previewSaveArea.containsMouse ? Theme.textPrimary : "#F7E8EA"
                                strokeWidth: 2
                            }

                            MouseArea {
                                id: previewSaveArea
                                anchors.fill: parent
                                hoverEnabled: true
                                enabled: !isDownloading
                                onClicked: root.openSaveDialog(model.id, attachmentName)
                            }
                        }
                    }

                    Rectangle {
                        id: fileCard
                        anchors.top: showMessageText ? msgText.bottom : (hasReply ? messageReplyPreview.bottom : (isMe ? parent.top : senderLabel.bottom))
                        anchors.topMargin: 6
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        height: showFileCard ? 58 : 0
                        visible: showFileCard
                        radius: Theme.radiusMd
                        color: Theme.bgInput
                        border.width: 1
                        border.color: Theme.border

                        implicitWidth: Math.max(230, fileNameText.implicitWidth + 78)
                        implicitHeight: height

                        Rectangle {
                            id: fileIcon
                            width: 38
                            height: 38
                            anchors.left: parent.left
                            anchors.leftMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            radius: Theme.radiusSm
                            color: fileIconArea.containsMouse ? Theme.bgCard : Theme.bgSecondary
                            border.width: 1
                            border.color: fileIconArea.containsMouse ? Theme.accentDim : Theme.border

                            AppIcon {
                                anchors.fill: parent
                                name: "file"
                                iconColor: Theme.accentHover
                                fillColor: Theme.accentDim
                                strokeWidth: 1.5
                            }

                            MouseArea {
                                id: fileIconArea
                                anchors.fill: parent
                                hoverEnabled: true
                                enabled: !isDownloading
                                onClicked: root.openSaveDialog(model.id, attachmentName)
                            }
                        }

                        Column {
                            anchors.left: fileIcon.right
                            anchors.leftMargin: 10
                            anchors.right: parent.right
                            anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 3

                            Text {
                                id: fileNameText
                                width: parent.width
                                text: attachmentName
                                color: Theme.textPrimary
                                font.pixelSize: Theme.fontSm
                                font.family: Theme.fontFamily
                                elide: Text.ElideRight
                            }
                            Text {
                                readonly property bool isEphemeral: (model.ephemeral_file_id || "").length > 0
                                width: parent.width
                                text: isDownloading
                                      ? qsTr("Сохранение…")
                                      : root.formatFileSize(model.size)
                                        + (isEphemeral ? qsTr(" · временный, до %1").arg(root.formatEphemeralExpiry(model.ephemeral_expires_at)) : "")
                                color: isEphemeral ? Theme.accentHover : Theme.textSecondary
                                font.pixelSize: Theme.fontXs
                                font.family: Theme.fontFamily
                                elide: Text.ElideRight
                            }
                        }
                    }

                    Flow {
                        id: reactionsFlow
                        anchors.top: isPhotoGroup ? photoMosaic.bottom : (isImage ? imagePreview.bottom : (showFileCard ? fileCard.bottom : msgText.bottom))
                        anchors.topMargin: 6
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        spacing: 4
                        visible: hasReactions

                        Repeater {
                            model: reactions
                            delegate: Rectangle {
                                required property var modelData
                                readonly property string senderInitial: {
                                    const s = modelData.sender_name || modelData.sender || ""
                                    return s.length > 0 ? s.charAt(0).toUpperCase() : ""
                                }
                                width: reactionRow.implicitWidth + 14
                                height: 28
                                radius: 14
                                color: modelData.mine ? Theme.accentDim : Theme.bgDark
                                border.width: 1
                                border.color: modelData.mine ? Theme.accentHover : Theme.border
                                Row {
                                    id: reactionRow
                                    anchors.centerIn: parent
                                    spacing: 4
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: modelData.emoji
                                        color: Theme.textPrimary
                                        font.pixelSize: 16
                                        font.family: Theme.fontFamily
                                    }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: senderInitial.length > 0
                                        text: senderInitial
                                        color: Theme.textSecondary
                                        font.pixelSize: Theme.fontSm
                                        font.family: Theme.fontFamily
                                        font.weight: Font.DemiBold
                                    }
                                }
                            }
                        }
                    }

                    Row {
                        id: metaRow
                        anchors.top: hasReactions ? reactionsFlow.bottom : (isPhotoGroup ? photoMosaic.bottom : (isImage ? imagePreview.bottom : (showFileCard ? fileCard.bottom : msgText.bottom)))
                        anchors.topMargin: hasReactions ? 4 : 0
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 4
                        spacing: 4
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.formatTime(model.ts)
                            color: isMe ? root.deliveryStatusColor(model.status) : Theme.messageMetaIncoming
                            font.pixelSize: Theme.fontXs
                            font.family: Theme.fontFamily
                        }
                        DeliveryStatusIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: isMe
                            status: model.status
                            iconColor: root.deliveryStatusColor(model.status)
                        }
                    }
                }
            }
            }

            BusyIndicator {
                id: messagesBusy
                anchors.centerIn: parent
                // Только начальная загрузка (пустая лента). Иначе крутилка лезла
                // поверх уже показанных сообщений при каждом fetchMessages —
                // в т.ч. при отправке вложений (fetchMessages → messagesLoading).
                running: (Chat.messagesLoading || !root.messagesLoaded) && msgModel.count === 0
                visible: running
                z: 2
            }

            Text {
                anchors.top: messagesBusy.bottom
                anchors.topMargin: 8
                anchors.horizontalCenter: parent.horizontalCenter
                text: qsTr("Загрузка сообщений…")
                color: Theme.textSecondary
                font.pixelSize: Theme.fontSm
                font.family: Theme.fontFamily
                visible: messagesBusy.visible
                z: 2
            }

            Text {
                anchors.centerIn: parent
                text: qsTr("Сообщений пока нет")
                color: Theme.textSecondary
                font.pixelSize: Theme.fontSm
                font.family: Theme.fontFamily
                visible: root.messagesLoaded && !Chat.messagesLoading && msgModel.count === 0
                z: 2
            }

            // Тост «Скопировано» — обратная связь при копировании текста сообщения
            // (inline-код/блок кода/пункт меню), особенно нужен на ПК, где клик по
            // inline-копированию иначе незаметен.
            Rectangle {
                id: copyToast
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 18
                z: 10
                radius: Theme.radiusMd
                color: Theme.bgCard
                border.color: Theme.border
                border.width: 1
                implicitWidth: copyToastRow.implicitWidth + 28
                implicitHeight: 36
                width: implicitWidth
                height: implicitHeight
                opacity: 0
                visible: opacity > 0

                Behavior on opacity { NumberAnimation { duration: 150 } }

                Row {
                    id: copyToastRow
                    anchors.centerIn: parent
                    spacing: 8
                    AppIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 16; height: 16
                        name: "check"
                        iconColor: Theme.success
                        strokeWidth: 2.4
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Скопировано")
                        color: Theme.textPrimary
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSm
                    }
                }

                Timer { id: copyToastTimer; interval: 1400; onTriggered: copyToast.opacity = 0 }
            }

            Rectangle {
                id: scrollToBottomButton
                width: 44
                height: 44
                anchors.right: parent.right
                anchors.rightMargin: 18
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 18
                radius: 22
                visible: root.messagesLoaded && msgModel.count > 0 && !root.isListAtEnd()
                opacity: visible ? 1 : 0
                z: 5
                color: scrollToBottomArea.containsMouse ? Theme.accentHover : Theme.accent
                border.width: 1
                border.color: Theme.accentDim

                Behavior on opacity { NumberAnimation { duration: 120 } }
                Behavior on color { ColorAnimation { duration: 120 } }

                AppIcon {
                    anchors.centerIn: parent
                    width: 22
                    height: 22
                    name: "chevronLeft"
                    rotation: -90
                    iconColor: Theme.textPrimary
                    strokeWidth: 2.4
                }

                MouseArea {
                    id: scrollToBottomArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { listView.stickToBottom = true; listView.positionViewAtEnd() }
                }

                ToolTip.visible: scrollToBottomArea.containsMouse
                ToolTip.delay: 500
                ToolTip.text: qsTr("Вниз")
            }
        }

        // ── Sending-files indicator ──────────────────────────
        // Видимая обратная связь, пока Chat.sendFile в полёте: пользователь
        // видит, что отправка реально идёт (как для обычных вложений из «+»,
        // так и для share-target'а).
        Rectangle {
            id: sendIndicator
            // Для мозаики индикация отправки — кольца НА плитках; нижний баннер
            // прячем, пока в полёте фото-группа (иначе дублирует и висит внизу).
            readonly property bool mosaicInFlight: Object.keys(root.pendingGroups).length > 0
            Layout.fillWidth: true
            Layout.preferredHeight: (Chat.filesInFlight > 0 && !mosaicInFlight) ? 44 : 0
            visible: Chat.filesInFlight > 0 && !mosaicInFlight
            color: Theme.bgSecondary

            // Прогресс per-transfer: ключ — sendKey из C++ (см. ChatBackend::sendFile),
            // значение — { chunk, total }. Прогрессбар внизу показывает агрегат.
            property var progressByTransfer: ({})
            property int totalChunks: 0
            property int doneChunks: 0
            readonly property real progressFraction: totalChunks > 0
                ? Math.min(1.0, doneChunks / totalChunks) : 0
            readonly property bool hasProgress: totalChunks > 0

            function recomputeProgress() {
                let d = 0, t = 0
                for (const k in progressByTransfer) {
                    const p = progressByTransfer[k]
                    d += p.chunk || 0
                    t += p.total || 0
                }
                doneChunks = d
                totalChunks = t
            }

            Connections {
                target: Chat
                function onFileProgress(transferKey, chunkIndex, total) {
                    const map = sendIndicator.progressByTransfer
                    map[transferKey] = { chunk: chunkIndex, total: total }
                    // Если transfer завершён, удалим запись.
                    if (chunkIndex >= total) delete map[transferKey]
                    sendIndicator.progressByTransfer = map
                    sendIndicator.recomputeProgress()
                }
                function onFilesInFlightChanged() {
                    if (Chat.filesInFlight === 0) {
                        sendIndicator.progressByTransfer = ({})
                        sendIndicator.doneChunks = 0
                        sendIndicator.totalChunks = 0
                    }
                }
            }

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width; height: 1
                color: Theme.separator
            }

            // Круглый прогресс-бар: рисуем дугу пропорционально progressFraction.
            // Если ещё ни один chunk не пришёл (total=0) — показываем
            // обычный BusyIndicator как «крутилку».
            Item {
                id: progressVis
                anchors.left: parent.left
                anchors.leftMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                width: 24; height: 24

                BusyIndicator {
                    anchors.fill: parent
                    running: visible
                    visible: !sendIndicator.hasProgress
                }

                Canvas {
                    id: arcCanvas
                    anchors.fill: parent
                    visible: sendIndicator.hasProgress
                    property real fraction: sendIndicator.progressFraction
                    onFractionChanged: requestPaint()
                    onPaint: {
                        const ctx = getContext("2d")
                        ctx.clearRect(0, 0, width, height)
                        const cx = width / 2, cy = height / 2
                        const r = Math.min(cx, cy) - 2
                        ctx.lineWidth = 2.5
                        ctx.lineCap = "round"
                        // Базовое кольцо
                        ctx.beginPath()
                        ctx.strokeStyle = Theme.accentDim
                        ctx.arc(cx, cy, r, 0, Math.PI * 2)
                        ctx.stroke()
                        // Активная дуга
                        if (fraction > 0) {
                            ctx.beginPath()
                            ctx.strokeStyle = Theme.accent
                            ctx.arc(cx, cy, r, -Math.PI / 2,
                                    -Math.PI / 2 + Math.PI * 2 * fraction)
                            ctx.stroke()
                        }
                    }
                }
            }

            Text {
                anchors.left: progressVis.right
                anchors.leftMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                text: {
                    if (!sendIndicator.hasProgress)
                        return Chat.filesInFlight === 1
                               ? qsTr("Отправка вложения…")
                               : qsTr("Отправка вложений: %1…").arg(Chat.filesInFlight)
                    const pct = Math.round(sendIndicator.progressFraction * 100)
                    const filesPart = Chat.filesInFlight > 1
                        ? qsTr(" (файлов: %1)").arg(Chat.filesInFlight)
                        : ""
                    return qsTr("Отправка: %1/%2 блоков (%3%)%4")
                           .arg(sendIndicator.doneChunks).arg(sendIndicator.totalChunks)
                           .arg(pct).arg(filesPart)
                }
                color: Theme.textSecondary
                font.pixelSize: Theme.fontSm
                font.family: Theme.fontFamily
            }
        }

        // ── Error bar ─────────────────────────────────────────
        Rectangle {
            id: errorBar
            Layout.fillWidth: true
            height: 36
            color: Theme.errorBg
            visible: false

            Timer { id: errorTimer; interval: 3000; onTriggered: errorBar.visible = false }

            Text {
                id: errorText
                anchors.centerIn: parent
                color: Theme.error
                font.pixelSize: Theme.fontSm
                font.family: Theme.fontFamily
            }
        }

        // ── Input bar ─────────────────────────────────────────
        Rectangle {
            id: inputBar
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(Math.max(msgInput.implicitHeight + 32 + (root.hasPendingReply ? 58 : 0),
                                                      root.hasPendingReply ? 118 : 60), 200)
            color: Theme.bgDark

            Rectangle {
                anchors.top: parent.top
                width: parent.width; height: 1
                color: Theme.separator
            }

            ColumnLayout {
                id: inputContent
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                anchors.topMargin: 8
                anchors.bottomMargin: 8
                spacing: 6

                ReplyPreview {
                    Layout.fillWidth: true
                    Layout.preferredHeight: root.hasPendingReply ? implicitHeight : 0
                    visible: root.hasPendingReply
                    author: root.pendingReplyAuthor
                    previewText: root.pendingReplyText
                    closeVisible: true
                    onCloseClicked: root.clearPendingReply()
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 8

                    Rectangle {
                        Layout.preferredWidth: 40
                        Layout.preferredHeight: 40
                        Layout.alignment: Qt.AlignVCenter
                        radius: Theme.radiusSm
                        color: attachArea.containsMouse ? Theme.bgCard : Theme.bgInput
                        border.width: 1
                        border.color: Theme.border

                        AppIcon {
                            anchors.centerIn: parent
                            width: 20
                            height: 20
                            name: "plus"
                            iconColor: Theme.accentHover
                            strokeWidth: 2.2
                        }

                        MouseArea {
                            id: attachArea
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: {
                                const p = mapToItem(root, 0, 0)
                                attachMenu.x = Math.max(8, p.x)
                                attachMenu.y = Math.max(8, p.y - attachMenu.height - 6)
                                attachMenu.open()
                            }
                        }
                    }

                    // Кнопка эмодзи — открывает эмодзи-пикер для вставки в текст.
                    Rectangle {
                        Layout.preferredWidth: 40
                        Layout.preferredHeight: 40
                        Layout.alignment: Qt.AlignVCenter
                        radius: Theme.radiusSm
                        color: emojiArea.containsMouse ? Theme.bgCard : Theme.bgInput
                        border.width: 1
                        border.color: Theme.border

                        Text {
                            anchors.centerIn: parent
                            text: "🙂"
                            font.pixelSize: 20
                            font.family: Theme.fontFamily
                        }

                        MouseArea {
                            id: emojiArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: inputEmojiPicker.open()
                        }
                    }

                    ScrollView {
                        id: msgInputScroll
                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.min(Math.max(msgInput.implicitHeight, 40), 124)
                        Layout.alignment: Qt.AlignVCenter
                        clip: true
                        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                        ScrollBar.vertical.policy: ScrollBar.AsNeeded

                        background: Rectangle {
                            radius: Theme.radiusMd
                            color: Theme.bgInput
                            border.color: Theme.border
                            border.width: 1
                        }

                        TextArea {
                            id: msgInput
                            placeholderText: qsTr("Сообщение…")
                            placeholderTextColor: Theme.textHint
                            wrapMode: TextEdit.Wrap
                            selectByMouse: true
                            inputMethodHints: Qt.ImhNoAutoUppercase
                            color: Theme.textPrimary
                            font.pixelSize: Theme.fontMd
                            font.family: Theme.fontFamily
                            // NativeRendering обязателен, иначе scene-graph
                            // (distance-field) рендер НЕ рисует подчёркивания из
                            // QSyntaxHighlighter — волнистая линия опечаток не видна.
                            renderType: Text.NativeRendering
                            topPadding: 8
                            bottomPadding: 8
                            leftPadding: 14
                            rightPadding: 14

                            background: null
                            onTextChanged: {
                                if (text.length > 0) root.sendLocked = false
                                root.saveDraft()
                                spellUnderlines.requestPaint()
                            }

                            SpellHighlighter {
                                id: spellHighlighter
                                textDocument: msgInput.textDocument
                                // На мобилках орфографию подсвечивает Qt VKB (предикативный ввод).
                                // Дублирующее подчёркивание от Hunspell визуально мешает.
                                enabled: !root.isMobileOs
                                locale: "ru_RU"
                                onAvailableChanged: spellUnderlines.requestPaint()
                            }

                            // Подчёркивание опечаток: QQuickTextEdit не рендерит
                            // underline из QSyntaxHighlighter, поэтому рисуем волнистую
                            // линию сами. Дочерний Canvas без MouseArea — ввод/выделение
                            // проходят в TextArea насквозь; линия идёт в зоне нижних
                            // выносных элементов, глифы не перекрывает.
                            Canvas {
                                id: spellUnderlines
                                anchors.fill: parent
                                visible: spellHighlighter.enabled && spellHighlighter.available

                                function squiggle(ctx, x1, x2, y) {
                                    if (x2 - x1 < 1) return
                                    var amp = 1.6, wl = 4, up = true
                                    ctx.beginPath()
                                    ctx.moveTo(x1, y)
                                    for (var x = x1; x < x2; x += wl) {
                                        var nx = Math.min(x + wl, x2)
                                        ctx.lineTo(nx, y + (up ? -amp : amp))
                                        up = !up
                                    }
                                    ctx.stroke()
                                }

                                onPaint: {
                                    var ctx = getContext("2d")
                                    ctx.reset()
                                    if (!spellHighlighter.enabled || !spellHighlighter.available) return
                                    var ranges = spellHighlighter.misspelledRanges()
                                    ctx.strokeStyle = "#FF2738"
                                    ctx.lineWidth = 1.4
                                    for (var i = 0; i < ranges.length; ++i) {
                                        var s = ranges[i].start
                                        var e = s + ranges[i].length
                                        var r1 = msgInput.positionToRectangle(s)
                                        var r2 = msgInput.positionToRectangle(e)
                                        var y = r1.y + r1.height - 1
                                        if (Math.abs(r1.y - r2.y) < 1) {
                                            squiggle(ctx, r1.x, r2.x, y)
                                        } else {
                                            // Слово перенеслось — подчёркиваем по двум строкам.
                                            squiggle(ctx, r1.x, msgInput.width - msgInput.rightPadding, y)
                                            squiggle(ctx, msgInput.leftPadding, r2.x, r2.y + r2.height - 1)
                                        }
                                    }
                                }

                                Connections {
                                    target: msgInput
                                    function onWidthChanged() { spellUnderlines.requestPaint() }
                                    function onContentHeightChanged() { spellUnderlines.requestPaint() }
                                }
                            }

                            persistentSelection: true

                            function populateSpellContext(x, y) {
                                inputMenu.spellStart = -1
                                inputMenu.spellLength = 0
                                inputMenu.spellWord = ""
                                inputMenu.spellSuggestions = []
                                if (!spellHighlighter.enabled || !spellHighlighter.available) return
                                const pos = positionAt(x, y)
                                if (pos < 0) return
                                const info = spellHighlighter.misspelledAt(pos, 5)
                                if (info && info.start !== undefined) {
                                    inputMenu.spellStart = info.start
                                    inputMenu.spellLength = info.length
                                    inputMenu.spellWord = info.word
                                    inputMenu.spellSuggestions = info.suggestions || []
                                }
                            }

                            // Якорь меню = точка клика (в координатах root); сама
                            // позиция считается реактивными биндингами inputMenu.x/y.
                            function anchorInputMenu(clickX, clickY) {
                                const p = mapToItem(root, clickX, clickY)
                                inputMenu.anchorX = p.x
                                inputMenu.anchorY = p.y
                            }

                            // Правая кнопка на десктопе
                            onPressed: function(event) {
                                if (event.button === Qt.RightButton && !isMobileOs) {
                                    populateSpellContext(event.x, event.y)
                                    anchorInputMenu(event.x, event.y)
                                    inputMenu.open()
                                    event.accepted = true
                                }
                            }

                            // Длинное нажатие на мобильных
                            onPressAndHold: function(event) {
                                if (!isMobileOs) return
                                // Если это было листание поля (скролл многострочного
                                // ввода), а не удержание — меню не открываем.
                                if (msgInputScroll.contentItem.moving
                                        || msgInputScroll.contentItem.dragging)
                                    return
                                populateSpellContext(event.x, event.y)
                                anchorInputMenu(event.x, event.y)
                                inputMenu.open()
                            }

                            onActiveFocusChanged: {
                               if (activeFocus) Qt.inputMethod.show()
                            }

                            Keys.onPressed: function(event) {
                                if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                                        && (event.modifiers & Qt.ControlModifier)) {
                                    sendBtn.clicked()
                                    event.accepted = true
                                }
                            }
                        }
                    }

                    // Send button
                    Rectangle {
                        // Активность по тексту ИЛИ по pre-edit'у (предикативный ввод
                        // до коммита держит первое слово только в preeditText).
                        readonly property bool hasContent: msgInput.text.trim().length > 0
                                                           || (msgInput.preeditText && msgInput.preeditText.trim().length > 0)
                        Layout.preferredWidth: 40
                        Layout.preferredHeight: 40
                        Layout.alignment: Qt.AlignVCenter
                        radius: Theme.radiusSm
                        color: root.sendLocked || !hasContent ? Theme.accentDim : (sendArea.containsMouse ? Theme.accentHover : Theme.accent)

                        AppIcon {
                            anchors.fill: parent
                            name: "send"
                            iconColor: parent.hasContent ? Theme.textPrimary : Theme.textSecondary
                        }

                        MouseArea {
                            id: sendArea
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: !root.sendLocked && parent.hasContent
                            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ForbiddenCursor
                            onClicked: sendBtn.clicked()
                        }
                    }

                    // Invisible button target for keyboard submit
                    Item {
                        id: sendBtn
                        signal clicked()

                        function doSend() {
                            if (root.sendLocked) return
                            let txt = msgInput.text.trim()
                            // Если commit() не успел сложить pre-edit в text
                            // (предикативный ввод первого слова), берём напрямую
                            // из preeditText TextArea — он содержит то, что
                            // визуально показано пользователю.
                            if (txt.length === 0 && msgInput.preeditText && msgInput.preeditText.length > 0)
                                txt = String(msgInput.preeditText).trim()
                            if (txt.length === 0) return
                            root.sendLocked = true
                            if (root.hasPendingReply)
                                Chat.sendTextReply(txt, root.pendingReplyId, root.pendingReplySender, root.pendingReplyText)
                            else
                                Chat.sendText(txt)
                            msgInput.text = ""
                            root.clearDraft()
                            root.clearPendingReply()
                            sendUnlockTimer.restart()
                            // Автопрокрутка вниз при отправке: гарантированно
                            // показываем только что отправленное сообщение.
                            listView.stickToBottom = true
                            Qt.callLater(listView.positionViewAtEnd)
                        }

                        onClicked: {
                            if (root.sendLocked) return
                            // Qt.inputMethod.commit() кладёт pre-edit в editor через
                            // QInputMethodEvent. Property msgInput.text обновляется,
                            // но для некоторых input method'ов (Android Latin, Qt VKB
                            // с предикцией) первое слово приходит в preeditText и не
                            // успевает закоммититься в text до возврата из commit().
                            // Поэтому отправляем через Qt.callLater + fallback на
                            // preeditText в doSend().
                            Qt.inputMethod.commit()
                            Qt.callLater(doSend)
                        }
                    }
                }
            }
        }
    }

    PhotoViewer {
        id: photoViewer
        anchors.fill: parent
        onSaveRequested: function(messageId, filename) {
            root.openSaveDialog(messageId, filename)
        }
    }

    // ── Эмодзи-пикер для вставки в поле ввода ────────────────────────────
    EmojiPicker {
        id: inputEmojiPicker
        anchors.centerIn: Overlay.overlay
        heading: qsTr("Эмодзи")
        closeOnPick: false   // можно вставить несколько подряд
        onPicked: function(emoji) {
            msgInput.insert(msgInput.cursorPosition, emoji)
        }
        onClosed: msgInput.forceActiveFocus()
    }

    // ── Настройка списка быстрых реакций ─────────────────────────────────
    Popup {
        id: reactionsConfig
        anchors.centerIn: Overlay.overlay
        width: 340; padding: 20
        modal: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        background: Rectangle {
            radius: Theme.radiusLg
            color: Theme.bgSecondary
            border.color: Theme.border
        }

        contentItem: ColumnLayout {
            spacing: 14

            Text {
                Layout.fillWidth: true
                text: qsTr("Быстрые реакции")
                color: Theme.textPrimary
                font.pixelSize: Theme.fontLg
                font.family: Theme.fontFamily
                font.weight: Font.Medium
            }
            Text {
                Layout.fillWidth: true
                text: qsTr("Нажмите на реакцию, чтобы убрать её из списка.")
                color: Theme.textSecondary
                font.pixelSize: Theme.fontSm
                font.family: Theme.fontFamily
                wrapMode: Text.WordWrap
            }

            Flow {
                Layout.fillWidth: true
                spacing: 8
                Repeater {
                    model: Reactions.list
                    delegate: Rectangle {
                        required property int index
                        required property string modelData
                        width: 40; height: 40
                        radius: Theme.radiusSm
                        color: cfgReactionArea.containsMouse ? Theme.errorBg : Theme.bgCard
                        border.width: 1
                        border.color: cfgReactionArea.containsMouse ? Theme.error : Theme.border
                        Text {
                            anchors.centerIn: parent
                            text: modelData
                            font.pixelSize: 20
                            font.family: Theme.fontFamily
                        }
                        MouseArea {
                            id: cfgReactionArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: Reactions.removeAt(index)
                        }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 12
                ParaButton {
                    Layout.fillWidth: true
                    text: qsTr("Добавить")
                    onClicked: reactionEmojiPicker.open()
                }
                ParaButton {
                    Layout.fillWidth: true
                    text: qsTr("Сбросить")
                    secondary: true
                    onClicked: Reactions.reset()
                }
                ParaButton {
                    Layout.fillWidth: true
                    text: qsTr("Готово")
                    secondary: true
                    onClicked: reactionsConfig.close()
                }
            }
        }
    }

    // Эмодзи-пикер для добавления новой реакции в список.
    EmojiPicker {
        id: reactionEmojiPicker
        anchors.centerIn: Overlay.overlay
        heading: qsTr("Добавить реакцию")
        closeOnPick: true
        onPicked: function(emoji) { Reactions.add(emoji) }
    }

    // ── Подтверждение удаления выделенных сообщений ──────────────────────
    Popup {
        id: deleteSelectionConfirm
        anchors.centerIn: Overlay.overlay
        width: 320; padding: 24
        modal: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        background: Rectangle {
            radius: Theme.radiusLg
            color: Theme.bgSecondary
            border.color: Theme.border
        }

        contentItem: ColumnLayout {
            spacing: 16
            Text {
                Layout.alignment: Qt.AlignHCenter
                text: qsTr("Удалить сообщения?")
                color: Theme.textPrimary
                font.pixelSize: Theme.fontLg
                font.family: Theme.fontFamily
                font.weight: Font.Medium
            }
            Text {
                Layout.fillWidth: true
                text: qsTr("Выбранные сообщения (включая прикреплённые файлы) будут удалены и с сервера, и у собеседника при следующей синхронизации.")
                color: Theme.textSecondary
                font.pixelSize: Theme.fontSm
                font.family: Theme.fontFamily
                wrapMode: Text.WordWrap
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 12
                ParaButton {
                    Layout.fillWidth: true
                    text: qsTr("Удалить")
                    onClicked: {
                        deleteSelectionConfirm.close()
                        root.confirmDeleteSelection()
                    }
                }
                ParaButton {
                    Layout.fillWidth: true
                    text: qsTr("Отмена")
                    secondary: true
                    onClicked: deleteSelectionConfirm.close()
                }
            }
        }
    }

    // ── Предложение удалить файл с сервера после скачивания ──────────────
    Popup {
        id: deleteServerCopyPrompt
        anchors.centerIn: Overlay.overlay
        width: 340; padding: 24
        modal: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        property string targetMessageId: ""
        property string targetFilename: ""

        background: Rectangle {
            radius: Theme.radiusLg
            color: Theme.bgSecondary
            border.color: Theme.border
        }

        contentItem: ColumnLayout {
            spacing: 16
            Text {
                Layout.alignment: Qt.AlignHCenter
                text: qsTr("Удалить файл с сервера?")
                color: Theme.textPrimary
                font.pixelSize: Theme.fontLg
                font.family: Theme.fontFamily
                font.weight: Font.Medium
            }
            Text {
                Layout.fillWidth: true
                text: qsTr("Файл скачан и сохранён локально. Если он больше не нужен на сервере — можно его убрать. Сообщение в чате останется.")
                color: Theme.textSecondary
                font.pixelSize: Theme.fontSm
                font.family: Theme.fontFamily
                wrapMode: Text.WordWrap
            }
            Text {
                Layout.fillWidth: true
                text: deleteServerCopyPrompt.targetFilename
                color: Theme.textHint
                font.pixelSize: Theme.fontXs
                font.family: Theme.fontFamily
                elide: Text.ElideMiddle
                visible: deleteServerCopyPrompt.targetFilename.length > 0
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 12
                ParaButton {
                    Layout.fillWidth: true
                    text: qsTr("Удалить")
                    onClicked: {
                        const id = deleteServerCopyPrompt.targetMessageId
                        deleteServerCopyPrompt.close()
                        if (id.length > 0) Chat.removeAttachmentChunksFromServer(id)
                    }
                }
                ParaButton {
                    Layout.fillWidth: true
                    text: qsTr("Оставить")
                    secondary: true
                    onClicked: deleteServerCopyPrompt.close()
                }
            }
        }
    }

    Connections {
        target: Chat
        function onAttachmentDownloaded(messageId, filename) {
            deleteServerCopyPrompt.targetMessageId = messageId || ""
            deleteServerCopyPrompt.targetFilename = filename || ""
            deleteServerCopyPrompt.open()
        }
        function onMessagesDeleted(peer) {
            if (peer === root.peer) Chat.fetchMessages()
        }
    }
}
