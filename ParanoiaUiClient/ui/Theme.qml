pragma Singleton
import QtQuick
import ParanoiaUiClient

QtObject {
    // ── Backgrounds ──────────────────────────────────────
    readonly property color bgPrimary:   "#17212B"
    readonly property color bgSecondary: "#232E3C"
    readonly property color bgDark:      "#0E1621"
    readonly property color bgInput:     "#1C2733"
    readonly property color bgButton:    "#2B5278"
    readonly property color bgCard:      "#1E2C3A"

    // ── Text ─────────────────────────────────────────────
    readonly property color textPrimary:   "#FFFFFF"
    readonly property color textSecondary: "#708499"
    readonly property color textHint:      "#3D5060"

    // ── Accent ───────────────────────────────────────────
    readonly property color accent:        "#2AABEE"
    readonly property color accentHover:   "#3DBCFF"
    readonly property color accentDark:    "#1A7AAF"

    // ── Status ───────────────────────────────────────────
    readonly property color success: "#4FAD5B"
    readonly property color error:   "#D56B70"
    readonly property color warning: "#D4904F"

    // ── Borders ──────────────────────────────────────────
    readonly property color separator: "#0D1823"
    readonly property color border:    "#273747"

    // ── Radius ───────────────────────────────────────────
    readonly property int radiusSm: 6
    readonly property int radiusMd: 10
    readonly property int radiusLg: 16

    // ── Typography ───────────────────────────────────────
    readonly property int fontXs:    11
    readonly property int fontSm:    13
    readonly property int fontMd:    15
    readonly property int fontLg:    18
    readonly property int fontXl:    22
    readonly property string fontFamily: "Segoe UI"
}
