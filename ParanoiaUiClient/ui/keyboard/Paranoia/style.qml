import QtQuick
import QtQuick.VirtualKeyboard.Styles

KeyboardStyle {

    // ── Palette ──────────────────────────────────────────
    readonly property color clrBg:       "#08070a"
    readonly property color clrKey:      "#12080C"
    readonly property color clrKeyFn:    "#1B0A10"
    readonly property color clrPressed:  "#C91122"
    readonly property color clrEnter:    "#C91122"
    readonly property color clrEnterPrs: "#FF2738"
    readonly property color clrBorder:   "#3A1118"
    readonly property color clrText:     "#F7E8EA"
    readonly property color clrHint:     "#56323A"
    readonly property color clrSpace:    "#0E0609"

    // ── Design geometry ───────────────────────────────────
    keyboardDesignWidth:          480
    keyboardDesignHeight:         Screen.width > Screen.height ? 100 : 260
    keyboardRelativeLeftMargin:    5 / keyboardDesignWidth
    keyboardRelativeRightMargin:   5 / keyboardDesignWidth
    keyboardRelativeTopMargin:     8 / keyboardDesignHeight
    keyboardRelativeBottomMargin:  8 / keyboardDesignHeight

    // ── Keyboard background ───────────────────────────────
    keyboardBackground: Rectangle { color: clrBg }

    // ── Normal key ────────────────────────────────────────
    keyPanel: KeyPanel {
        Rectangle {
            anchors { fill: parent; margins: 3 }
            radius: 5
            color: control.pressed ? clrPressed : clrKey
            border { color: clrBorder; width: 1 }

            Text {
                anchors.centerIn: parent
                text: control.displayText
                color: clrText
                font.pixelSize: 28
                font.weight: Font.Normal
            }

            Text {
                visible: control.smallTextVisible
                anchors { top: parent.top; right: parent.right; margins: 3 }
                text: control.smallText
                color: clrHint
                font.pixelSize: 14
            }
        }
    }

    // ── Shift key ─────────────────────────────────────────
    shiftKeyPanel: KeyPanel {
        Rectangle {
            anchors { fill: parent; margins: 3 }
            radius: 5
            color: control.pressed ? clrPressed
                 : control.uppercased ? "#4A060C"
                 : clrKeyFn
            border {
                color: control.uppercased ? "#C91122" : clrBorder
                width: 1
            }

            Text {
                anchors.centerIn: parent
                text: "⇧"
                color: control.uppercased ? "#C91122" : clrText
                font.pixelSize: 24
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

            Text {
                anchors.centerIn: parent
                text: "←"
                color: clrText
                font.pixelSize: 22
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

            Text {
                anchors.centerIn: parent
                text: "⏎"
                color: clrText
                font.pixelSize: 22
                font.weight: Font.Medium
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
                font.pixelSize: 22
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
                font.pixelSize: 22
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
                font.pixelSize: 22
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
                font.pixelSize: 22
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

            Text {
                anchors.centerIn: parent
                text: "▼"
                color: clrHint
                font.pixelSize: 18
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
                font.pixelSize: 52
            }
        }
    }

    // ── Word candidate list (hidden) ──────────────────────
    selectionListHeight: 0
    selectionListDelegate: Item {}
    selectionListHighlight: Item {}
    selectionListBackground: Item {}
    selectionListAdd: Transition {}
    selectionListRemove: Transition {}

    // ── Alternate keys popup (long-press) ─────────────────
    alternateKeysListItemWidth:    80
    alternateKeysListItemHeight:   80
    alternateKeysListTopMargin:     6
    alternateKeysListBottomMargin:  6
    alternateKeysListLeftMargin:    6
    alternateKeysListRightMargin:   6

    alternateKeysListBackground: Rectangle {
        color: clrBg
        border { color: clrBorder; width: 1 }
        radius: 5
    }
    alternateKeysListDelegate: KeyPanel {
        Rectangle {
            anchors { fill: parent; margins: 3 }
            radius: 5
            color: control.pressed ? clrPressed : clrKey
            border { color: clrBorder; width: 1 }
            Text {
                anchors.centerIn: parent
                text: control.displayText
                color: clrText
                font.pixelSize: 28
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
        Text {
            anchors.centerIn: parent
            text: modelData !== undefined ? modelData : ""
            color: clrText
            font.pixelSize: 24
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
        Text {
            anchors.centerIn: parent
            text: modelData !== undefined ? modelData : ""
            color: clrText
            font.pixelSize: 24
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
