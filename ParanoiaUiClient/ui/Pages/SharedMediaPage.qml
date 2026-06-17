import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import ParanoiaUiClient

// Экран «Вложения диалога»: общая галерея медиа/файлов/ссылок, накопленных в
// переписке. Открывается из шапки диалога (кнопка-картинка). Данные передаются
// из ChatPage (см. openSharedMedia) уже готовыми массивами — страница не лезет
// в бэкенд сама, кроме сохранения вложения (Chat.saveAttachmentToDefault).
Rectangle {
    id: root
    objectName: "SharedMediaPage"
    color: Theme.bgPrimary

    // Передаются при stackView.push.
    property string peerName: ""
    property string peerId: ""    // для дозагрузки превью (ensureGalleryPreview)
    property var mediaItems: []   // [{id,local,ready,filename,ts,size}]
    property var fileItems: []    // [{id,name,size,mime,ts}]
    property var linkItems: []    // [{url,ts,id,snippet}]

    // Превью, уже расшифрованные в провайдер (id → true). Заполняется по сигналу
    // galleryPreviewReady; переприсваивание объекта → обновление source плиток.
    property var readyIds: ({})
    function markPreviewReady(id) {
        if (!id || id.length === 0) return
        var m = Object.assign({}, readyIds)
        m[id] = true
        readyIds = m
    }
    // Отображаемый источник плитки: своё фото (file://) — сразу; иначе провайдер,
    // когда превью готово (ready при сборке ИЛИ дотянуто). Пусто → плейсхолдер.
    function mediaSource(item) {
        if (item.local && item.local.length > 0) return item.local
        if (item.ready === true || readyIds[item.id] === true)
            return "image://secure/" + item.id
        return ""
    }
    // Список для полноэкранного просмотрщика (только с доступным источником).
    function galleryForViewer() {
        var out = []
        for (var i = 0; i < mediaItems.length; ++i) {
            var s = mediaSource(mediaItems[i])
            if (s.length === 0) continue
            out.push({ source: s, id: mediaItems[i].id, filename: mediaItems[i].filename })
        }
        return out
    }

    property int currentTab: 0    // 0=медиа, 1=файлы, 2=ссылки
    property bool loadingMore: false   // дотягивается полная история диалога

    // Режим выделения для удаления вложений (медиа/файлы). На вкладке ссылок недоступен.
    property bool selectMode: false
    property var selectedIds: ({})
    property int selectedCount: 0

    // Суммарный объём вложений (медиа + файлы) в человекочитаемом виде для шапки.
    readonly property string totalSizeText: {
        var total = 0
        for (var i = 0; i < mediaItems.length; ++i) total += Number(mediaItems[i].size) || 0
        for (var k = 0; k < fileItems.length; ++k) total += Number(fileItems[k].size) || 0
        return total > 0 ? fileSize(total) : ""
    }

    // Системная/Esc-кнопка «назад»: фотовьюер → режим выделения → выход с экрана.
    function handleBackButton(): bool {
        if (photoViewer.visible) { photoViewer.close(); return true }
        if (selectMode) { exitSelect(); return true }
        return false
    }

    function toggleSel(id) {
        if (!id || id.length === 0) return
        // ВАЖНО: новый объект (Object.assign) — иначе QML сравнивает var по ссылке и
        // не уведомляет биндинги делегатов (галочка не перерисовывалась).
        var m = Object.assign({}, selectedIds)
        if (m[id]) { delete m[id]; selectedCount -= 1 }
        else { m[id] = true; selectedCount += 1 }
        selectedIds = m
    }

    function exitSelect() {
        selectMode = false
        selectedIds = ({})
        selectedCount = 0
    }

    function deleteSelected() {
        var ids = Object.keys(selectedIds)
        if (ids.length === 0) { exitSelect(); return }
        Chat.deleteMessages(ids)
        // Локально убираем удалённое из всех списков (id вложения = id сообщения).
        function keep(arr) {
            var out = []
            for (var i = 0; i < arr.length; ++i)
                if (!selectedIds[arr[i].id]) out.push(arr[i])
            return out
        }
        mediaItems = keep(mediaItems)
        fileItems = keep(fileItems)
        linkItems = keep(linkItems)
        exitSelect()
        toast.show(qsTr("Удалено: %1").arg(ids.length))
    }

    // Короткая дата для строк файлов/ссылок: сегодня → время, иначе — дата.
    function shortDate(ts) {
        var d = new Date(ts)
        var now = new Date()
        if (d.getFullYear() === now.getFullYear()
            && d.getMonth() === now.getMonth()
            && d.getDate() === now.getDate())
            return Qt.locale().toString(d, "HH:mm")
        if (d.getFullYear() === now.getFullYear())
            return Qt.locale().toString(d, "d MMM")
        return Qt.locale().toString(d, "d MMM yyyy")
    }

    function fileSize(size) {
        var bytes = Number(size)
        if (!isFinite(bytes) || bytes < 0) return ""
        var units = [qsTr("Б"), qsTr("КБ"), qsTr("МБ"), qsTr("ГБ")]
        var u = 0
        while (bytes >= 1024 && u < units.length - 1) { bytes /= 1024; ++u }
        return (u === 0 ? Math.round(bytes).toString()
                        : bytes.toFixed(bytes >= 10 ? 1 : 2)) + " " + units[u]
    }

    function saveFile(id, name) {
        Chat.requestFileAccessPermissions()
        Chat.saveAttachmentToDefault(id)
        toast.show(qsTr("Сохраняю «%1»…").arg(name && name.length > 0 ? name : "файл"))
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ── Шапка ───────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            height: 56
            color: Theme.bgDark

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width; height: 2
                color: Theme.accentDim
            }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 16
                spacing: 8

                Rectangle {
                    width: 40; height: 40
                    radius: Theme.radiusSm
                    color: backArea.containsMouse ? Theme.bgCard : "transparent"
                    border.width: backArea.containsMouse ? 1 : 0
                    border.color: Theme.border
                    AppIcon {
                        anchors.centerIn: parent
                        width: 24; height: 24
                        name: root.selectMode ? "close" : "chevronLeft"
                        iconColor: Theme.accentHover
                        strokeWidth: 2.2
                    }
                    MouseArea {
                        id: backArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.selectMode ? root.exitSelect() : stackView.pop()
                    }
                }

                Column {
                    Layout.fillWidth: true
                    spacing: 2
                    Text {
                        text: root.selectMode ? qsTr("Выбрано: %1").arg(root.selectedCount)
                                              : qsTr("Вложения")
                        color: Theme.textPrimary
                        font.pixelSize: Theme.fontMd
                        font.family: Theme.fontFamily
                        font.weight: Font.Medium
                    }
                    Text {
                        // Имя собеседника + суммарный объём вложений (человекочитаемо).
                        text: {
                            var parts = []
                            if (root.peerName.length > 0) parts.push(root.peerName)
                            if (root.totalSizeText.length > 0) parts.push(root.totalSizeText)
                            return parts.join("  ·  ")
                        }
                        visible: text.length > 0 && !root.selectMode
                        color: Theme.textSecondary
                        font.pixelSize: Theme.fontXs
                        font.family: Theme.fontFamily
                        elide: Text.ElideRight
                        width: parent.width
                    }
                }

                // Войти в режим выделения — когда не в нём.
                Rectangle {
                    Layout.preferredWidth: 40
                    Layout.preferredHeight: 40
                    Layout.alignment: Qt.AlignVCenter
                    visible: !root.selectMode
                    radius: Theme.radiusSm
                    color: selBtnArea.containsMouse ? Theme.bgCard : "transparent"
                    AppIcon {
                        anchors.centerIn: parent
                        width: 22; height: 22
                        name: "trash"
                        iconColor: Theme.accentHover
                        strokeWidth: 2
                    }
                    MouseArea {
                        id: selBtnArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.selectMode = true
                    }
                }

                // Удалить выбранные (в режиме выделения).
                Rectangle {
                    Layout.preferredWidth: 40
                    Layout.preferredHeight: 40
                    Layout.alignment: Qt.AlignVCenter
                    visible: root.selectMode
                    radius: Theme.radiusSm
                    color: delBtnArea.containsMouse ? Theme.bgCard : "transparent"
                    opacity: root.selectedCount > 0 ? 1 : 0.4
                    AppIcon {
                        anchors.centerIn: parent
                        width: 22; height: 22
                        name: "trash"
                        iconColor: Theme.accent
                        strokeWidth: 2.2
                    }
                    MouseArea {
                        id: delBtnArea
                        anchors.fill: parent
                        hoverEnabled: true
                        enabled: root.selectedCount > 0
                        cursorShape: Qt.PointingHandCursor
                        onClicked: deleteConfirm.open()
                    }
                }
            }
        }

        // ── Вкладки ─────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            height: 46
            color: Theme.bgDark

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width; height: 1
                color: Theme.separator
            }

            Row {
                anchors.fill: parent

                Repeater {
                    model: [
                        { label: qsTr("Медиа"),  count: root.mediaItems.length },
                        { label: qsTr("Файлы"),  count: root.fileItems.length },
                        { label: qsTr("Ссылки"), count: root.linkItems.length }
                    ]
                    delegate: Item {
                        width: root.width / 3
                        height: parent.height
                        readonly property bool active: root.currentTab === index

                        Text {
                            anchors.centerIn: parent
                            text: modelData.label + (modelData.count > 0 ? "  " + modelData.count : "")
                            color: active ? Theme.accentHover : Theme.textSecondary
                            font.pixelSize: Theme.fontSm
                            font.family: Theme.fontFamily
                            font.weight: active ? Font.Bold : Font.Normal
                        }

                        // Подчёркивание активной вкладки.
                        Rectangle {
                            anchors.bottom: parent.bottom
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: parent.width * 0.6
                            height: 2
                            visible: active
                            color: Theme.accentHover
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: contentSwipe.currentIndex = index
                        }
                    }
                }
            }
        }

        // ── Полоска «дотягиваю всю историю» ─────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: root.loadingMore ? 22 : 0
            visible: root.loadingMore
            color: Theme.bgCard
            Text {
                anchors.centerIn: parent
                text: qsTr("Загружаю всю историю…")
                color: Theme.textSecondary
                font.pixelSize: Theme.fontXs
                font.family: Theme.fontFamily
            }
        }

        // ── Контент (свайпом между вкладками) ────────────────────
        SwipeView {
            id: contentSwipe
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            // SwipeView — источник истины; root.currentTab следует за ним (свайп
            // и клики по вкладкам обновляют его без binding-loop, см. tab onClicked).
            onCurrentIndexChanged: if (root.currentTab !== currentIndex) root.currentTab = currentIndex

            // ── 0. Медиа (сетка превью) ──────────────────────
            Item {
                Text {
                    anchors.centerIn: parent
                    visible: root.mediaItems.length === 0
                    text: qsTr("Нет фото и видео")
                    color: Theme.textSecondary
                    font.pixelSize: Theme.fontMd
                }

                GridView {
                    id: mediaGrid
                    anchors.fill: parent
                    visible: root.mediaItems.length > 0
                    clip: true
                    cellWidth: Math.floor(width / Math.max(3, Math.floor(width / 130)))
                    cellHeight: cellWidth
                    model: root.mediaItems
                    cacheBuffer: cellHeight * 4

                    delegate: Item {
                        width: mediaGrid.cellWidth
                        height: mediaGrid.cellHeight

                        readonly property string mid: modelData.id
                        readonly property string effSource: root.mediaSource(modelData)
                        // Нет готового превью → просим бэкенд расшифровать (лениво, только
                        // для видимых плиток). По готовности markPreviewReady обновит source.
                        function ensurePreview() {
                            if (effSource.length === 0 && root.peerId.length > 0)
                                Chat.ensureGalleryPreview(root.peerId, mid)
                        }
                        Component.onCompleted: ensurePreview()
                        onMidChanged: ensurePreview()

                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: 1
                            color: Theme.bgCard
                            clip: true

                            Image {
                                id: thumb
                                anchors.fill: parent
                                source: effSource
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                cache: true
                                sourceSize.width: 260
                                sourceSize.height: 260
                            }
                            // Плейсхолдер пока превью грузится.
                            Rectangle {
                                anchors.fill: parent
                                visible: thumb.status !== Image.Ready
                                color: Theme.bgCard
                                AppIcon {
                                    anchors.centerIn: parent
                                    width: 28; height: 28
                                    name: "image"
                                    iconColor: Theme.textSecondary
                                }
                            }

                            // Затемнение + галочка для выбранной плитки в режиме выделения.
                            readonly property bool picked: root.selectMode && root.selectedIds[modelData.id] === true
                            Rectangle {
                                anchors.fill: parent
                                visible: parent.picked
                                color: Theme.accent
                                opacity: 0.35
                            }
                            Rectangle {
                                anchors.top: parent.top
                                anchors.right: parent.right
                                anchors.margins: 6
                                width: 24; height: 24
                                radius: 12
                                visible: root.selectMode
                                color: parent.picked ? Theme.accent : "#80000000"
                                border.width: 2
                                border.color: "#FFFFFF"
                                AppIcon {
                                    anchors.centerIn: parent
                                    width: 14; height: 14
                                    name: "check"
                                    visible: parent.parent.picked
                                    iconColor: "#FFFFFF"
                                    strokeWidth: 2.5
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (root.selectMode) { root.toggleSel(modelData.id); return }
                                    var g = root.galleryForViewer()
                                    var idx = 0
                                    for (var k = 0; k < g.length; ++k)
                                        if (g[k].id === modelData.id) { idx = k; break }
                                    if (g.length > 0) photoViewer.openGallery(g, idx)
                                }
                                onPressAndHold: {
                                    root.selectMode = true
                                    root.toggleSel(modelData.id)
                                }
                            }
                        }
                    }
                }
            }

            // ── 1. Файлы (список) ────────────────────────────
            Item {
                Text {
                    anchors.centerIn: parent
                    visible: root.fileItems.length === 0
                    text: qsTr("Нет файлов")
                    color: Theme.textSecondary
                    font.pixelSize: Theme.fontMd
                }

                ListView {
                    anchors.fill: parent
                    visible: root.fileItems.length > 0
                    clip: true
                    model: root.fileItems
                    spacing: 0

                    delegate: Rectangle {
                        id: fileRow
                        width: ListView.view.width
                        height: 64
                        readonly property bool picked: root.selectMode && root.selectedIds[modelData.id] === true
                        color: picked ? Theme.accentDim
                                      : (fileArea.containsMouse ? Theme.bgCard : "transparent")

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 14
                            anchors.rightMargin: 14
                            spacing: 12

                            Rectangle {
                                Layout.preferredWidth: 40
                                Layout.preferredHeight: 40
                                radius: Theme.radiusMd
                                color: Theme.bgSecondary
                                AppIcon {
                                    anchors.centerIn: parent
                                    width: 22; height: 22
                                    name: "file"
                                    iconColor: Theme.accentHover
                                    strokeWidth: 2
                                }
                            }

                            Column {
                                Layout.fillWidth: true
                                spacing: 3
                                Text {
                                    width: parent.width
                                    text: modelData.name && modelData.name.length > 0
                                          ? modelData.name : qsTr("файл")
                                    color: Theme.textPrimary
                                    font.pixelSize: Theme.fontSm
                                    font.family: Theme.fontFamily
                                    elide: Text.ElideMiddle
                                }
                                Text {
                                    text: root.fileSize(modelData.size)
                                          + (modelData.ts ? "  ·  " + root.shortDate(modelData.ts) : "")
                                    color: Theme.textSecondary
                                    font.pixelSize: Theme.fontXs
                                    font.family: Theme.fontFamily
                                }
                            }

                            // Режим выделения → кружок-галочка; обычный → иконка скачивания.
                            Rectangle {
                                Layout.preferredWidth: 34
                                Layout.preferredHeight: 34
                                radius: root.selectMode ? 17 : Theme.radiusSm
                                color: (root.selectMode && fileRow.picked) ? Theme.accent : "transparent"
                                border.width: root.selectMode ? 2 : 0
                                border.color: fileRow.picked ? Theme.accent : Theme.border
                                AppIcon {
                                    anchors.centerIn: parent
                                    width: 20; height: 20
                                    name: root.selectMode ? "check" : "download"
                                    visible: !root.selectMode || fileRow.picked
                                    iconColor: root.selectMode ? "#FFFFFF" : Theme.accentHover
                                    strokeWidth: 2
                                }
                            }
                        }

                        Rectangle {
                            anchors.bottom: parent.bottom
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.leftMargin: 14
                            height: 1
                            color: Theme.separator
                        }

                        MouseArea {
                            id: fileArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (root.selectMode) root.toggleSel(modelData.id)
                                else root.saveFile(modelData.id, modelData.name)
                            }
                            onPressAndHold: {
                                root.selectMode = true
                                root.toggleSel(modelData.id)
                            }
                        }
                    }
                }
            }

            // ── 2. Ссылки (список) ───────────────────────────
            Item {
                Text {
                    anchors.centerIn: parent
                    visible: root.linkItems.length === 0
                    text: qsTr("Нет ссылок")
                    color: Theme.textSecondary
                    font.pixelSize: Theme.fontMd
                }

                ListView {
                    anchors.fill: parent
                    visible: root.linkItems.length > 0
                    clip: true
                    model: root.linkItems
                    spacing: 0

                    delegate: Rectangle {
                        id: linkRow
                        width: ListView.view.width
                        height: linkCol.implicitHeight + 24
                        readonly property bool picked: root.selectMode && root.selectedIds[modelData.id] === true
                        color: picked ? Theme.accentDim
                                      : (linkArea.containsMouse ? Theme.bgCard : "transparent")

                        // Кружок-галочка в режиме выделения (справа).
                        Rectangle {
                            anchors.right: parent.right
                            anchors.rightMargin: 14
                            anchors.verticalCenter: parent.verticalCenter
                            width: 28; height: 28
                            radius: 14
                            visible: root.selectMode
                            color: linkRow.picked ? Theme.accent : "transparent"
                            border.width: 2
                            border.color: linkRow.picked ? Theme.accent : Theme.border
                            z: 2
                            AppIcon {
                                anchors.centerIn: parent
                                width: 16; height: 16
                                name: "check"
                                visible: linkRow.picked
                                iconColor: "#FFFFFF"
                                strokeWidth: 2.5
                            }
                        }

                        Column {
                            id: linkCol
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: 14
                            anchors.rightMargin: root.selectMode ? 50 : 14
                            spacing: 4

                            Text {
                                width: parent.width
                                text: modelData.url
                                color: Theme.accentHover
                                font.pixelSize: Theme.fontSm
                                font.family: Theme.fontFamily
                                elide: Text.ElideRight
                            }
                            Text {
                                width: parent.width
                                visible: modelData.snippet && modelData.snippet.length > 0
                                text: modelData.snippet
                                color: Theme.textSecondary
                                font.pixelSize: Theme.fontXs
                                font.family: Theme.fontFamily
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }
                            Text {
                                text: root.shortDate(modelData.ts)
                                color: Theme.textSecondary
                                font.pixelSize: Theme.fontXs
                                font.family: Theme.fontFamily
                            }
                        }

                        Rectangle {
                            anchors.bottom: parent.bottom
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.leftMargin: 14
                            height: 1
                            color: Theme.separator
                        }

                        MouseArea {
                            id: linkArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (root.selectMode) root.toggleSel(modelData.id)
                                else Qt.openUrlExternally(modelData.url)
                            }
                            onPressAndHold: {
                                root.selectMode = true
                                root.toggleSel(modelData.id)
                            }
                        }
                    }
                }
            }
        }
    }

    // Полноэкранный просмотрщик фото (свой экземпляр — экран самодостаточен).
    PhotoViewer {
        id: photoViewer
        anchors.fill: parent
        onSaveRequested: function(messageId, filename) {
            root.saveFile(messageId, filename)
        }
    }

    // ── Подтверждение удаления выбранных вложений ──────────────────────
    Popup {
        id: deleteConfirm
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
                text: qsTr("Удалить вложения?")
                color: Theme.textPrimary
                font.pixelSize: Theme.fontLg
                font.family: Theme.fontFamily
                font.weight: Font.Medium
            }
            Text {
                Layout.fillWidth: true
                text: qsTr("Выбранные сообщения с вложениями будут удалены и с сервера, и у собеседника при следующей синхронизации.")
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
                        deleteConfirm.close()
                        root.deleteSelected()
                    }
                }
                ParaButton {
                    Layout.fillWidth: true
                    text: qsTr("Отмена")
                    secondary: true
                    onClicked: deleteConfirm.close()
                }
            }
        }
    }

    // Лёгкий тост (сохранение файла и т.п.).
    Rectangle {
        id: toast
        function show(t) { toastText.text = t; opacity = 1; toastTimer.restart() }
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 40
        width: toastText.implicitWidth + 32
        height: 40
        radius: 20
        color: Theme.bgCard
        border.color: Theme.border
        opacity: 0
        Behavior on opacity { NumberAnimation { duration: 180 } }
        Text {
            id: toastText
            anchors.centerIn: parent
            color: Theme.textPrimary
            font.pixelSize: Theme.fontSm
        }
        Timer { id: toastTimer; interval: 2200; onTriggered: toast.opacity = 0 }
    }
}
