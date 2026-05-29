import QtQuick
import QtQuick.VirtualKeyboard
import QtQuick.VirtualKeyboard.Styles
import ParanoiaUiClient

KeyboardStyle {

    // ── Palette ──────────────────────────────────────────
    // Привязано к Theme: клавиатура автоматически меняет цвета вместе с темой
    // приложения (светлая/тёмная), см. ui/Theme.qml.
    readonly property color clrBg:       Theme.bgPrimary
    readonly property color clrKey:      Theme.bgCard
    readonly property color clrKeyFn:    Theme.bgInput
    readonly property color clrPressed:  Theme.accent
    readonly property color clrEnter:    Theme.accent
    readonly property color clrEnterPrs: Theme.accentHover
    readonly property color clrBorder:   Theme.border
    readonly property color clrText:     Theme.textPrimary
    readonly property color clrHint:     Theme.textHint
    readonly property color clrSpace:    Theme.bgDark
    readonly property color clrShiftOn:  Theme.accentDim
    readonly property bool landscapeMode: Screen.width > Screen.height

    // ── Design geometry ───────────────────────────────────
    keyboardDesignWidth:          480
    keyboardDesignHeight:         landscapeMode ? 132 : 250
    keyboardRelativeLeftMargin:    5 / keyboardDesignWidth
    keyboardRelativeRightMargin:   5 / keyboardDesignWidth
    keyboardRelativeTopMargin:     8 / keyboardDesignHeight
    keyboardRelativeBottomMargin:  8 / keyboardDesignHeight

    // ── Keyboard background ───────────────────────────────
    keyboardBackground: Rectangle { color: clrBg }

    // ── Normal key ────────────────────────────────────────
    keyPanel: KeyPanel {
        Rectangle {
            anchors { fill: parent; margins: 1 }
            radius: 5
            color: control.pressed ? clrPressed : clrKey
            border { color: clrBorder; width: 1 }

            Text {
                anchors.centerIn: parent
                text: control.displayText
                color: clrText
                font.pixelSize: 30
                font.weight: Font.Light
            }

            Text {
                visible: control.smallTextVisible
                anchors { top: parent.top; right: parent.right; margins: 1 }
                text: control.smallText
                color: clrHint
                font.pixelSize: 12
            }
        }
    }

    // ── Shift key ─────────────────────────────────────────
    shiftKeyPanel: KeyPanel {
        Rectangle {
            anchors { fill: parent; margins: 3 }
            radius: 5
            color: control.pressed ? clrPressed
                 : control.uppercased ? clrShiftOn
                 : clrKeyFn
            border {
                color: control.uppercased ? clrEnter : clrBorder
                width: 1
            }

            KeyboardIcon {
                anchors.centerIn: parent
                name: "shift"
                iconColor: control.uppercased ? clrEnter : clrText
                strokeWidth: 1.9
            }
        }
    }

    // ── Backspace key ─────────────────────────────────────
    backspaceKeyPanel: KeyPanel {
        Rectangle {
            anchors { fill: parent; margins: 3 }
            radius: 5
            color: control.pressed ? clrPressed : clrKeyFn
            border { color: clrBorder; width: 1 }

            KeyboardIcon {
                anchors.centerIn: parent
                name: "backspace"
                iconColor: clrText
                strokeWidth: 1.8
            }
        }
    }

    // ── Space key ─────────────────────────────────────────
    spaceKeyPanel: KeyPanel {
        Rectangle {
            anchors { fill: parent; margins: 3 }
            radius: 5
            color: control.pressed ? clrPressed : clrSpace
            border { color: clrBorder; width: 1 }
        }
    }

    // ── Enter key ─────────────────────────────────────────
    enterKeyPanel: KeyPanel {
        Rectangle {
            anchors { fill: parent; margins: 3 }
            radius: 5
            color: control.pressed ? clrEnterPrs : clrEnter
            border { color: clrEnterPrs; width: 1 }

            KeyboardIcon {
                anchors.centerIn: parent
                name: "enter"
                iconColor: clrText
                strokeWidth: 2
            }
        }
    }

    // ── Symbol mode key ───────────────────────────────────
    symbolKeyPanel: KeyPanel {
        Rectangle {
            anchors { fill: parent; margins: 3 }
            radius: 5
            color: control.pressed ? clrPressed : clrKeyFn
            border { color: clrBorder; width: 1 }

            Text {
                anchors.centerIn: parent
                text: control.displayText
                color: clrText
                font.pixelSize: 18
            }
        }
    }

    // ── Mode key ──────────────────────────────────────────
    modeKeyPanel: KeyPanel {
        Rectangle {
            anchors { fill: parent; margins: 3 }
            radius: 5
            color: control.pressed ? clrPressed : clrKeyFn
            border { color: clrBorder; width: 1 }

            Text {
                anchors.centerIn: parent
                text: control.displayText
                color: clrText
                font.pixelSize: 18
            }
        }
    }

    // ── Language key ──────────────────────────────────────
    languageKeyPanel: KeyPanel {
        Rectangle {
            anchors { fill: parent; margins: 3 }
            radius: 5
            color: control.pressed ? clrPressed : clrKeyFn
            border { color: clrBorder; width: 1 }

            Text {
                anchors.centerIn: parent
                text: control.displayText
                color: clrText
                font.pixelSize: 18
            }
        }
    }

    // ── Handwriting key ───────────────────────────────────
    handwritingKeyPanel: KeyPanel {
        Rectangle {
            anchors { fill: parent; margins: 3 }
            radius: 5
            color: control.pressed ? clrPressed : clrKeyFn
            border { color: clrBorder; width: 1 }

            Text {
                anchors.centerIn: parent
                text: control.displayText
                color: clrText
                font.pixelSize: 18
            }
        }
    }

    // ── Hide keyboard key ─────────────────────────────────
    hideKeyPanel: KeyPanel {
        Rectangle {
            anchors { fill: parent; margins: 3 }
            radius: 5
            color: control.pressed ? clrPressed : clrKeyFn
            border { color: clrBorder; width: 1 }

            KeyboardIcon {
                anchors.centerIn: parent
                name: "keyboardHide"
                iconColor: clrHint
                strokeWidth: 1.7
            }
        }
    }

    // ── Character preview popup ───────────────────────────
    characterPreviewMargin: 0
    characterPreviewDelegate: Item {
        id: previewRoot
        property string text
        Rectangle {
            anchors.fill: parent
            radius: 5
            color: clrKey
            border { color: clrBorder; width: 1 }
            Text {
                anchors.centerIn: parent
                text: previewRoot.text
                color: clrText
                font.pixelSize: 38
            }
        }
    }

    // ── Word candidate list ───────────────────────────────
    selectionListHeight: landscapeMode ? 32 : 44
    selectionListDelegate: SelectionListItem {
        id: candidateItem
        width: Math.max(76, candidateText.implicitWidth + 30)

        Rectangle {
            anchors.fill: parent
            anchors.margins: 3
            radius: 6
            color: candidateItem.ListView.isCurrentItem ? clrShiftOn : "transparent"
            border.width: candidateItem.ListView.isCurrentItem ? 1 : 0
            border.color: clrBorder
        }

        Text {
            id: candidateText
            anchors.centerIn: parent
            text: decorateText(display, wordCompletionLength)
            textFormat: Text.RichText
            color: clrText
            opacity: candidateItem.ListView.isCurrentItem ? 1 : 0.88
            font.pixelSize: landscapeMode ? 14 : 16
            font.family: Qt.application.font.family

            function decorateText(value, completionLength) {
                const textValue = value || ""
                if (completionLength > 0)
                    return textValue.slice(0, -completionLength) + "<u>" + textValue.slice(-completionLength) + "</u>"
                return textValue
            }
        }
    }
    selectionListHighlight: Rectangle {
        radius: 6
        color: clrShiftOn
        border.width: 1
        border.color: clrBorder
    }
    selectionListBackground: Rectangle {
        color: clrBg
        border.width: 1
        border.color: clrBorder
    }
    selectionListAdd: Transition {
        NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 120 }
    }
    selectionListRemove: Transition {
        NumberAnimation { property: "opacity"; to: 0; duration: 100 }
    }

    // ── Alternate keys popup (long-press) ─────────────────
    alternateKeysListItemWidth:    50
    alternateKeysListItemHeight:   50
    alternateKeysListTopMargin:     6
    alternateKeysListBottomMargin:  6
    alternateKeysListLeftMargin:    6
    alternateKeysListRightMargin:   6

    alternateKeysListBackground: Rectangle {
        color: clrBg
        border { color: clrBorder; width: 1 }
        radius: 5
    }
    // ВАЖНО: это делегат ListView'а (модель с ролями text/data, ListView.isCurrentItem),
    // а НЕ key-панель. Использовать здесь KeyPanel/control нельзя — control в этом
    // контексте не существует, и без явных размеров элементы получаются нулевыми,
    // из-за чего popup длинного нажатия визуально «не появляется» и выбор не работает.
    alternateKeysListDelegate: Item {
        id: altKeyItem
        width: alternateKeysListItemWidth
        height: alternateKeysListItemHeight
        Rectangle {
            anchors { fill: parent; margins: 4 }
            radius: 5
            color: altKeyItem.ListView.isCurrentItem ? clrPressed : clrKey
            border { color: clrBorder; width: 1 }
            Text {
                anchors.centerIn: parent
                text: model.text
                color: clrText
                font.pixelSize: 26
            }
        }
    }
    alternateKeysListHighlight: Rectangle {
        color: clrPressed
        opacity: 0.25
        radius: 5
    }

    // ── Function popup list ───────────────────────────────
    functionPopupListBackground: Rectangle {
        color: clrKey
        border { color: clrBorder; width: 1 }
        radius: 5
    }
    functionPopupListDelegate: Item {
        id: funcItem
        width: funcLabel.implicitWidth + 28
        height: 48
        // Роль модели функционального popup'а — keyboardFunction (enum), не modelData.
        readonly property string label: {
            switch (keyboardFunction) {
            case QtVirtualKeyboard.KeyboardFunction.HideInputPanel:       return "Скрыть"
            case QtVirtualKeyboard.KeyboardFunction.ChangeLanguage:       return "Язык"
            case QtVirtualKeyboard.KeyboardFunction.ToggleHandwritingMode: return "Рукопись"
            default: return ""
            }
        }
        Text {
            id: funcLabel
            anchors.centerIn: parent
            text: funcItem.label
            color: clrText
            font.pixelSize: 18
        }
    }
    functionPopupListHighlight: Rectangle {
        color: clrPressed
        opacity: 0.3
        radius: 4
    }

    // ── Popup list ────────────────────────────────────────
    popupListBackground: Rectangle {
        color: clrKey
        border { color: clrBorder; width: 1 }
        radius: 5
    }
    popupListDelegate: Item {
        width: popupLabel.implicitWidth + 24
        height: 40
        Text {
            id: popupLabel
            anchors.centerIn: parent
            text: model.display !== undefined ? model.display : ""
            color: clrText
            font.pixelSize: 18
        }
    }
    popupListHighlight: Rectangle {
        color: clrPressed
        opacity: 0.3
        radius: 4
    }
    popupListAdd: Transition {}
    popupListRemove: Transition {}

    // ── Navigation highlight ──────────────────────────────
    navigationHighlight: Rectangle {
        color: "transparent"
        border { color: clrPressed; width: 2 }
        radius: 5
    }

}
