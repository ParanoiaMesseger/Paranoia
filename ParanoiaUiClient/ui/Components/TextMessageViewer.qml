import QtQuick
import QtQuick.Controls
import QtCore
import ParanoiaUiClient

// Полноэкранное чтение длинного текстового сообщения. Открывается кнопкой-уголками
// в пузыре (видна только для длинных сообщений, >~10 строк). Во всю ширину экрана (в
// ленте пузырь сжат до 72%) и с прокруткой — удобно читать «простыни».
// Тело рендерит ТОТ ЖЕ MessageText, что в ленте → визуал 1:1 (подсветка кода, инлайн-
// код чипом, ссылки, эмодзи, переносы). «Копировать» внизу — копирует целиком. Шрифт
// масштабируется: кнопки A−/A+ в шапке, пинч (тач), Ctrl+колесо (десктоп), Ctrl±/Ctrl0.
Rectangle {
    id: root
    visible: false
    z: 1000
    // Фон тела — «кофе с молоком» (bgSecondary), как шапка/подвал ридера. Раньше был
    // bgPrimary (#F2E8DF) — в светлой теме читался почти белым (правка Иванова 0.2.15).
    color: Theme.bgSecondary
    focus: visible

    property string bodyText: ""
    property string senderName: ""
    property bool outgoing: false
    property string timeText: ""

    // Управляемый зум текста (множитель к шрифту ленты). Запоминается между
    // открытиями (в т.ч. между диалогами и перезапусками) — см. _settings ниже.
    property real textScale: 1.0
    property real pinchStartScale: 1.0
    readonly property real minScale: 0.5
    readonly property real maxScale: 2.0

    // Персист последнего масштаба (как Theme._settings). При открытии подхватываем,
    // при изменении — сохраняем.
    property Settings _settings: Settings {
        category: "TextViewer"
        property real lastScale: 1.0
    }
    onTextScaleChanged: _settings.lastScale = textScale

    // Режим выделения: тело переключается с MessageText (рендер 1:1 с лентой, но НЕ
    // выделяемый) на выделяемый TextEdit с сырым текстом. На Android ручки выделения
    // даёт ТОЛЬКО редактируемое поле (read-only по тап-удержанию не выделяется), поэтому
    // поле editable, а правки гасятся откатом текста (см. bodyEdit). В этом режиме
    // форматирование (код/ссылки/жирный) не показываем — задача режима «выделить и
    // скопировать кусок», для чего удобнее именно сырой текст.
    property bool selectMode: false

    signal copyRequested(string text)

    function clampScale(v) { return Math.max(minScale, Math.min(maxScale, v)) }
    function zoomBy(factor) { textScale = clampScale(textScale * factor) }
    function resetScale() { textScale = 1.0 }

    function open(text, sender, isOutgoing, time) {
        bodyText = text || ""
        senderName = sender || ""
        outgoing = isOutgoing === true
        timeText = time || ""
        textScale = clampScale(_settings.lastScale)   // подхватываем прошлый масштаб
        selectMode = false
        bodyFlick.contentY = 0
        visible = true
        forceActiveFocus()
    }

    function close() {
        visible = false
        selectMode = false
        bodyText = ""
        senderName = ""
        timeText = ""
    }

    // Esc/назад: сперва выходим из режима выделения, затем закрываем ридер.
    Keys.onEscapePressed: {
        if (selectMode) selectMode = false
        else close()
    }
    // Ctrl + / − / 0 — зум с клавиатуры (десктоп). Plus/Equal — увеличить.
    Keys.onPressed: function(event) {
        if (event.modifiers & Qt.ControlModifier) {
            if (event.key === Qt.Key_Plus || event.key === Qt.Key_Equal) { zoomBy(1.15); event.accepted = true }
            else if (event.key === Qt.Key_Minus) { zoomBy(1 / 1.15); event.accepted = true }
            else if (event.key === Qt.Key_0) { resetScale(); event.accepted = true }
        }
    }

    // Фон гасит случайные тапы — чтобы не проваливались в ленту под оверлеем.
    // Объявлен первым → лежит ниже шапки/тела/подвала (они получают клики).
    MouseArea {
        anchors.fill: parent
        hoverEnabled: false
        onClicked: function(mouse) { mouse.accepted = true }
    }

    // ── Шапка: имя автора + закрыть ──────────────────────────────────────
    Rectangle {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 52
        color: Theme.bgSecondary

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 16
            anchors.right: zoomGroup.left
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            text: root.outgoing
                  ? qsTr("Вы")
                  : (root.senderName.length > 0 ? root.senderName : qsTr("Сообщение"))
            color: root.outgoing ? Theme.textPrimary : Theme.accent
            font.pixelSize: Theme.fontMd
            font.family: Theme.fontFamily
            font.weight: Font.DemiBold
            elide: Text.ElideRight
        }

        // Зум текста: A− [процент] A+ (процент по тапу сбрасывает в 100%).
        Row {
            id: zoomGroup
            anchors.right: closeBtn.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4

            Rectangle {
                width: 34; height: 34; radius: Theme.radiusSm
                anchors.verticalCenter: parent.verticalCenter
                color: zoomOutArea.containsMouse ? Theme.bgCard : Theme.bgInput
                border.width: 1; border.color: Theme.border
                opacity: root.textScale <= root.minScale + 0.001 ? 0.45 : 1.0
                AppIcon {
                    anchors.centerIn: parent; width: 16; height: 16
                    name: "minus"; iconColor: Theme.textPrimary; strokeWidth: 2.2
                }
                MouseArea {
                    id: zoomOutArea
                    anchors.fill: parent; hoverEnabled: true
                    onClicked: root.zoomBy(1 / 1.15)
                }
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: 42
                horizontalAlignment: Text.AlignHCenter
                text: Math.round(root.textScale * 100) + "%"
                color: Theme.textSecondary
                font.pixelSize: Theme.fontSm
                font.family: Theme.fontFamily
                MouseArea { anchors.fill: parent; onClicked: root.resetScale() }
            }

            Rectangle {
                width: 34; height: 34; radius: Theme.radiusSm
                anchors.verticalCenter: parent.verticalCenter
                color: zoomInArea.containsMouse ? Theme.bgCard : Theme.bgInput
                border.width: 1; border.color: Theme.border
                opacity: root.textScale >= root.maxScale - 0.001 ? 0.45 : 1.0
                AppIcon {
                    anchors.centerIn: parent; width: 16; height: 16
                    name: "plus"; iconColor: Theme.textPrimary; strokeWidth: 2.2
                }
                MouseArea {
                    id: zoomInArea
                    anchors.fill: parent; hoverEnabled: true
                    onClicked: root.zoomBy(1.15)
                }
            }
        }

        Rectangle {
            id: closeBtn
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            width: 38; height: 38
            radius: Theme.radiusSm
            color: closeArea.containsMouse ? Theme.bgCard : "transparent"
            border.width: 1
            border.color: Theme.border
            AppIcon {
                anchors.centerIn: parent
                width: 18; height: 18
                name: "close"
                iconColor: Theme.textPrimary
                strokeWidth: 2.2
            }
            MouseArea {
                id: closeArea
                anchors.fill: parent
                hoverEnabled: true
                onClicked: root.close()
            }
        }

        Rectangle {
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: 1
            color: Theme.border
        }
    }

    // Читаемая колонка: во всю ширину на телефоне, ограничена на широком экране.
    readonly property int colWidth: Math.min(width - 32, 760)
    readonly property int colPad: Math.max(16, (width - colWidth) / 2)

    // ── Тело (режим ЧТЕНИЯ): прокручиваемое сообщение в комфортной ширине ──
    // Рендер — ТОТ ЖЕ MessageText, что в ленте → 1:1 совпадение (подсветка кода,
    // инлайн-код чипом, ссылки, эмодзи, переносы). Зум — `fontScale` (×textScale).
    Flickable {
        id: bodyFlick
        visible: !root.selectMode
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: footer.top
        clip: true
        contentWidth: width
        contentHeight: bodyView.implicitHeight + 48
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick

        ScrollBar.vertical: AppScrollBar { policy: ScrollBar.AsNeeded }

        MessageText {
            id: bodyView
            x: root.colPad
            y: 24
            width: root.colWidth
            raw: root.bodyText
            outgoing: root.outgoing
            textColor: Theme.textPrimary
            fontScale: root.textScale
            onLinkActivated: function(url) { Qt.openUrlExternally(url) }
            onCopyRequested: function(t) { root.copyRequested(t) }
        }

        // Пинч двумя пальцами — зум текста (тач).
        PinchHandler {
            target: null
            minimumPointCount: 2
            maximumPointCount: 2
            onActiveChanged: if (active) root.pinchStartScale = root.textScale
            onActiveScaleChanged: if (active) root.textScale = root.clampScale(root.pinchStartScale * activeScale)
        }

        // Ctrl + колесо — зум текста (десктоп). Без Ctrl колесо прокручивает как обычно.
        WheelHandler {
            target: null
            acceptedModifiers: Qt.ControlModifier
            onWheel: function(event) {
                root.zoomBy(event.angleDelta.y > 0 ? 1.12 : 1 / 1.12)
                event.accepted = true
            }
        }
    }

    // ── Тело (режим ВЫДЕЛЕНИЯ): сырой текст + СВОИ ручки выделения ─────────
    // Почему свои ручки: приложение использует Qt VirtualKeyboard как input-метод
    // на мобиле; он замещает платформенный input-context, а его контрол ручек
    // (DesktopInputSelectionControl) включён только для desktop → на Android ни
    // нативных ручек, ни VKB-ручек не появляется НИ у TextEdit, НИ у TextArea
    // (проверено в бетах -9/-10/-11). Поэтому выделение драйвим сами: read-only поле
    // (без клавиатуры!), long-press выделяет слово, две перетаскиваемые ручки тянут
    // границы через select(). Поведение одинаково на десктопе и Android, не зависит
    // от VKB/платформы. На десктопе вдобавок работает обычное выделение мышью.
    Flickable {
        id: selectFlick
        visible: root.selectMode
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: footer.top
        clip: true
        contentWidth: width
        contentHeight: bodyEdit.implicitHeight + 48
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick

        ScrollBar.vertical: AppScrollBar { policy: ScrollBar.AsNeeded }

        TextEdit {
            id: bodyEdit
            x: root.colPad
            y: 24
            width: root.colWidth
            text: root.bodyText
            textFormat: TextEdit.PlainText
            wrapMode: TextEdit.Wrap
            readOnly: true                 // без клавиатуры; выделение драйвим сами
            selectByMouse: true            // десктоп: выделение мышью «из коробки»
            persistentSelection: true
            color: Theme.textPrimary
            selectionColor: Theme.accent
            selectedTextColor: "#ffffff"
            font.family: Theme.fontFamily
            font.pixelSize: Math.round(Theme.fontMd * root.textScale)

            // Long-press → выделить слово под пальцем; одиночный тап → снять выделение.
            // TapHandler срабатывает только на «стоячем» касании, поэтому вертикальный
            // свайп по-прежнему прокручивает Flickable (выделение ему не мешает).
            TapHandler {
                acceptedDevices: PointerDevice.TouchScreen | PointerDevice.Mouse | PointerDevice.Stylus
                onLongPressed: {
                    bodyEdit.cursorPosition = bodyEdit.positionAt(point.position.x, point.position.y)
                    bodyEdit.selectWord()
                }
                onTapped: bodyEdit.deselect()
            }
        }

        // ── Ручки выделения (свои) ───────────────────────────────────────
        // Перетаскивание ручки тянет соответствующую границу выделения. Якорь —
        // противоположная граница (фиксируется в onPressed). preventStealing держит
        // жест за ручкой (Flickable не перехватывает скролл во время тяги).
        component SelHandle: Rectangle {
            property int edgePos: 0        // позиция границы в тексте
            property bool isStart: false
            // Прямоугольник каретки границы в координатах bodyEdit.
            readonly property rect cr: bodyEdit.positionToRectangle(edgePos)
            width: 20; height: 20
            // Капля: три угла скруглены, один острый и смотрит ВНУТРЬ выделения
            // (к тексту между ручками) — у левой ручки острый верх-правый угол, у
            // правой ручки верх-левый. Per-corner radius — Qt 6.7+.
            radius: width / 2
            topLeftRadius:  isStart ? width / 2 : 0
            topRightRadius: isStart ? 0 : width / 2
            color: Theme.accent
            border.color: "#ffffff"; border.width: 2
            visible: root.selectMode && bodyEdit.selectedText.length > 0
            // Острый угол капли прислоняется к каретке границы, тело висит под строкой.
            x: bodyEdit.x + cr.x - (isStart ? width : 0)
            y: bodyEdit.y + cr.y + cr.height

            property int dragAnchor: 0
            MouseArea {
                anchors.fill: parent
                anchors.margins: -12          // увеличенная зона захвата для пальца
                preventStealing: true
                cursorShape: Qt.SizeHorCursor
                onPressed: parent.dragAnchor = parent.isStart ? bodyEdit.selectionEnd
                                                              : bodyEdit.selectionStart
                onPositionChanged: function(mouse) {
                    // Точка пальца → в координаты bodyEdit; поднимаем на ~0.7 строки
                    // вверх (ручка-кружок ниже текста) и наводим на середину строки.
                    var pt = mapToItem(bodyEdit, mouse.x, mouse.y)
                    var liftY = pt.y - parent.cr.height * 0.7
                    var pos = bodyEdit.positionAt(pt.x, liftY)
                    var lo = Math.min(pos, parent.dragAnchor)
                    var hi = Math.max(pos, parent.dragAnchor)
                    if (hi > lo) bodyEdit.select(lo, hi)
                }
            }
        }

        SelHandle { isStart: true;  edgePos: bodyEdit.selectionStart }
        SelHandle { isStart: false; edgePos: bodyEdit.selectionEnd }
    }

    // ── Подвал: время + копировать целиком ───────────────────────────────
    Rectangle {
        id: footer
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 48
        color: Theme.bgSecondary

        Rectangle {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: 1
            color: Theme.border
        }

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            visible: root.timeText.length > 0
            text: root.timeText
            color: Theme.textSecondary
            font.pixelSize: Theme.fontSm
            font.family: Theme.fontFamily
        }

        // Тумблер режима выделения. Вкл → тело становится выделяемым (сырой текст),
        // кнопка «Копировать» копирует выделенное (или всё, если ничего не выделено).
        Rectangle {
            id: selectBtn
            anchors.right: copyBtn.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            width: selectRow.implicitWidth + 22
            height: 34
            radius: Theme.radiusSm
            color: root.selectMode ? Theme.accent
                                   : (selectArea.containsMouse ? Theme.bgCard : Theme.bgInput)
            border.width: 1
            border.color: root.selectMode ? Theme.accent : Theme.border

            Row {
                id: selectRow
                anchors.centerIn: parent
                spacing: 7
                AppIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 16; height: 16
                    name: "selectAll"
                    iconColor: root.selectMode ? Theme.bgPrimary : Theme.textPrimary
                    fillColor: selectBtn.color
                    secondaryColor: selectBtn.color
                    strokeWidth: 1.6
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.selectMode ? qsTr("Готово") : qsTr("Выделить")
                    color: root.selectMode ? Theme.bgPrimary : Theme.textPrimary
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                }
            }

            MouseArea {
                id: selectArea
                anchors.fill: parent
                hoverEnabled: true
                onClicked: {
                    root.selectMode = !root.selectMode
                    // Не фокусируем поле сразу — иначе на Android выскочит клавиатура.
                    // Long-press по тексту сам сфокусирует поле и начнёт выделение.
                    if (!root.selectMode) root.forceActiveFocus()
                }
            }
        }

        Rectangle {
            id: copyBtn
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            width: copyRow.implicitWidth + 22
            height: 34
            radius: Theme.radiusSm
            color: copyArea.containsMouse ? Theme.bgCard : Theme.bgInput
            border.width: 1
            border.color: Theme.border

            Row {
                id: copyRow
                anchors.centerIn: parent
                spacing: 7
                AppIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 16; height: 16
                    name: copyArea.copied ? "check" : "copy"
                    iconColor: Theme.textPrimary
                    fillColor: copyBtn.color
                    secondaryColor: copyBtn.color
                    strokeWidth: 1.6
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    // В режиме выделения с выделенным фрагментом — «Копировать выделенное».
                    text: copyArea.copied
                          ? qsTr("Скопировано")
                          : (root.selectMode && bodyEdit.selectedText.length > 0
                             ? qsTr("Копировать выделенное") : qsTr("Копировать"))
                    color: Theme.textPrimary
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                }
            }

            MouseArea {
                id: copyArea
                anchors.fill: parent
                hoverEnabled: true
                property bool copied: false
                onClicked: {
                    var sel = (root.selectMode && bodyEdit.selectedText.length > 0)
                              ? bodyEdit.selectedText : root.bodyText
                    root.copyRequested(sel)
                    copied = true
                    copyResetTimer.restart()
                }
                Timer { id: copyResetTimer; interval: 1200; onTriggered: copyArea.copied = false }
            }
        }
    }
}
