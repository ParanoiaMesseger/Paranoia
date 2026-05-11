pragma Singleton
import QtQuick
import ParanoiaUiClient

QtObject {
    // ── Backgrounds ──────────────────────────────────────
    readonly property color bgPrimary:   "#08070a"
    readonly property color bgSecondary: "#08070A"
    readonly property color bgDark:      "#020103"
    readonly property color bgInput:     "#10080B"
    readonly property color bgButton:    "#650710"
    readonly property color bgCard:      "#12080C"
    readonly property color errorBg:     "#2A070D"

    // ── Text ─────────────────────────────────────────────
    readonly property color textPrimary:   "#F7E8EA"
    readonly property color textSecondary: "#aa636c"
    readonly property color textHint:      "#56323A"

    // ── Accent ───────────────────────────────────────────
    readonly property color accent:        "#C91122"
    readonly property color accentHover:   "#FF2738"
    readonly property color accentDark:    "#650710"
    readonly property color accentDim:     "#4A060C"

    // ── Status ───────────────────────────────────────────
    readonly property color success: "#E3172A"
    readonly property color error:   "#FF2738"
    readonly property color warning: "#8F0B16"

    // ── Borders ──────────────────────────────────────────
    readonly property color separator: "#251015"
    readonly property color border:    "#3A1118"

    // ── Radius ───────────────────────────────────────────
    readonly property int radiusSm: 3
    readonly property int radiusMd: 10
    readonly property int radiusLg: 10

    // ── Typography ───────────────────────────────────────
    readonly property int fontXs:    11
    readonly property int fontSm:    13
    readonly property int fontMd:    15
    readonly property int fontLg:    18
    readonly property int fontXl:    22
    readonly property string fontFamily: "Segoe UI"
    readonly property string monoFamily: "monospace"

}
