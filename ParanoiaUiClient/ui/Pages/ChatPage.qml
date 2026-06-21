import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Window
import QtCore
import ParanoiaUiClient

Rectangle {
    id: root
    color: Theme.bgPrimary
    readonly property bool isMobileOs: (Qt.platform.os === "android" || Qt.platform.os === "ios")
    required property string peer
    // Локальные имя/аватар диалога (см. MainPage/Backend) — для хедера. Берём из
    // getDialogs по peer; обновляем по dialogsChanged. Пусто → fallback на peer/букву.
    property string displayName: peer
    property string avatar: ""
    // Своё имя/аватар (активный профиль) — для бейджей реакций на свои реакции.
    property string selfName: ""
    property string selfAvatar: ""
    function _refreshPeerInfo() {
        root.selfName = Backend.activeProfileDisplayName()
        root.selfAvatar = Backend.activeProfileAvatar()
        const list = Backend.getDialogs()
        for (var i = 0; i < list.length; ++i) {
            if (list[i].peer === root.peer) {
                root.displayName = list[i].displayName || root.peer
                root.avatar = list[i].avatar || ""
                return
            }
        }
        root.displayName = root.peer
        root.avatar = ""
    }
    Connections {
        target: Backend
        function onDialogsChanged() { root._refreshPeerInfo() }
    }
    property string pendingDownloadId: ""
    property string pendingDownloadName: "attachment.bin"
    property string downloadingAttachmentId: ""
    property bool sendLocked: false
    property bool messagesLoaded: false
    // Inline эмодзи-панель (#42) открыта (вместо клавиатуры). Toggle ниже.
    property bool emojiPanelOpen: false

    // Открыть панель эмодзи: прячем клавиатуру (снимаем фокус с поля), показываем
    // панель. Иконка кнопки превращается в «клавиатуру».
    function openEmojiPanel() {
        root.emojiPanelOpen = true
        msgInput.focus = false
        Qt.inputMethod.hide()
    }
    // Закрыть панель и вернуть клавиатуру (фокус на поле).
    function closeEmojiPanel() {
        root.emojiPanelOpen = false
        msgInput.forceActiveFocus()
        if (root.isMobileOs) Qt.inputMethod.show()
    }
    function toggleEmojiPanel() {
        if (root.emojiPanelOpen) root.closeEmojiPanel()
        else root.openEmojiPanel()
    }

    // Открыть длинное сообщение на весь экран для удобного чтения (кнопка-уголки
    // в пузыре, видна только для «простыней» — см. isLongText в делегате).
    function openTextViewer(text, senderName, outgoing, timeStr) {
        textViewer.open(text, senderName, outgoing, timeStr)
    }

    // Анимация удаления «шредер»: НАБОР id сообщений, чьи пузыри сейчас «режутся»
    // (поддерживает и одиночное, и множественное удаление). Делегаты с этими id
    // запускают ShredderOverlay; реальное удаление делает ОДИН общий таймер после
    // окончания анимации (а не каждый делегат сам — иначе N model-update'ов).
    property var shreddingIds: ({})
    property var _shredDeleteIds: []
    // visibleIds — id видимых пузырей для анимации; deleteIds — что реально удалить
    // (расширенный набор, напр. с фото из групп).
    function startShredder(visibleIds, deleteIds) {
        const del = (deleteIds && deleteIds.length > 0) ? deleteIds : (visibleIds || [])
        if (!visibleIds || visibleIds.length === 0) {
            if (del.length > 0) Chat.deleteMessages(del)
            return
        }
        const set = {}
        for (let i = 0; i < visibleIds.length; ++i) set[visibleIds[i]] = true
        root.shreddingIds = set
        root._shredDeleteIds = del
        shredCommitTimer.restart()
    }
    Timer {
        id: shredCommitTimer
        interval: 740   // сразу после анимации шредера (720мс) — слот схлопывается быстро
        onTriggered: {
            if (root._shredDeleteIds.length > 0) Chat.deleteMessages(root._shredDeleteIds)
            root._shredDeleteIds = []
            // НЕ чистим shreddingIds здесь: иначе isShredding→false вернёт пузырю
            // opacity=1 (он мелькнёт на месте) ДО того как model-update удалит делегат.
            // Пузырь остаётся скрытым (opacity 0), пока модель его не уберёт. Набор
            // перезапишется при следующем startShredder; восстановление видимости
            // переиспользованных делегатов — через onIsShreddingChanged (смена model.id).
        }
    }
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
    // Сообщение для кратковременной подсветки при переходе из галереи вложений
    // («перейти к вложению в диалоге»). Сбрасывается flashTimer'ом.
    property string _flashMessageId: ""
    // Режим множественного выбора (ranged-delete).
    property bool selectionMode: false
    property var selectedIds: ({})  // объект как Set: { [messageId]: true }
    property int selectionCount: 0
    // Drag-select состояние (выделение перетаскиванием).
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

    // Прикреплённые, но ещё НЕ отправленные вложения (стейджинг): пользователь
    // прикрепляет файлы/фото (через «+», share, picker), при желании дописывает
    // текст-подпись и отправляет всё разом кнопкой отправки. Каждый элемент:
    // { path, name, kind } где kind ∈ "image"|"video"|"file".
    property var pendingAttachments: []
    readonly property bool hasPendingAttachments: pendingAttachments && pendingAttachments.length > 0

    signal back()

    // CallPage.qml тянет QtMultimedia — её нет в сборках без VoIP, поэтому
    // компонент создаётся динамически только при VoIPAvailable=true.
    property var callPageComponent: null
    // VideoViewer.qml тоже тянет QtMultimedia — грузим динамически так же.
    property var videoViewerComponent: null
    // Одиночный аудио-плеер голосовых (VoicePlayer.qml, тоже QtMultimedia).
    property var voicePlayer: null
    property string pendingVoicePlayId: ""

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

    // Полночь указанной даты (для подсчёта «целых суток» между датами без влияния времени).
    function _dayStartMs(ts) {
        let d = new Date(ts)
        return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime()
    }

    // Ключ календарного дня (для группировки сообщений по дням в ленте).
    function dayKey(ts) {
        let d = new Date(ts)
        return d.getFullYear() * 10000 + (d.getMonth() + 1) * 100 + d.getDate()
    }

    // Подпись разделителя-пилюли над первым сообщением дня:
    //   сегодня → «Сегодня», вчера → «Вчера», в пределах недели → день недели,
    //   этот год → «23 апреля», прошлый год и старше → «23 апреля 2025».
    function formatDaySeparator(ts) {
        let d = new Date(ts)
        let now = new Date()
        let diffDays = Math.round((_dayStartMs(now.getTime()) - _dayStartMs(ts)) / 86400000)
        if (diffDays <= 0) return qsTr("Сегодня")
        if (diffDays === 1) return qsTr("Вчера")
        if (diffDays < 7) {
            let w = Qt.locale().toString(d, "dddd")
            return w.length > 0 ? w.charAt(0).toUpperCase() + w.slice(1) : w
        }
        if (d.getFullYear() === now.getFullYear())
            return Qt.locale().toString(d, "d MMMM")
        return Qt.locale().toString(d, "d MMMM yyyy")
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
        root.downloadingAttachmentId = messageId
        Chat.requestFileAccessPermissions()
        // Одним тапом в дефолт-папку (картинки → Изображения/Paranoia, файлы →
        // Загрузки/Paranoia), без диалога выбора. onAttachmentSaved
        // покажет тост с путём. (#33/#34)
        Chat.saveAttachmentToDefault(messageId)
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

    // Открыть видео: материализуем расшифрованный mp4 (асинхронно) и по
    // готовности пушим полноэкранный плеер. Плеер тянет QtMultimedia, поэтому
    // доступен только в VoIP/Video-сборках (см. videoViewerComponent).
    property string pendingVideoPlayId: ""
    // true пока идёт транскод видео перед отправкой — держит панель «Подготовка
    // видео» видимой непрерывно (errorTimer её не прячет, см. onVideoPrepareProgress).
    property bool videoPreparing: false

    // Длительность текущей записи голосового (мс) — для таймера в оверлее.
    property int recordingMs: 0
    function formatDuration(ms) {
        var s = Math.floor((ms || 0) / 1000)
        var m = Math.floor(s / 60)
        s = s % 60
        return m + ":" + (s < 10 ? "0" + s : s)
    }
    function openVideo(messageId, filename) {
        if (!VoIPAvailable || !root.videoViewerComponent
                || root.videoViewerComponent.status !== Component.Ready) {
            errorText.text = qsTr("Проигрывание видео недоступно в этой сборке.")
            errorBar.visible = true
            errorTimer.restart()
            return
        }
        root.pendingVideoPlayId = messageId
        root._pendingVideoName = filename || "video.mp4"
        errorText.text = qsTr("Подготовка видео…")
        errorBar.visible = true
        errorTimer.restart()
        Chat.cacheVideoForPlayback(messageId)
    }
    property string _pendingVideoName: ""

    // Воспроизведение/пауза голосового сообщения. Файл материализуется тем же
    // FFI-путём, что и видео (cacheVideoForPlayback), играет VoicePlayer инлайн.
    function toggleVoice(messageId) {
        if (!VoIPAvailable || !root.voicePlayer) return
        if (root.voicePlayer.currentId === messageId) {
            root.voicePlayer.toggle(messageId, "")  // уже загружено — pause/resume
            return
        }
        root.pendingVoicePlayId = messageId
        Chat.cacheVideoForPlayback(messageId)
    }

    // Собрать медиа/файлы/ссылки из списка сообщений. Работает и с composed-строками
    // (photo_group → photos_json), и с сырыми (отдельные kind=="image"). Вход —
    // oldest-first; на выходе разворачиваем в newest-first (как лента).
    function buildAttachmentData(src) {
        var media = []
        var files = []
        var links = []
        var urlRe = /(https?:\/\/[^\s<>"'`]+)/g
        src = src || []
        for (var i = 0; i < src.length; ++i) {
            var m = src[i]
            if (m.kind === "photo_group") {
                var photos = []
                try { photos = JSON.parse(m.photos_json || "[]") } catch (e) { photos = [] }
                for (var j = 0; j < photos.length; ++j) {
                    var p = photos[j]
                    if (!p.id || p.id.length === 0) continue
                    // local — file:// своих фото (показывается сразу); ready — превью уже
                    // в провайдере (file:// или image://secure). Иначе галерея ДОТЯНЕТ
                    // превью по id (ensureGalleryPreview) — старые фото тоже попадают.
                    var pLocal = (p.source && p.source.indexOf("file://") === 0) ? p.source : ""
                    media.push({ id: p.id, messageId: m.id, local: pLocal, ready: (p.source && p.source.length > 0) === true,
                                 filename: (p.name && p.name.length > 0) ? p.name : "attachment.bin",
                                 ts: m.ts, size: p.size || 0 })
                }
            } else if (root.isImageMessage(m.kind, m.mime_type)) {
                var iLocal = m.local_preview || ""
                var iProv  = m.preview_source || ""
                media.push({ id: m.id, messageId: m.id, local: iLocal, ready: (iLocal.length > 0 || iProv.length > 0),
                             filename: (m.filename && m.filename.length > 0) ? m.filename : "attachment.bin",
                             ts: m.ts, size: m.size || 0 })
            } else if (m.kind === "video") {
                // Видео — в «Медиа» с пометкой isVideo (плашка ▶ на плитке).
                var vProv = m.preview_source || ""
                media.push({ id: m.id, messageId: m.id, local: "", ready: vProv.length > 0, isVideo: true,
                             filename: (m.filename && m.filename.length > 0) ? m.filename : "video.mp4",
                             ts: m.ts, size: m.size || 0 })
            } else if (m.kind === "file") {
                files.push({ id: m.id, name: root.fileNameFor(m), size: m.size,
                             mime: m.mime_type || "", ts: m.ts })
            }
            // Ссылки из текста любого сообщения (и подписи к вложению).
            var t = m.text || ""
            if (t.length > 0) {
                var match
                urlRe.lastIndex = 0
                while ((match = urlRe.exec(t)) !== null) {
                    links.push({ url: match[1], ts: m.ts, id: m.id,
                                 snippet: t.replace(/\s+/g, " ").trim() })
                }
            }
        }
        media.reverse(); files.reverse(); links.reverse()
        return { media: media, files: files, links: links }
    }

    // Открыть экран «Вложения диалога». Сразу показываем то, что уже загружено
    // (мгновенно), и параллельно дотягиваем ПОЛНУЮ историю диалога с сервера/БД —
    // когда придёт, обновляем экран (см. onAttachmentsHistoryLoaded).
    // Типизированная (Item) ссылка — QML авто-обнулит её при уничтожении страницы
    // (pop), поэтому onAttachmentsHistoryLoaded не тронет «мёртвый» объект.
    property Item _sharedMediaPage: null
    function openSharedMedia() {
        var d = root.buildAttachmentData(root._allMessages)
        root._sharedMediaPage = stackView.push(sharedMediaComponent, {
            peerName: root.displayName,
            peerId: root.peer,
            mediaItems: d.media,
            fileItems: d.files,
            linkItems: d.links,
            loadingMore: true
        })
        Chat.loadAllForAttachments(root.peer)
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
                                          name: m.filename || "", key: "", status: m.status,
                                          size: m.size || 0 })
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
        // Полноэкранное чтение перехватывает «назад»/свайп РАНЬШЕ выхода из диалога:
        // сперва выходим из режима выделения (если включён), затем закрываем ридер.
        if (textViewer.visible) {
            if (textViewer.selectMode) textViewer.selectMode = false
            else textViewer.close()
            return true
        }
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
        const vis = Object.keys(root.selectedIds)
        const ids = root.expandDeleteIds(vis)
        if (ids.length === 0) {
            root.exitSelection()
            return
        }
        // Анимация-шредер на всех выбранных пузырях, затем удаление (общий таймер).
        root.startShredder(vis, ids)
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

    // Дебаунс сохранения черновика. Раньше onTextChanged звал saveDraft() на
    // КАЖДЫЙ символ → setDraft → session->saveDialogs() (синхронная запись всех
    // диалогов под ffiMutex на GUI-потоке) → залипания при печати. Теперь печать
    // только перезапускает таймер; реальная запись — через 600мс после паузы.
    // Явные сохранения (отправка/закрытие страницы) флашат немедленно сами.
    Timer {
        id: draftSaveTimer
        interval: 600
        repeat: false
        onTriggered: root.saveDraft()
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
        // Оптимистичная отправка: стабильный ключ на всё время жизни строки
        // (sending → committed). Иначе при коммите id меняется (pending:→реальный) и
        // строка пересоздаётся (повторное «всплытие»/мерцание). client_token переносится
        // на committed в ChatBackend (dispatchOutbox + appendMessages).
        const ct = String(message.client_token || "")
        if (ct.length > 0) return "ct:" + ct
        const id = String(message.id || "")
        if (id.length > 0) return "id:" + id
        const seq = Number(message.seq || 0)
        return seq > 0 ? "seq:" + seq : ""
    }

    // ── Пагинация ленты (#39) ────────────────────────────────────────────
    // В ListView кладём ОКНО последних _windowCount сообщений, а не всю историю.
    // Лента ИНВЕРТИРОВАНА (BottomToTop): index 0 = НОВЕЙШЕЕ сообщение (внизу), далее
    // к старым вверх. _allMessages — хронологический порядок (старые→новые), окно
    // берём с конца (новейшие) и РАЗВОРАЧИВАЕМ при заливке в модель. Старые
    // раскрываются порциями, когда долистал до визуального верха (= конец модели,
    // onAtYEndChanged).
    property var _allMessages: []
    readonly property int _windowDefault: 50
    readonly property int _windowPage: 40
    property int _windowCount: 50
    property bool _loadingOlder: false

    function updateMessageModel(messages) {
        root._allMessages = messages
        const start = Math.max(0, messages.length - root._windowCount)
        const slice = start > 0 ? messages.slice(start) : messages
        // Разворачиваем: index 0 = новейшее (для BottomToTop-ленты).
        const windowed = slice.slice().reverse()
        // Пилюля-разделитель дня крепится к САМОМУ СТАРОМУ сообщению дня (рисуется НАД
        // ним → визуально вверху дневного блока). В newest-first окне это строка, у
        // которой следующая (i+1, ещё старее) — другой день, либо это верх загруженного.
        for (let di = 0; di < windowed.length; ++di) {
            const isDayTop = (di === windowed.length - 1)
                          || root.dayKey(windowed[di].ts) !== root.dayKey(windowed[di + 1].ts)
            windowed[di].daySep = isDayTop ? root.formatDaySeparator(windowed[di].ts) : ""
        }
        return root.reconcileModel(windowed)
    }

    // Лёгкая сигнатура ИЗМЕНЯЕМЫХ полей строки — чтобы set() трогал ТОЛЬКО реально
    // изменившиеся сообщения (статус отправки, реакции, правка, превью), а видимые
    // неизменные не дёргались (нет ре-рендера/реколлапса при чтении и приходе нового).
    function _msgSig(m) {
        if (!m) return ""
        return String(m.id || "") + "" + String(m.status || "") + ""
             + String(m.text || "") + "" + String(m.reactions_json || "") + ""
             + String(m.edited || "") + "" + String(m.preview_source || "") + ""
             + String(m.photos_json || "") + "" + String(m.kind || "")
             + "" + String(m.daySep || "")
    }

    // Инкрементальная сверка модели с окном (newest-first) — минимум операций
    // remove/insert/move/set вместо разрушительного clear()+append(). Это:
    //  • сохраняет существующие делегаты и позицию вьюпорта (ListView сам держит якорь
    //    при insert/remove) → УБИРАЕТ рывок при приходе нового во время чтения, телепорт
    //    при удалении в начале/середине и передёргивания (полный ребилд был их корнем);
    //  • включает add/remove/displaced-transitions (анимация появления/удаления).
    // Возврат: true = сделано инкрементально, ListView сам держит позицию (anchor-restore
    // не нужен); false = пришлось полностью пересобрать (вход в новый диалог) → вызывающий
    // восстановит позицию.
    property bool _popNewest: false
    function reconcileModel(windowed) {
        const n = windowed.length
        const prevCount = msgModel.count
        if (n === 0) { if (prevCount > 0) msgModel.clear(); return false }

        // Карта ключей нового окна (key → индекс).
        const newKeys = ({})
        for (let i = 0; i < n; ++i) newKeys[messageKey(windowed[i])] = i

        // Нет пересечения со старой моделью (полная смена диалога) → дешевле rebuild.
        if (prevCount > 0) {
            let overlap = false
            for (let i = 0; i < prevCount; ++i) {
                if (newKeys[messageKey(msgModel.get(i))] !== undefined) { overlap = true; break }
            }
            if (!overlap) {
                msgModel.clear()
                for (let i = 0; i < n; ++i) msgModel.append(windowed[i])
                return false
            }
        }

        // 1. Удалить строки, которых нет в новом окне (с конца — индексы не съезжают).
        for (let i = msgModel.count - 1; i >= 0; --i) {
            if (newKeys[messageKey(msgModel.get(i))] === undefined) msgModel.remove(i)
        }
        // 2. Прямой проход: выровнять позиции вставкой/перемещением + set изменившихся.
        let insertedNewest = false
        for (let i = 0; i < n; ++i) {
            const wk = messageKey(windowed[i])
            if (i < msgModel.count && messageKey(msgModel.get(i)) === wk) {
                if (_msgSig(msgModel.get(i)) !== _msgSig(windowed[i])) msgModel.set(i, windowed[i])
                continue
            }
            let j = -1
            for (let k = i + 1; k < msgModel.count; ++k) {
                if (messageKey(msgModel.get(k)) === wk) { j = k; break }
            }
            if (j >= 0) {
                msgModel.move(j, i, 1)
                if (_msgSig(msgModel.get(i)) !== _msgSig(windowed[i])) msgModel.set(i, windowed[i])
            } else {
                msgModel.insert(i, windowed[i])
                if (i === 0) insertedNewest = true
            }
        }
        // 3. Подрезать хвост (страховка).
        while (msgModel.count > n) msgModel.remove(msgModel.count - 1)

        // Анимация появления — только для реально нового новейшего (index 0) на ЖИВОМ
        // апдейте (не на первичном наполнении: prevCount === 0). Драйвер — ОДНА root-
        // анимация _revealValue 0→1 для делегата с ключом _revealKey. Исходящие — пилюля,
        // входящие — дешифровка текста (см. делегат).
        if (insertedNewest && prevCount > 0 && Date.now() >= root._animSuppressUntil) {
            // Dedup-страховка: commit оптимистичной отправки может из-за гонки poll/commit
            // прийти как ОТДЕЛЬНАЯ вставка (если client_token не сматчился) → анимация
            // перезапускалась бы («дважды»). Тот же текст+направление за <4с — не
            // перезапускаем. (На устройстве реконсиляция по тексту в appendMessages делает
            // commit обычным set() и сюда повторно не заходит.)
            const m0  = msgModel.get(0)
            const sig = (m0.isMe ? "1" : "0") + "" + String(m0.text || "")
            const dup = (sig === root._lastAnimSig && (Date.now() - root._lastAnimAt) < 4000)
            // ВСЕГДА переносим ключ на текущий новейший делегат — иначе при коммите
            // оптимистичной (committed мог прийти ОТДЕЛЬНОЙ вставкой из-за гонки poll/commit
            // → делегат пересоздаётся с НОВЫМ ключом) анимация обрывалась бы мгновенно
            // (_delegateKey != _revealKey) → визуально «анимации нет».
            root._revealKey = messageKey(windowed[0])
            if (!dup) {
                // Реально новое — запускаем; дубль (commit того же) — только перенос ключа
                // выше, БЕЗ перезапуска драйвера (анимация продолжается, не играет дважды).
                root._lastAnimSig = sig
                root._lastAnimAt  = Date.now()
                root._popNewest   = true
                popResetTimer.restart()
                // Исходящая пилюля — бодрее; входящая дешифровка — медленно/читаемо.
                revealDriver.duration = m0.isMe
                    ? 300
                    : Math.max(420, Math.min(1800, Math.round(String(m0.text || "").length * 22)))
                revealDriver.restart()
            }
        }
        return true
    }
    property string _lastAnimSig: ""
    property double _lastAnimAt: 0
    // До этого момента (мс, Date.now) анимация появления подавлена — ставится при ВХОДЕ
    // в диалог, чтобы пачка непрочитанных не ломала раскладку дешифровкой (см. wasEmpty).
    property double _animSuppressUntil: 0

    // Снимает флаг «всплытия» после старта add-transition, чтобы последующие вставки
    // (пагинация старых, рендер при скролле) не анимировались.
    Timer { id: popResetTimer; interval: 220; repeat: false; onTriggered: root._popNewest = false }

    // «Принтерный» reveal нового пузыря: _revealValue 0→1 (доля раскрытого текста
    // сверху-вниз). Делегат с ключом == _revealKey тянет по нему шторку.
    property string _revealKey: ""
    property real _revealValue: 1.0
    NumberAnimation {
        id: revealDriver
        target: root; property: "_revealValue"
        from: 0.0; to: 1.0; duration: 1650; easing.type: Easing.OutCubic
    }
    // Тик «мерцания» нерасшифрованных символов (каракули меняются), пока идёт reveal.
    property int _scrambleTick: 0
    Timer {
        running: revealDriver.running
        interval: 45; repeat: true
        onTriggered: root._scrambleTick = (root._scrambleTick + 1) % 100000
    }
    // «Дешифровка»: первые p*len символов — настоящие, остальные — псевдослучайные глифы
    // (меняются с tick). Пробелы/переводы строк сохраняем — держит форму строк. Сверху-вниз
    // (=по порядку строки, текст так и течёт). Псевдо-ГСЧ по (i,tick) — без Math.random,
    // плавно и детерминированно на кадр.
    readonly property string _scrGlyphs: "ABCDEF0123456789#$%&*<>/\\|=+?АБВГДЕЖЗИКЛ▒▓░"
    function decryptStr(real, p, tick) {
        const n = real.length
        if (n === 0) return ""
        const reveal = Math.floor(p * n)
        const g = root._scrGlyphs, gl = g.length
        let out = ""
        for (let i = 0; i < n; ++i) {
            const c = real.charAt(i)
            if (i < reveal || c === " " || c === "\n" || c === "\t" || c === "\r") { out += c; continue }
            const r = ((i + 1) * 2654435761 + tick * 40503 + (i << 4)) >>> 0
            out += g.charAt(r % gl)
        }
        return out
    }

    // Раскрыть ещё страницу старых сообщений (когда долистал до визуального верха).
    // В инвертированной ленте старые добавляются в КОНЕЦ модели (выше по экрану) —
    // дно (index 0) не двигается, поэтому видимая позиция сохраняется сама собой;
    // anchor-restore оставлен как страховка от скачка на стыке.
    function loadOlderMessages() {
        if (root._loadingOlder) return
        if (root._windowCount >= root._allMessages.length) return
        root._loadingOlder = true
        const anchor = root.visibleMessageAnchor()
        root._windowCount = Math.min(root._allMessages.length, root._windowCount + root._windowPage)
        root.updateMessageModel(root._allMessages)
        root.restoreVisibleMessageAnchor(anchor)
        Qt.callLater(function() { root._loadingOlder = false })
    }

    // Показать новейшее сообщение внизу. В ИНВЕРТИРОВАННОЙ ленте новейшее — index 0,
    // и «дно» = positionViewAtBeginning. Якорь дна (index 0) всегда реализован →
    // позиционирование стабильно, без зависимости от оценочной contentHeight и без
    // дрейфа (в отличие от positionViewAtEnd на не-инверт. ленте — корень #39).
    function pinToBottom() {
        if (!listView || msgModel.count === 0) return
        // ВНИЗ к новейшему. Для сообщения ВЫШЕ вьюпорта positionViewAtIndex(0, End)
        // клампится к ВЕРХУ (видна первая строка — жалоба Иванова), positionViewAtEnd()
        // уходит к СТАРЕЙШЕМУ, а contentY из оценочного contentHeight сразу после вставки
        // занижен (delegate ещё не учтён). Самое надёжное — РЕАЛЬНАЯ геометрия делегата
        // index 0 (новейшее, всегда реализован у низа): ставим его НИЗ (item.y+height) к
        // нижнему краю вьюпорта. Если ещё не реализован — fallback realize'ит, следующий
        // пин (callLater/таймер) доведёт по факт. геометрии.
        // Применить отложенные изменения модели → contentHeight учитывает фактическую
        // высоту нового делегата (иначе оценка отстаёт: низ нового сообщения торчит ниже
        // originY+contentHeight, и clampListContentY режет target).
        listView.forceLayout()
        const item = listView.itemAtIndex(0)
        if (item) {
            // Низ новейшего (item.y+height) к нижнему краю вьюпорта. Берём максимум с
            // contentHeight-границей на случай, если оценка всё ещё чуть меньше факт. низа.
            const target = item.y + item.height - listView.height
            const maxY = Math.max(listView.originY + listView.contentHeight - listView.height, target)
            listView.contentY = Math.max(listView.originY, Math.min(target, maxY))
        } else {
            listView.positionViewAtIndex(0, ListView.End)
        }
    }

    // Явный «к низу» (вход, кнопка «вниз», отправка). Один pin + пара отложенных —
    // дёшево и надёжно докручивает к index 0 после досоздания делегатов.
    function settleToBottom() {
        if (!listView) return
        listView.stickToBottom = true
        root.pinToBottom()
        Qt.callLater(root.pinToBottom)
        // Повторный пин на время ОСЕДАНИЯ раскладки: высота нового тяжёлого делегата
        // считается не мгновенно, а оценочный contentHeight (через него clampListContentY
        // ограничивает target) догоняет постепенно; плюс оптимистичная отправка через
        // ~0.5–1с коммитится (set() → высота снова меняется). Одного пина мало — новое
        // высокое сообщение оставалось «первой строкой». Тикаем ~1.2с (ограниченно, не
        // петля #39), гард stickToBottom: юзер листнул вверх — прекращаем.
        root._pinTicks = 0
        bottomPinTimer.restart()
    }

    property int _pinTicks: 0
    // Дотягивает вид к низу, пока оседают высоты делегатов (см. settleToBottom).
    Timer {
        id: bottomPinTimer
        interval: 80
        repeat: true
        onTriggered: {
            if (listView && listView.stickToBottom) root.pinToBottom()
            root._pinTicks++
            if (root._pinTicks >= 15 || !listView || !listView.stickToBottom) stop()
        }
    }

    // «У новейшего» = визуальный низ инверт-ленты. КВИРК BottomToTop: index 0
    // (новейшее) лежит у нижнего края, и по Y это соответствует atYEnd (а не
    // atYBeginning); старейшее (визуальный верх, конец модели) — atYBeginning.
    function isListAtEnd() {
        if (!listView) return true
        if (listView.contentHeight <= listView.height) return true
        return listView.atYEnd
            || (listView.contentY + listView.height >= listView.originY + listView.contentHeight - 24)
    }

    function clampListContentY(y) {
        const minY = listView.originY
        const maxY = Math.max(minY, minY + listView.contentHeight - listView.height)
        return Math.min(Math.max(y, minY), maxY)
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

    // Переход к сообщению по id из галереи вложений: при необходимости расширяет
    // окно ленты (сообщение могло быть вне последних _windowCount), затем скроллит
    // и кратко подсвечивает пузырь. _allMessages — oldest-first, окно = последние N.
    function jumpToMessageById(messageId) {
        if (!messageId || messageId.length === 0) return
        let idx = -1
        for (let i = 0; i < root._allMessages.length; ++i)
            if (root._allMessages[i].id === messageId) { idx = i; break }
        if (idx >= 0) {
            const needed = root._allMessages.length - idx + 4
            if (root._windowCount < needed) {
                root._windowCount = Math.min(root._allMessages.length, needed)
                root.updateMessageModel(root._allMessages)
            }
        }
        root._flashMessageId = messageId
        flashTimer.restart()
        // Геометрия делегатов досчитывается после обновления модели — скроллим в
        // следующем кадре, иначе positionViewAtIndex может промахнуться.
        Qt.callLater(function() { root.scrollToMessageId(messageId) })
    }

    Timer {
        id: flashTimer
        interval: 1700
        onTriggered: root._flashMessageId = ""
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
            // Свежий вход в диалог → окно на дефолт (последние N), без накопленного
            // _windowCount от прошлого открытия (пагинация #39).
            if (wasEmpty) {
                root._windowCount = root._windowDefault
                // Подавляем анимацию появления на ~1.5с после ВХОДА в диалог: непрочитанные
                // догружаются разом и, дешифруясь, ломали раскладку инверт-ленты (наложение
                // пузырей). Они просто появляются; дешифровка остаётся для сообщений,
                // пришедших в УЖЕ открытый диалог. (repro Иванова: вход с новыми → наложение.)
                root._animSuppressUntil = Date.now() + 1500
            }
            // Следовать низу на входе в диалог И на всех догрузках, пока юзер сам не
            // пролистнул вверх (тогда stickToBottom станет false на его жесте). Раньше
            // решение бралось по сиюминутному isListAtEnd(): первый pin не успевал
            // доехать до низа (высоты делегатов досчитываются позже), вторая догрузка
            // видела «не в конце» → уходила в anchor-restore и фиксировала СЕРЕДИНУ →
            // диалог открывался не внизу (#39).
            const stick = wasEmpty || listView.stickToBottom
            const anchor = stick ? null : root.visibleMessageAnchor()
            const previousContentY = listView.contentY
            if (root.updateMessageModel(messages)) {
                if (stick) Qt.callLater(function() { if (listView) root.settleToBottom() })
                if (root.searchActive) root.recomputeSearchMatches()
                return
            }
            Qt.callLater(function() {
                if (!listView) return // страница могла быть разрушена до отложенного вызова
                if (stick) {
                    root.settleToBottom()
                    return
                }

                if (root.restoreVisibleMessageAnchor(anchor)) return

                listView.contentY = root.clampListContentY(previousContentY)
            })
            if (root.searchActive) root.recomputeSearchMatches()
        }
        function onAttachmentsHistoryLoaded(peer, messages) {
            if (peer !== root.peer) return
            if (!root._sharedMediaPage) return
            var d = root.buildAttachmentData(messages)
            var newTotal = d.media.length + d.files.length + d.links.length
            var page = root._sharedMediaPage
            var curTotal = page.mediaItems.length + page.fileItems.length + page.linkItems.length
            // НЕ понижаем: если полная выгрузка вернула пусто/меньше (ошибка дешифра
            // одного старого сообщения роняет всю выборку в FFI) — оставляем мгновенный
            // снимок, иначе галерея «опустела бы». Применяем только если данных БОЛЬШЕ.
            if (newTotal >= curTotal) {
                page.mediaItems = d.media
                page.fileItems = d.files
                page.linkItems = d.links
            }
            page.loadingMore = false
        }
        function onGalleryPreviewReady(messageId) {
            if (root._sharedMediaPage) root._sharedMediaPage.markPreviewReady(messageId)
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
            // Мобильный нативный пикер — складываем в стейджинг (как десктоп-диалоги).
            // Тип угадываем по расширению (фото/видео), отправится при «Отправить».
            for (var i = 0; i < uris.length; ++i)
                root.stageAttachment(uris[i])
        }
        // ── Видео: транскод перед отправкой («Подготовка…») ──
        // ── Голосовое: тик длительности записи ──
        function onVoiceRecordingDurationMs(ms) {
            root.recordingMs = ms
        }
        function onVideoPrepareProgress(peer, fraction) {
            if (peer !== root.peer) return
            // Панель держится постоянно (видна, пока videoPreparing) — у больших
            // видео апдейты процента редкие, errorTimer её не спрячет (см. таймер).
            root.videoPreparing = true
            errorText.text = qsTr("Подготовка видео… %1%").arg(Math.round(fraction * 100))
            errorBar.visible = true
        }
        function onVideoPrepareFinished(peer, ok) {
            if (peer !== root.peer) return
            root.videoPreparing = false
            if (ok) {
                errorText.text = qsTr("Видео готово, отправляю…")
                errorBar.visible = true
                errorTimer.restart()   // теперь можно скрыть по таймеру
            } else {
                errorTimer.restart()
            }
        }
        // ── Видео/голосовое: материализация для проигрывания (один FFI-путь) ──
        function onVideoReadyForPlayback(messageId, fileUrl) {
            if (messageId === root.pendingVoicePlayId) {
                root.pendingVoicePlayId = ""
                if (root.voicePlayer) root.voicePlayer.toggle(messageId, fileUrl)
                return
            }
            if (messageId !== root.pendingVideoPlayId) return
            root.pendingVideoPlayId = ""
            errorBar.visible = false
            if (root.videoViewerComponent && root.videoViewerComponent.status === Component.Ready) {
                stackView.push(root.videoViewerComponent,
                               { source: fileUrl, title: root._pendingVideoName })
            }
        }
        function onVideoPlaybackError(messageId, error) {
            if (messageId === root.pendingVoicePlayId) root.pendingVoicePlayId = ""
            if (messageId !== root.pendingVideoPlayId && messageId !== root.pendingVoicePlayId) {
                // не наш — но всё равно покажем
            }
            root.pendingVideoPlayId = ""
            errorText.text = error
            errorBar.visible = true
            errorTimer.restart()
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
        root._refreshPeerInfo()
        restoreDraft()
        applyShareTarget()
        if (VoIPAvailable) {
            root.callPageComponent = Qt.createComponent(
                Qt.resolvedUrl("CallPage.qml"), Component.PreferSynchronous);
            if (root.callPageComponent.status === Component.Error)
                console.warn("CallPage load error:", root.callPageComponent.errorString());
            root.videoViewerComponent = Qt.createComponent(
                Qt.resolvedUrl("../Components/VideoViewer.qml"), Component.PreferSynchronous);
            if (root.videoViewerComponent.status === Component.Error)
                console.warn("VideoViewer load error:", root.videoViewerComponent.errorString());
            var vpc = Qt.createComponent(
                Qt.resolvedUrl("../Components/VoicePlayer.qml"), Component.PreferSynchronous);
            if (vpc.status === Component.Ready)
                root.voicePlayer = vpc.createObject(root);
            else if (vpc.status === Component.Error)
                console.warn("VoicePlayer load error:", vpc.errorString());
        }
        // Тяжёлую загрузку диалога (Chat.openChat — синхронный FFI: расшифровка
        // кэша диалога, ~0.5с фриз GUI-потока) ОТКЛАДЫВАЕМ на ~кадр. Так сперва
        // отрисуется страница со спиннером-лого (он крутится на render-потоке и не
        // замирает), а фриз пройдёт уже ПОД анимацией, а не на пустом переходе.
        // (Идея юзера: открыть диалог → показать анимацию загрузки → грузить контент.)
        // Тяжёлую загрузку запускаем ПОСЛЕ первого отрендеренного кадра окна
        // (frameSwapped) — гарантия, что спиннер-лого уже на экране ДО фриза
        // GUI-потока (тогда RotationAnimator крутит его через render-поток ВСЁ время
        // фриза). Таймер 250мс — фолбэк, если кадр почему-то не пришёл. (#2/#47 Option A)
    }
    property bool _openChatStarted: false
    function _startOpenChat() {
        if (root._openChatStarted) return
        root._openChatStarted = true
        Chat.openChat(root.peer)
    }
    Connections {
        target: root.Window.window
        enabled: !root._openChatStarted
        function onFrameSwapped() { root._startOpenChat() }
    }
    Timer { interval: 250; running: true; repeat: false; onTriggered: root._startOpenChat() }

    // ── Стейджинг вложений ───────────────────────────────────────────────────
    function guessAttachmentKind(path) {
        const lp = String(path).toLowerCase()
        if (/\.(png|jpe?g|gif|webp|bmp|tiff?|heic|heif)(\?|$)/.test(lp)) return "image"
        if (/\.(mp4|mov|mkv|webm|avi|m4v|3gp|ogv)(\?|$)/.test(lp)) return "video"
        return "file"
    }

    function stageAttachment(p, kind) {
        if (!p) return
        const path = String(p)
        if (path.length === 0) return
        // Имя: последний сегмент пути без query (?...).
        let name = path.split('?')[0]
        name = name.substring(name.lastIndexOf('/') + 1)
        if (name.length === 0) name = qsTr("вложение")
        const arr = root.pendingAttachments.slice()
        arr.push({ path: path, name: name, kind: kind || root.guessAttachmentKind(path) })
        root.pendingAttachments = arr
        msgInput.forceActiveFocus()
    }

    function removeAttachmentAt(i) {
        if (i < 0 || i >= root.pendingAttachments.length) return
        const arr = root.pendingAttachments.slice()
        arr.splice(i, 1)
        root.pendingAttachments = arr
    }

    function clearAttachments() { root.pendingAttachments = [] }

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
            // Раньше тут был мгновенный sendFile (молча падал на share-кэше и
            // не давал дописать текст). Теперь — прикрепляем в стейджинг: юзер
            // видит вложение, может добавить подпись и отправить кнопкой.
            for (let i = 0; i < files.length; ++i) {
                const candidate = files[i] ? String(files[i]) : ""
                if (candidate.length > 0) root.stageAttachment(candidate)
            }
        }
    }
    Component.onDestruction: {
        saveDraft()
        Chat.stopChat()
        // Чистим расшифрованные playback-файлы (видео/голос) при выходе из диалога —
        // чтобы plaintext-медиа не залёживалось в кэше.
        Chat.clearPlaybackCache()
    }

    ParaFileDialog {
        id: attachDialog
        title: qsTr("Выберите файл")
        mode: "open"
        onAccepted: root.stageAttachment(selectedFile, "file")
    }

    ParaFileDialog {
        id: photoDialog
        title: qsTr("Выберите фото")
        // Мультивыбор: несколько фото прикрепляются в стейджинг (отправятся
        // мозаикой-группой с подписью при нажатии «Отправить»).
        mode: "openMultiple"
        nameFilters: [qsTr("Изображения (*.png *.jpg *.jpeg *.gif *.webp *.bmp *.tiff *.heic *.heif)"), qsTr("Все файлы (*)")]
        onAccepted: {
            for (var i = 0; i < selectedFiles.length; ++i)
                root.stageAttachment(selectedFiles[i], "image")
        }
    }

    ParaFileDialog {
        id: videoDialog
        title: qsTr("Выберите видео")
        mode: "open"
        nameFilters: [qsTr("Видео (*.mp4 *.mov *.mkv *.webm *.avi *.m4v *.3gp *.ogv)"), qsTr("Все файлы (*)")]
        onAccepted: root.stageAttachment(selectedFile, "video")
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
        // modal (без затемнения): закрывающий press-outside поглощается оверлеем
        // и НЕ проваливается на inline-/блок-код сообщения под меню — иначе тап
        // «мимо, чтобы закрыть» случайно копировал текст и показывал тост.
        modal: true
        dim: false
        // focus:false — меню НЕ забирает фокус у поля ввода. Иначе на мобиле при
        // открытии меню VKB пряталась, а при закрытии всплывала (фокус возвращался
        // в msgInput) — даже если клавиатуры не было; смена геометрии дёргала UI и
        // меню вставало не над тем сообщением (#29). Закрытие — по press-outside
        // (модальный оверлей) и по действиям меню; Escape на десктопе — оверлеем.
        focus: false
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
            radius: Theme.radiusLg
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
                    ScrollBar.vertical: AppScrollBar { policy: ScrollBar.AsNeeded }

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
                                radius: height / 2          // круглые кнопки реакций
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
                            radius: height / 2          // круглая кнопка настройки реакций
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
                        // Не удаляем сразу: запускаем анимацию-шредер на пузыре; по её
                        // завершении общий таймер вызовет реальное удаление.
                        if (id.length > 0) root.startShredder([id], root.expandDeleteIds([id]))
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
            radius: Theme.radiusLg
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
            radius: Theme.radiusLg
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
            radius: Theme.radiusLg
            border.width: 1
            border.color: Theme.border
        }
        contentItem: Column {
            id: attachMenuColumn
            width: attachMenu.width - attachMenu.leftPadding - attachMenu.rightPadding
            spacing: 2

            Repeater {
                model: [
                    { label: qsTr("Файл"),       icon: "file"  },
                    { label: qsTr("Фото"),       icon: "image" },
                    { label: qsTr("Видео"),      icon: "video" },
                    { label: qsTr("Голосовое"),  icon: "mic"   }
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
                            } else if (index === 2) {
                                if (Qt.platform.os === "android") Chat.pickVideoFromGallery()
                                else videoDialog.open()
                            } else {
                                // Голосовое: начинаем запись, показываем оверлей записи.
                                root.recordingMs = 0
                                Chat.startVoiceRecording()
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
                anchors.rightMargin: 6
                spacing: 3
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

                // Avatar (локальный аватар или буква по отображаемому имени)
                Rectangle {
                    id: headerAvatar
                    width: 36; height: 36
                    radius: width / 2     // кружок — единообразно со списком (стандарт мессенджеров)
                    color: Theme.bgCard
                    border.width: 1
                    border.color: Theme.accentDim
                    clip: true

                    // ВАЖНО: НЕ вызывать .length/.charAt на ВЫРАЖЕНИИ ((x||"")…) —
                    // qmlcachegen AOT мис-типизирует результат и компилит .length как
                    // indexOfProperty("length") на битом QMetaObject → SIGSEGV при
                    // инкубации страницы (крашило вход в ЛЮБОЙ диалог). На ПРЯМОМ
                    // string-свойстве методы безопасны (как было у root.peer.charAt).
                    // hasAvatar — сравнение без метода; displayName всегда непустой
                    // (дефолт = peer, _refreshPeerInfo не ставит пустое).
                    readonly property bool hasAvatar: root.avatar !== ""

                    Text {
                        anchors.centerIn: parent
                        visible: !headerAvatar.hasAvatar
                        text: root.displayName.charAt(0).toUpperCase()
                        color: Theme.accentHover
                        font.pixelSize: Theme.fontMd
                        font.weight: Font.Bold
                    }

                    // Круг запечён в PNG (см. setDialogAvatar) → обычный Image без
                    // QML-маски/MultiEffect (та создавала FBO и вешала UI на GPU).
                    Image {
                        id: headerAvatarImg
                        anchors.fill: parent
                        visible: headerAvatar.hasAvatar && status === Image.Ready
                        source: headerAvatar.hasAvatar ? root.avatar : ""
                        fillMode: Image.PreserveAspectFit
                        mipmap: true
                    }
                }

                Column {
                    Layout.fillWidth: true
                    spacing: 2
                    Text {
                        text: root.displayName
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

                // Три кнопки в своём Row (spacing 0) — внешний spacing их больше не
                // растягивает; стоят плотной группой у правого края.
                RowLayout {
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 0

                // Поиск по диалогу
                Rectangle {
                    Layout.preferredWidth: 30
                    Layout.preferredHeight: 34
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

                // Вложения диалога (медиа/файлы/ссылки)
                Rectangle {
                    Layout.preferredWidth: 30
                    Layout.preferredHeight: 34
                    Layout.alignment: Qt.AlignVCenter
                    radius: Theme.radiusSm
                    color: mediaHeaderArea.containsMouse ? Theme.bgCard : "transparent"
                    border.width: mediaHeaderArea.containsMouse ? 1 : 0
                    border.color: Theme.border

                    AppIcon {
                        anchors.centerIn: parent
                        width: 22; height: 22
                        name: "image"
                        iconColor: Theme.accentHover
                        strokeWidth: 2
                    }

                    MouseArea {
                        id: mediaHeaderArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.openSharedMedia()
                    }
                }

                // Видна только если voip собран. Наличие master_key проверяется перед стартом вызова.
                CallButton {
                    visible: VoIPAvailable
                    Layout.preferredWidth: 30
                    Layout.preferredHeight: 34
                    Layout.alignment: Qt.AlignVCenter
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
                } // конец Row из трёх кнопок
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
                    radius: 20          // как у поля ввода сообщений (скруглённая пилюля)
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
                            // И preeditText: при предиктивном вводе (Android) набранное
                            // сидит в preeditText, а text пуст → иначе плейсхолдер не
                            // прятался и НАЕЗЖАЛ на вводимый текст.
                            visible: searchField.text.length === 0 && searchField.preeditText.length === 0
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
                    radius: 16
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
                    radius: 16
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
                    radius: 16
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
                // ИНВЕРТИРОВАННАЯ лента (как во всех чат-клиентах). Новейшее сообщение —
                // index 0, лежит у НИЗА. «Дно» диалога = positionViewAtBeginning /
                // atYBeginning, и якорь дна (index 0) ВСЕГДА реализован → высоты старых
                // сообщений выше не двигают дно. Это снимает корневую причину #39:
                // делегаты с rich-text/кодом отдают нестабильную высоту (минимальную до
                // реализации, реальную после), из-за чего contentHeight на не-инверт.
                // ленте осциллировала и любой bottom-anchor через contentY/индекс
                // дрейфовал и морозил UI. Модель заполняется новейшими-первыми
                // (updateMessageModel разворачивает срез).
                verticalLayoutDirection: ListView.BottomToTop
                // Пока зажат чекбокс drag-select, отключаем встроенный Flickable, иначе
                // ListView перехватывает вертикальный жест и устраивает flick
                // (визуально это и был тот «телепорт на страницу»).
                interactive: !root._dragSelectActive

                model: ListModel { id: msgModel }

                // Пред-реализуем ~2 экрана соседних делегатов. У тяжёлых rich-text/код-
                // сообщений высота нестабильна (минимальная до реализации, реальная после);
                // больший cacheBuffer держит соседей уже измеренными → оценка contentHeight
                // далеко от низа меньше «прыгает», уходит самопрокрутка на 1-2 сообщения.
                cacheBuffer: Math.round(Math.max(height, 600) * 2)

                ScrollBar.vertical: AppScrollBar {}

                // ── Анимации блоков ленты ────────────────────────────────────
                // add: новейшее (index 0) «всплывает» облачком (scale 0→1 БЕЗ overshoot —
                //   overshoot читался как двойной дёрг). Гейт root._popNewest → ТОЛЬКО на
                //   реально новом снизу, не на пагинации/первичном наполнении/скролле.
                //   scale — визуальный, на раскладку не влияет → пин к низу не ломает.
                add: Transition {
                    enabled: root._popNewest
                    // Мягкое проявление пузыря (часто гасится пином/forceLayout — тогда
                    // сообщение просто появляется; это ОК). Анимация отправки убрана.
                    // Входящие — «дешифровка» текста (делегат).
                    NumberAnimation { property: "opacity"; from: 0.0; to: 1.0; duration: 180; easing.type: Easing.OutCubic }
                }
                // addDisplaced: МГНОВЕННО. Новое снизу толкает остальных вверх — если их
                // смещение анимировать, при отправке вся лента дёргается, а пин к низу
                // гонится за движущимся контентом и «не доезжает» (сообщение висело
                // серединкой). Ставим на места сразу, вид доводит settleToBottom.
                addDisplaced: Transition {
                    NumberAnimation { properties: "x,y"; duration: 0 }
                    NumberAnimation { properties: "scale,opacity"; to: 1.0; duration: 0 }
                }
                // removeDisplaced: плавный глайд соседей вверх при удалении (в т.ч.
                // множественном) — вместо телепорта.
                removeDisplaced: Transition {
                    NumberAnimation { properties: "x,y"; duration: 180; easing.type: Easing.OutQuad }
                    NumberAnimation { properties: "scale,opacity"; to: 1.0; duration: 120 }
                }
                remove: Transition {
                    NumberAnimation { property: "opacity"; to: 0.0; duration: 110 }
                }

                // «Прилипание к новейшему»: стоим ли у визуального низа (index 0).
                // В инверт-ленте дно анкерится само (index 0 у нижнего края), поэтому
                // НИКАКОГО дебаунс-пина на contentHeightChanged не нужно — это и была
                // runaway-петля #39. На смену высоты вьюпорта (клавиатура) докручиваем
                // к низу один раз, если стояли там.
                property bool stickToBottom: true
                onHeightChanged: if (stickToBottom) Qt.callLater(root.pinToBottom)
                onMovementEnded: stickToBottom = root.isListAtEnd()
                onDraggingChanged: if (!dragging) stickToBottom = root.isListAtEnd()
                // Долистал до визуального ВЕРХА = конец инверт-модели (старейшее), по Y
                // это atYBeginning → раскрыть ещё страницу старых сообщений (#39).
                onAtYBeginningChanged: if (atYBeginning && !root._loadingOlder) root.loadOlderMessages()

                delegate: Item {
                    width: listView.width
                    // Разделитель-пилюля дня (если есть) добавляется НАД пузырём, увеличивая
                    // высоту строки сверху; пузырь остаётся в нижней части (см. verticalCenterOffset).
                    readonly property string daySepLabel: model.daySep || ""
                    readonly property bool hasDaySep: daySepLabel.length > 0
                    readonly property real daySepH: hasDaySep ? 38 : 0
                    height: bubble.implicitHeight + 8 + daySepH
                    // Пилюля-втекание масштабируется от нижнего угла со стороны отправителя
                    // (у исходящих — низ-право, ближе к полю ввода). См. add-transition.
                    transformOrigin: (model.isMe === true) ? Item.BottomRight : Item.BottomLeft

                    readonly property int delegateIndex: index
                    readonly property bool isSearchMatch: root.searchActive && root.searchMatchIndices.indexOf(delegateIndex) >= 0
                    readonly property bool isSearchCurrent: isSearchMatch
                                                           && root.searchCurrentIndex >= 0
                                                           && root.searchMatchIndices[root.searchCurrentIndex] === delegateIndex
                    // Кратковременная подсветка при переходе из галереи вложений.
                    readonly property bool isFlash: root._flashMessageId.length > 0 && model.id === root._flashMessageId
                    readonly property bool isMe: model.isMe === true
                    // Анимация появления (один root-драйвер root._revealValue 0→1, для
                    // делегата с ключом == root._revealKey). Исходящие — пилюля втекает
                    // (scale+проявление), входящие — принтер (шторка вниз раскрывает текст).
                    readonly property string _delegateKey: root.messageKey(model)
                    readonly property bool _animating: _delegateKey.length > 0 && _delegateKey === root._revealKey && root._revealValue < 1.0
                    readonly property real _rv: _animating ? root._revealValue : 1.0
                    readonly property string mimeType: model.mime_type || ""
                    readonly property bool isImage: root.isImageMessage(model.kind, mimeType)
                    readonly property bool isVideo: model.kind === "video"
                    readonly property bool isVoice: model.kind === "voice"
                    // Визуальное медиа в пузыре (превью-картинкой): фото ИЛИ видео.
                    readonly property bool isVisualMedia: isImage || isVideo
                    readonly property bool isPhotoGroup: model.kind === "photo_group"
                    readonly property var groupPhotos: {
                        if (!isPhotoGroup) return []
                        try { return JSON.parse(model.photos_json || "[]") } catch (e) { return [] }
                    }
                    readonly property bool hasAttachment: model.kind === "file" || model.kind === "image" || model.kind === "voice" || model.kind === "video" || isImage
                    readonly property bool showMessageText: !hasAttachment && !isPhotoGroup && (model.text || "").length > 0
                    readonly property bool showFileCard: hasAttachment && !isVisualMedia && !isVoice
                    // «Простыня»: текст занимает больше ~10 строк на экране (высота уже
                    // посчитана с учётом переноса при текущей ширине пузыря) → показываем
                    // кнопку-уголки для чтения на весь экран.
                    readonly property real _msgLineH: Math.round(Theme.fontMd * 1.3)
                    readonly property bool isLongText: showMessageText && msgText.visible
                                                       && msgText.implicitHeight > _msgLineH * 10
                    // Ограничение высоты ОЧЕНЬ длинных пузырей inline (~18 строк). Делает
                    // высоты делегатов ОГРАНИЧЕННЫМИ → оценка contentHeight в ListView
                    // перестаёт «прыгать» при скролле тяжёлых сообщений (корень телепорта).
                    // Полный текст — по кнопке-уголкам в полноэкранном ридере (уже есть).
                    readonly property real _maxInlineH: _msgLineH * 18
                    readonly property bool _clampText: showMessageText && msgText.visible
                                                       && msgText.implicitHeight > _maxInlineH
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

                    // Анимация-шредер при удалении (по запросу из меню). Loader держит
                    // Этот пузырь сейчас «режется» (в наборе shreddingIds) — одиночное
                    // или множественное удаление. Реальное удаление делает общий таймер
                    // root.shredCommitTimer после анимации; делегат только анимирует.
                    readonly property bool isShredding: root.shreddingIds[model.id] === true
                    // Восстанавливаем видимость пузыря, когда перестали резать (набор
                    // очищен после удаления / делегат переиспользован ListView).
                    onIsShreddingChanged: if (!isShredding && bubble) bubble.opacity = 1

                    Loader {
                        id: shredderLoader
                        active: parent.isShredding
                        anchors.fill: bubble
                        z: 50
                        sourceComponent: ShredderOverlay {
                            sourceItem: bubble
                            // Удаление — общий таймер; здесь ничего не делаем.
                        }
                    }

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

                    // Tap по чекбоксу — тоггл выделения. Press-and-drag:
                    // режим (add/remove) определяется тем, был
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
                    if (isVisualMedia && previewSource.length === 0)
                        Chat.ensureImagePreview(model.id)
                }

                // Разделитель-пилюля дня по центру над первым сообщением каждого дня.
                Rectangle {
                    id: daySepPill
                    visible: hasDaySep
                    anchors.top: parent.top
                    anchors.topMargin: 7
                    anchors.horizontalCenter: parent.horizontalCenter
                    height: 24
                    width: daySepText.implicitWidth + 24
                    radius: height / 2
                    color: Theme.bgSecondary
                    opacity: 0.92
                    border.width: 1
                    border.color: Theme.border
                    Text {
                        id: daySepText
                        anchors.centerIn: parent
                        text: daySepLabel
                        color: Theme.textSecondary
                        font.pixelSize: Theme.fontSm
                        font.bold: true
                    }
                }

                Rectangle {
                    id: bubble
                    anchors.right: isMe ? parent.right : undefined
                    anchors.left:  isMe ? undefined     : parent.left
                    anchors.rightMargin: isMe ? 12 : 0
                    anchors.leftMargin:  isMe ? 0  : 12
                    anchors.verticalCenter: parent.verticalCenter
                    // Доп. высота разделителя добавлена СВЕРХУ → сдвигаем центр пузыря вниз
                    // на половину, сохраняя прежние 4px-поля сверху/снизу самого пузыря.
                    anchors.verticalCenterOffset: daySepH / 2

                    width: Math.min(Math.max(showMessageText ? msgText.implicitWidth : 0,
                                             hasReply ? messageReplyPreview.implicitWidth : 0,
                                             isVisualMedia ? imagePreview.implicitWidth : 0,
                                             isPhotoGroup ? photoMosaic.implicitWidth : 0,
                                             showFileCard ? fileCard.implicitWidth : 0,
                                             isVoice ? voiceCard.implicitWidth : 0,
                                             hasReactions ? reactionsFlow.implicitWidth : 0,
                                             metaRow.implicitWidth,
                                             isMe ? 0 : senderLabel.implicitWidth) + 24,
                                      listView.width * 0.72)
                    implicitHeight: (isMe ? 0 : senderLabel.implicitHeight + 2)
                                  + (hasReply ? messageReplyPreview.implicitHeight + 6 : 0)
                                  + (showMessageText ? (_clampText ? _maxInlineH : msgText.implicitHeight) : 0)
                                  + (isVisualMedia ? imagePreview.implicitHeight + 6 : 0)
                                  + (isPhotoGroup ? photoMosaic.implicitHeight + 6 : 0)
                                  + (showFileCard ? fileCard.implicitHeight + 6 : 0)
                                  + (isVoice ? voiceCard.implicitHeight + 6 : 0)
                                  + (hasReactions ? reactionsFlow.implicitHeight + 6 : 0)
                                  + metaRow.implicitHeight + 16
                    // Скруглённый пузырь-«облачко»: углы крупные, но нижний угол со
                    // СТОРОНЫ отправителя почти острый — «хвостик» (как у speech bubble).
                    // Per-corner radius — Qt 6.7+. (Анимация втекания — scale делегата в
                    // add-transition; _rv-морф пузыря убран как ненадёжный при пине.)
                    radius: 18
                    bottomRightRadius: isMe ? 2 : 18
                    bottomLeftRadius:  isMe ? 18 : 2
                    color: isMe ? Theme.bgButton : Theme.bgSecondary
                    border.width: isSearchMatch ? (isSearchCurrent ? 3 : 2) : (isFlash ? 3 : 1)
                    border.color: isSearchMatch
                                  ? (isSearchCurrent ? Theme.accent : Theme.accentHover)
                                  : (isFlash ? Theme.accent : (isMe ? Theme.accentDim : Theme.border))
                    Behavior on border.color { ColorAnimation { duration: 200 } }

                    // ВХОДЯЩИЕ: «принтер» — шторка цвета пузыря закрывает текст и уезжает
                    // ВНИЗ (height: full→0) → текст проявляется сверху-вниз, как печать.
                    // Верх шторки прямой (radius 0) — ровная строка печати.
                    Rectangle {
                        id: printerShade
                        // Текстовые входящие расшифровываются scramble-оверлеем (ниже);
                        // шторка остаётся для НЕтекстовых (вложения/фото).
                        visible: !isMe && _animating && !showMessageText
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: parent.height * (1.0 - _rv)
                        color: parent.color
                        radius: 0
                        bottomLeftRadius: parent.bottomLeftRadius
                        bottomRightRadius: parent.bottomRightRadius
                        z: 40
                    }

                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        hoverEnabled: false
                        onClicked: function(mouse) {
                            // Ссылка под кликом? Открыть её (или скопировать inline-код),
                            // не входя в меню/выделение. MouseArea перекрывает MessageText,
                            // поэтому ссылку проверяем здесь — иначе она «не открывалась» (#28).
                            if (showMessageText && msgText.visible) {
                                const lp = mapToItem(msgText, mouse.x, mouse.y)
                                const link = msgText.linkAt(lp.x, lp.y)
                                if (link && link.length > 0) {
                                    if (link.indexOf("copy:") === 0)
                                        root.copyMessageText(decodeURIComponent(link.substring(5)))
                                    else
                                        Qt.openUrlExternally(link)
                                    return
                                }
                            }
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
                        text: isMe ? "" : root.displayName
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
                        // Очень длинный текст обрезаем по высоте (clip) → читать целиком в
                        // полноэкранном ридере (кнопка-уголки). Стабилизирует высоты делегатов.
                        height: _clampText ? _maxInlineH : implicitHeight
                        clip: _clampText
                        // На время «дешифровки» (входящий текст) прячем настоящий текст —
                        // поверх рисуется scramble-оверлей. Раскладку держим (opacity, не visible).
                        opacity: (!isMe && _animating) ? 0 : 1
                        onLinkActivated: function(url) { Qt.openUrlExternally(url) }
                        onCopyRequested: function(t) { root.copyMessageText(t) }
                    }

                    // ВХОДЯЩИЕ (текст): «дешифровка» — каракули осыпаются в настоящий текст
                    // сверху-вниз (см. root.decryptStr / root._scrambleTick). Плоский Text,
                    // тот же шрифт/ширина/перенос, что у msgText → форма строк совпадает.
                    Text {
                        visible: !isMe && _animating && showMessageText
                        anchors.left: msgText.left
                        anchors.right: msgText.right
                        anchors.top: msgText.top
                        height: msgText.height
                        // Всегда клипуем: скрамбл-глифы могут переноситься на БОЛЬШЕ строк,
                        // чем реальный текст → без клипа оверлей вылезал за пузырь на соседние
                        // сообщения (наложение). Клип держит его в границах реального текста.
                        clip: true
                        text: root.decryptStr(model.text || "", _rv, root._scrambleTick)
                        color: Theme.textPrimary
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontMd
                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                        textFormat: Text.PlainText
                    }

                    // Затухание у низа обрезанного текста — намёк «есть продолжение»
                    // (полный текст по кнопке-уголкам). Только когда текст реально обрезан.
                    Rectangle {
                        visible: _clampText
                        anchors.left: msgText.left
                        anchors.right: msgText.right
                        anchors.top: msgText.bottom
                        anchors.topMargin: -28
                        height: 28
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: "transparent" }
                            GradientStop { position: 1.0; color: isMe ? Theme.bgButton : Theme.bgSecondary }
                        }
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
                        captionColor: isMe ? Theme.messageTextOutgoing : Theme.textPrimary
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
                        height: isVisualMedia ? Math.min(340, Math.max(170, width * 0.66)) : 0
                        visible: isVisualMedia
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
                            // Спиннер «Загрузка превью» — только для фото. У видео
                            // отсутствие постера штатно (крупный файл) → показываем
                            // плашку ▶ ниже, а не вечный спиннер.
                            visible: previewSource.length === 0 && isImage
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

                        // Плашка воспроизведения поверх постера видео.
                        Rectangle {
                            anchors.centerIn: parent
                            width: 58; height: 58
                            radius: 29
                            visible: isVideo
                            color: "#B30B0F14"
                            border.width: 1
                            border.color: "#66FFFFFF"
                            z: 2
                            AppIcon {
                                anchors.centerIn: parent
                                anchors.horizontalCenterOffset: 2 // оптическая центровка треугольника
                                width: 26; height: 26
                                name: "play"
                                iconColor: "#F7FAFF"
                                fillColor: "#F7FAFF"
                                strokeWidth: 2
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: isVideo ? root.openVideo(model.id, attachmentName)
                                               : root.openPhoto(previewSource, model.id, attachmentName)
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

                    // ── Голосовое сообщение: play/pause + длительность ──
                    Rectangle {
                        id: voiceCard
                        anchors.top: showMessageText ? msgText.bottom : (hasReply ? messageReplyPreview.bottom : (isMe ? parent.top : senderLabel.bottom))
                        anchors.topMargin: 6
                        anchors.left: parent.left
                        anchors.leftMargin: 12
                        height: isVoice ? 52 : 0
                        visible: isVoice
                        radius: Theme.radiusMd
                        color: Theme.bgInput
                        border.width: 1
                        border.color: Theme.border
                        implicitWidth: 248
                        implicitHeight: height

                        readonly property bool isCurrent: root.voicePlayer && root.voicePlayer.tick >= 0
                                                          && root.voicePlayer.currentId === model.id
                        readonly property bool isPlaying: isCurrent && root.voicePlayer.playing
                        readonly property real playPos: isCurrent ? root.voicePlayer.position : 0
                        readonly property real playDur: isCurrent ? root.voicePlayer.duration : 0

                        Rectangle {
                            id: voicePlayBtn
                            width: 38; height: 38; radius: 19
                            anchors.left: parent.left; anchors.leftMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            color: voicePlayArea.containsMouse ? Theme.accentHover : Theme.accent
                            AppIcon {
                                anchors.centerIn: parent
                                anchors.horizontalCenterOffset: voiceCard.isPlaying ? 0 : 2
                                width: 18; height: 18
                                name: voiceCard.isPlaying ? "pause" : "play"
                                iconColor: "#FFFFFF"; fillColor: "#FFFFFF"; strokeWidth: 2
                            }
                            MouseArea {
                                id: voicePlayArea
                                anchors.fill: parent; hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.toggleVoice(model.id)
                            }
                        }

                        // Скачать аудио (голосовое = аудиофайл) — как у обычных вложений.
                        Rectangle {
                            id: voiceDownloadBtn
                            width: 30; height: 30; radius: 15
                            anchors.right: parent.right; anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            color: voiceDownloadArea.containsMouse ? Theme.bgCard : "transparent"
                            AppIcon {
                                anchors.centerIn: parent
                                width: 18; height: 18; name: "download"
                                iconColor: Theme.textSecondary; strokeWidth: 1.8
                            }
                            MouseArea {
                                id: voiceDownloadArea
                                anchors.fill: parent; hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.openSaveDialog(model.id, attachmentName)
                            }
                        }

                        Column {
                            anchors.left: voicePlayBtn.right; anchors.leftMargin: 10
                            anchors.right: voiceDownloadBtn.left; anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 5
                            // Тонкая дорожка прогресса.
                            Rectangle {
                                width: parent.width; height: 3; radius: 1.5
                                color: Theme.border
                                Rectangle {
                                    width: parent.width * (voiceCard.playDur > 0 ? Math.min(1, voiceCard.playPos / voiceCard.playDur) : 0)
                                    height: parent.height; radius: parent.radius
                                    color: Theme.accent
                                }
                            }
                            Text {
                                text: voiceCard.isCurrent && voiceCard.playDur > 0
                                      ? root.formatDuration(voiceCard.playPos) + " / " + root.formatDuration(voiceCard.playDur)
                                      : qsTr("Голосовое сообщение")
                                color: Theme.textSecondary
                                font.pixelSize: Theme.fontXs
                                font.family: Theme.fontFamily
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
                        anchors.top: isPhotoGroup ? photoMosaic.bottom : (isVisualMedia ? imagePreview.bottom : (isVoice ? voiceCard.bottom : (showFileCard ? fileCard.bottom : msgText.bottom)))
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
                                // Реактор в 1:1 диалоге — это либо я (mine), либо собеседник.
                                // Имя/аватар берём из профиля (свой) / диалога (собеседник),
                                // т.е. по НИКУ, а не по сырому sender_name (ФИО).
                                readonly property string reactorName: {
                                    const base = modelData.mine ? root.selfName : root.displayName
                                    if (base && base.length > 0) return base
                                    return modelData.sender_name || modelData.sender || ""
                                }
                                readonly property string reactorAvatar: modelData.mine ? root.selfAvatar : root.avatar
                                readonly property string senderInitial:
                                    reactorName.length > 0 ? reactorName.charAt(0).toUpperCase() : ""
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
                                    // Аватар реактора (круг уже запечён в PNG) — если задан.
                                    Image {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 18; height: 18
                                        visible: reactorAvatar.length > 0
                                        source: reactorAvatar
                                        asynchronous: true
                                        cache: true
                                    }
                                    // Иначе — буква-инициал (по нику).
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: reactorAvatar.length === 0 && senderInitial.length > 0
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
                        anchors.top: hasReactions ? reactionsFlow.bottom : (isPhotoGroup ? photoMosaic.bottom : (isVisualMedia ? imagePreview.bottom : (isVoice ? voiceCard.bottom : (showFileCard ? fileCard.bottom : msgText.bottom))))
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
                        // Упавшая отправка: КРУПНАЯ кликабельная иконка-ретрай (надёжный
                        // SVG-AppIcon, не Canvas — Canvas-✕ не рисовался на Android). Тап
                        // перехватывает событие ДО MouseArea пузыря (иначе всплывало
                        // контекст-меню), большая зона захвата (−12) — попасть пальцем.
                        Item {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 22; height: 22
                            visible: isMe && model.status === "failed"
                            AppIcon {
                                anchors.centerIn: parent
                                width: 17; height: 17
                                name: "refresh"
                                iconColor: Theme.error
                                strokeWidth: 2.2
                            }
                            MouseArea {
                                anchors.fill: parent
                                anchors.margins: -12
                                cursorShape: Qt.PointingHandCursor
                                onClicked: function(mouse) {
                                    mouse.accepted = true
                                    if ((model.client_token || "").length > 0) Chat.retrySend(model.client_token)
                                }
                            }
                        }
                        DeliveryStatusIcon {
                            id: deliveryIcon
                            anchors.verticalCenter: parent.verticalCenter
                            visible: isMe && model.status !== "failed"
                            status: model.status
                            iconColor: root.deliveryStatusColor(model.status)
                        }
                    }

                    // Кнопка-уголки «читать на весь экран» — в углу пузыря напротив
                    // имени автора (верх-право). Только для длинных сообщений и вне
                    // режима выделения.
                    Rectangle {
                        id: expandBtn
                        visible: isLongText && !root.selectionMode
                        anchors.top: parent.top
                        anchors.right: parent.right
                        anchors.topMargin: 6
                        anchors.rightMargin: 6
                        width: 26
                        height: 26
                        radius: 13   // скруглённая (в тон облачку), не «квадрат»
                        z: 5
                        opacity: expandArea.containsMouse ? 1.0 : 0.85
                        color: expandArea.containsMouse ? Theme.bgCard
                                                        : (isMe ? Theme.bgButton : Theme.bgSecondary)
                        border.width: 1
                        border.color: Theme.border

                        AppIcon {
                            anchors.centerIn: parent
                            width: 15
                            height: 15
                            name: "expand"
                            iconColor: isMe ? Theme.messageTextOutgoing : Theme.textSecondary
                            strokeWidth: 1.8
                        }

                        MouseArea {
                            id: expandArea
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: root.openTextViewer(model.text,
                                                           isMe ? "" : root.displayName,
                                                           isMe,
                                                           root.formatTime(model.ts))
                        }
                    }
                }
            }
            }

            // Индикатор загрузки — ВРАЩАЮЩИЙСЯ ЛОГО Paranoia вместо базового кружка.
            // Крутим через RotationAnimator: он работает на RENDER-потоке и продолжает
            // анимироваться, ДАЖЕ когда GUI-поток заблокирован (синхронный FFI на
            // загрузке) — обычная RotationAnimation/BusyIndicator в этот момент замерли бы.
            Item {
                id: messagesBusy
                anchors.centerIn: parent
                width: 52; height: 52
                // Только начальная загрузка (пустая лента). Иначе крутилка лезла
                // поверх уже показанных сообщений при каждом fetchMessages —
                // в т.ч. при отправке вложений (fetchMessages → messagesLoading).
                readonly property bool running: (Chat.messagesLoading || !root.messagesLoaded) && msgModel.count === 0
                visible: running
                z: 2

                Image {
                    anchors.fill: parent
                    source: "qrc:/logo_symbol.svg"
                    sourceSize.width: 104
                    sourceSize.height: 104
                    smooth: true
                    fillMode: Image.PreserveAspectFit
                    RotationAnimator on rotation {
                        running: messagesBusy.running
                        from: 0; to: 360
                        duration: 1100
                        loops: Animation.Infinite
                    }
                }
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
                    onClicked: { listView.stickToBottom = true; root.settleToBottom() }
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

            // Пока идёт транскод видео (videoPreparing) — НЕ прячем панель, даже
            // если между апдейтами процента прошло >interval (у больших видео
            // апдейты редкие, иначе плашка «Подготовка видео» мигала бы).
            Timer { id: errorTimer; interval: 3000; onTriggered: if (!root.videoPreparing) errorBar.visible = false }

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
            // Высоту бара считаем по КАПНУТОЙ высоте текста (как у msgInputScroll, 124),
            // а не по сырой implicitHeight — иначе при >~6 строк текст-вьюха стоит на
            // 124, а бар рос до 200, давая растущие отступы вокруг текста (#38).
            Layout.preferredHeight: Math.max(Math.min(msgInput.implicitHeight, 124) + 16 + (root.hasPendingReply ? 58 : 0)
                                             + (root.hasPendingAttachments ? 58 : 0),
                                             root.hasPendingReply ? 106 : 48)
            color: Theme.bgDark

            Rectangle {
                anchors.top: parent.top
                width: parent.width; height: 1
                color: Theme.separator
            }

            // ── Оверлей записи голосового (поверх инпута, пока идёт запись) ──
            Rectangle {
                anchors.fill: parent
                anchors.topMargin: 1
                color: Theme.bgDark
                visible: Chat.voiceRecording
                z: 20

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 14
                    anchors.rightMargin: 8
                    spacing: 12

                    // Пульсирующая красная точка.
                    Rectangle {
                        Layout.preferredWidth: 12; Layout.preferredHeight: 12; radius: 6
                        color: Theme.error
                        SequentialAnimation on opacity {
                            running: Chat.voiceRecording; loops: Animation.Infinite
                            NumberAnimation { from: 1.0; to: 0.25; duration: 650 }
                            NumberAnimation { from: 0.25; to: 1.0; duration: 650 }
                        }
                    }
                    Text {
                        Layout.fillWidth: true
                        text: qsTr("Запись… %1").arg(root.formatDuration(root.recordingMs))
                        color: Theme.textPrimary
                        font.pixelSize: Theme.fontMd
                        font.family: Theme.fontFamily
                    }
                    // Отмена (корзина).
                    Rectangle {
                        Layout.preferredWidth: 40; Layout.preferredHeight: 40; radius: 20
                        color: cancelVoiceArea.containsMouse ? Theme.bgInput : "transparent"
                        AppIcon {
                            anchors.centerIn: parent
                            width: 22; height: 22; name: "trash"
                            iconColor: Theme.textSecondary; strokeWidth: 1.8
                        }
                        MouseArea {
                            id: cancelVoiceArea
                            anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: Chat.cancelVoiceRecording()
                        }
                    }
                    // Отправить.
                    Rectangle {
                        Layout.preferredWidth: 44; Layout.preferredHeight: 44; radius: 22
                        color: sendVoiceArea.containsMouse ? Theme.accentHover : Theme.accent
                        AppIcon {
                            anchors.centerIn: parent
                            anchors.horizontalCenterOffset: -1
                            width: 22; height: 22; name: "send"
                            iconColor: "#FFFFFF"; fillColor: "#FFFFFF"; strokeWidth: 1.8
                        }
                        MouseArea {
                            id: sendVoiceArea
                            anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: Chat.sendVoiceRecording()
                        }
                    }
                }
            }

            ColumnLayout {
                id: inputContent
                anchors.fill: parent
                anchors.leftMargin: 6
                anchors.rightMargin: 2
                anchors.topMargin: 4
                anchors.bottomMargin: 4
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

                // Полоса прикреплённых, но ещё не отправленных вложений (стейджинг).
                // Чип: иконка по типу + имя + крестик удаления. Скролл по горизонтали.
                ListView {
                    id: stagedStrip
                    Layout.fillWidth: true
                    Layout.preferredHeight: root.hasPendingAttachments ? 52 : 0
                    visible: root.hasPendingAttachments
                    orientation: ListView.Horizontal
                    spacing: 6
                    clip: true
                    model: root.pendingAttachments

                    delegate: Rectangle {
                        height: 44
                        width: chipRow.implicitWidth + 16
                        radius: 10
                        color: Theme.bgInput
                        border.color: Theme.border
                        border.width: 1

                        Row {
                            id: chipRow
                            anchors.centerIn: parent
                            spacing: 6

                            AppIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 20; height: 20
                                name: modelData.kind === "video" ? "video"
                                      : (modelData.kind === "image" ? "image" : "file")
                                iconColor: Theme.accentHover
                                strokeWidth: 1.8
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.name.length > 20
                                      ? modelData.name.substring(0, 18) + "…"
                                      : modelData.name
                                color: Theme.textPrimary
                                font.pixelSize: Theme.fontSm
                                font.family: Theme.fontFamily
                            }
                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 20; height: 20; radius: 10
                                color: rmArea.containsMouse ? Theme.bgCard : "transparent"
                                AppIcon {
                                    anchors.centerIn: parent
                                    width: 13; height: 13; name: "close"
                                    iconColor: Theme.textSecondary; strokeWidth: 1.8
                                }
                                MouseArea {
                                    id: rmArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.removeAttachmentAt(index)
                                }
                            }
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 6

                    // Всё внутри ОДНОГО поля (#45): «+», поле ввода, смайлик и отправка —
                    // кнопки оверлеями ВНУТРИ пилюли (как смайлик в #41), а не отдельными
                    // колонками. Так диалогу/тексту больше места.
                    Item {
                        id: inputFieldWrap
                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.min(Math.max(msgInput.implicitHeight, 40), 124)
                        Layout.alignment: Qt.AlignVCenter

                    ScrollView {
                        id: msgInputScroll
                        anchors.fill: parent
                        clip: true
                        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                        ScrollBar.vertical: AppScrollBar { policy: ScrollBar.AsNeeded }

                        background: Rectangle {
                            radius: 20          // почти круглая пилюля — в тон круглой кнопке отправки
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
                            // Слева внутри — «+», справа — смайлик и отправка (#45):
                            // оставляем под них поле, чтобы текст не залезал под кнопки.
                            // Зазоры урезаны под край кнопок: «+» теперь 26px (край x≈30),
                            // смайлик слева ≈ w−62 — текст почти впритык, минимум потерь.
                            leftPadding: 28
                            rightPadding: 60

                            background: null
                            onTextChanged: {
                                if (text.length > 0) root.sendLocked = false
                                draftSaveTimer.restart()   // дебаунс: запись через 600мс после паузы
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
                                // Зафиксировать текущее КОМПОЗ-слово (pre-edit от
                                // предиктивного ввода) ДО перемещения курсора тапом —
                                // иначе IME перетаскивает незакоммиченное слово в новую
                                // позицию вместе с курсором (#46).
                                Qt.inputMethod.commit()
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
                               if (activeFocus) {
                                   // Тап по полю = пользователь хочет печатать →
                                   // прячем эмодзи-панель и показываем клавиатуру (#42).
                                   root.emojiPanelOpen = false
                                   Qt.inputMethod.show()
                               }
                            }

                            Keys.onPressed: function(event) {
                                if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                                        && (event.modifiers & Qt.ControlModifier)) {
                                    sendBtn.clicked()
                                    event.accepted = true
                                    return
                                }
                                // Desktop: Ctrl+V с картинкой в буфере (скриншот и т.п.).
                                // TextArea сам изображение не вставляет — перехватываем,
                                // сохраняем во временный PNG и шлём вложением. Текст
                                // вставляется штатно (сюда не попадает — нет картинки).
                                if (!root.isMobileOs
                                        && (event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_V
                                        && typeof ClipboardUtils !== "undefined" && ClipboardUtils.hasImage()) {
                                    var p = ClipboardUtils.saveImageToTemp()
                                    if (p && p.length > 0) {
                                        Chat.sendFile(p)
                                        event.accepted = true
                                    }
                                }
                            }
                        }
                    }   // ScrollView

                        // ── Кнопки ВНУТРИ поля (#45), все по нижнему краю пилюли ──────
                        // «+» (вложения) — низ-лево.
                        Rectangle {
                            id: attachBtn
                            anchors.left: parent.left
                            anchors.bottom: parent.bottom
                            anchors.leftMargin: 4
                            anchors.bottomMargin: 7
                            width: 26; height: 26
                            radius: width / 2
                            color: attachArea.containsMouse ? Theme.bgCard : "transparent"
                            AppIcon {
                                anchors.centerIn: parent
                                width: 20; height: 20
                                name: "plus"
                                iconColor: Theme.accentHover
                                strokeWidth: 2.2
                            }
                            MouseArea {
                                id: attachArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    const p = mapToItem(root, 0, 0)
                                    attachMenu.x = Math.max(8, p.x)
                                    attachMenu.y = Math.max(8, p.y - attachMenu.height - 6)
                                    attachMenu.open()
                                }
                            }
                        }

                        // Отправка — низ-право.
                        Rectangle {
                            id: sendBtnVisual
                            readonly property bool hasContent: msgInput.text.trim().length > 0
                                                               || (msgInput.preeditText && msgInput.preeditText.trim().length > 0)
                                                               || root.hasPendingAttachments
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            anchors.rightMargin: 4
                            anchors.bottomMargin: 6
                            width: 28; height: 28
                            radius: width / 2
                            color: root.sendLocked || !hasContent ? Theme.accentDim : (sendArea.containsMouse ? Theme.accentHover : Theme.accent)
                            AppIcon {
                                anchors.fill: parent
                                anchors.margins: 5
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

                        // Смайлик/клавиатура-toggle — низ-право, левее отправки (#41/#42).
                        Rectangle {
                            anchors.right: sendBtnVisual.left
                            anchors.bottom: parent.bottom
                            anchors.rightMargin: 2
                            anchors.bottomMargin: 7
                            width: 26; height: 26
                            radius: width / 2
                            color: emojiArea.containsMouse ? Theme.bgCard : "transparent"
                            AppIcon {
                                anchors.centerIn: parent
                                width: 24; height: 24
                                name: root.emojiPanelOpen
                                      ? (root.isMobileOs ? "keyboard" : "chevronDown")
                                      : "smile"
                                iconColor: Theme.accentHover
                                strokeWidth: 1.8
                            }
                            MouseArea {
                                id: emojiArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.toggleEmojiPanel()
                            }
                        }
                    }   // inputFieldWrap

                    // (Кнопка отправки перенесена ВНУТРЬ поля — sendBtnVisual выше, #45.)

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

                            const atts = root.pendingAttachments
                            // Нечего отправлять — ни текста, ни вложений.
                            if (atts.length === 0 && txt.length === 0) return

                            root.sendLocked = true

                            if (atts.length > 0) {
                                Chat.requestFileAccessPermissions()
                                // Фото — одной группой с подписью; остальное (видео/файлы)
                                // по одному. Подпись прикрепляется к фото-группе; если фото
                                // нет, а текст есть — уходит отдельным сообщением.
                                var images = []
                                var others = []
                                for (var i = 0; i < atts.length; ++i) {
                                    if (atts[i].kind === "image") images.push(atts[i].path)
                                    else others.push(atts[i].path)
                                }
                                var captionConsumed = false
                                if (images.length === 1 && txt.length === 0) {
                                    Chat.sendFile(images[0])
                                } else if (images.length > 0) {
                                    Chat.sendPhotoGroup(images, txt)
                                    captionConsumed = txt.length > 0
                                }
                                for (var j = 0; j < others.length; ++j)
                                    Chat.sendFile(others[j])
                                if (txt.length > 0 && !captionConsumed) {
                                    if (root.hasPendingReply)
                                        Chat.sendTextReply(txt, root.pendingReplyId, root.pendingReplySender, root.pendingReplyText)
                                    else
                                        Chat.sendText(txt)
                                }
                                root.clearAttachments()
                            } else if (root.hasPendingReply) {
                                Chat.sendTextReply(txt, root.pendingReplyId, root.pendingReplySender, root.pendingReplyText)
                            } else {
                                Chat.sendText(txt)
                            }

                            msgInput.text = ""
                            root.clearDraft()
                            root.clearPendingReply()
                            sendUnlockTimer.restart()
                            // Автопрокрутка вниз при отправке: гарантированно
                            // показываем только что отправленное сообщение.
                            listView.stickToBottom = true
                            Qt.callLater(root.settleToBottom)
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

        // INLINE эмодзи-панель (#42) — занимает место клавиатуры.
        // Открывается кнопкой 🙂 в поле ввода (toggle с клавиатурой); высота 0 когда
        // закрыта, поэтому лента сообщений занимает всё место.
        EmojiPanel {
            id: emojiPanel
            Layout.fillWidth: true
            Layout.preferredHeight: root.emojiPanelOpen ? 300 : 0
            visible: root.emojiPanelOpen
            onPicked: function(emoji) {
                msgInput.insert(msgInput.cursorPosition, emoji)
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

    // Экран «Вложения диалога» (медиа/файлы/ссылки) — пушится в общий stackView.
    Component {
        id: sharedMediaComponent
        SharedMediaPage {
            // «Перейти к вложению в диалоге»: закрываем галерею и скроллим ленту
            // к сообщению (с расширением окна и подсветкой).
            onJumpToMessageRequested: function(messageId) {
                stackView.pop()
                Qt.callLater(function() { root.jumpToMessageById(messageId) })
            }
        }
    }

    // Полноэкранное чтение длинного текста (открывается из пузыря, см. openTextViewer).
    TextMessageViewer {
        id: textViewer
        anchors.fill: parent
        onCopyRequested: function(t) { root.copyMessageText(t) }
    }

    // (Анимация отправки исходящего убрана по просьбе Иванова — сообщение просто
    //  появляется. Внутри-ленточные анимации гасил пин/forceLayout, overlay-вариант
    //  не зашёл. Входящая «дешифровка» текста остаётся.)

    // (Эмодзи для поля ввода — теперь inline EmojiPanel внизу, см. #42; старый
    //  popup-пикер удалён. Для настройки реакций — отдельный EmojiPicker ниже.)

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

    // Desktop drag-and-drop: перетаскивание файлов из проводника → отправка
    // вложениями. DropArea ловит только drag-события и не мешает обычному вводу.
    // На мобильных не нужен.
    DropArea {
        id: fileDropArea
        anchors.fill: parent
        enabled: !root.isMobileOs
        keys: ["text/uri-list"]

        onDropped: function (drop) {
            if (!drop.hasUrls) {
                drop.accepted = false
                return
            }
            var sent = 0
            for (var i = 0; i < drop.urls.length; ++i) {
                var u = String(drop.urls[i] || "")
                if (u.length === 0) continue
                Chat.sendFile(u)          // sendFile понимает file://-URL (normalizeLocalFilePath)
                sent++
            }
            drop.accepted = sent > 0
        }

        Rectangle {
            anchors.fill: parent
            z: 1000
            visible: fileDropArea.containsDrag
            color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.12)
            border.color: Theme.accent
            border.width: 2
            radius: 8
            Text {
                anchors.centerIn: parent
                text: qsTr("Отпустите файлы, чтобы отправить")
                color: Theme.accent
                font.pixelSize: Theme.fontMd
                font.family: Theme.fontFamily
            }
        }
    }
}
