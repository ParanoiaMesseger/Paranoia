pragma Singleton
import QtQuick
import QtCore
import ParanoiaUiClient

QtObject {
    id: root

    property bool darkMode: _settings.darkMode

    function toggleTheme() {
        _settings.darkMode = !_settings.darkMode
    }

    property Settings _settings: Settings {
        category: "theme"
        property bool darkMode: true
    }

    // ── Backgrounds ──────────────────────────────────────
    readonly property color bgPrimary:   darkMode ? "#08070a" : "#F2E8DF"
    readonly property color bgSecondary: darkMode ? "#08070A" : "#EAD9CE"
    readonly property color bgDark:      darkMode ? "#020103" : "#DECABB"
    readonly property color bgInput:     darkMode ? "#10080B" : "#EAD9CE"
    readonly property color bgButton:    darkMode ? "#650710" : "#7D4535"
    readonly property color bgCard:      darkMode ? "#12080C" : "#E6D3C6"
    readonly property color errorBg:     darkMode ? "#2A070D" : "#F0D5CC"

    // ── Text ─────────────────────────────────────────────
    readonly property color textPrimary:   darkMode ? "#F7E8EA" : "#231209"
    readonly property color textSecondary: darkMode ? "#aa636c" : "#7A4A38"
    readonly property color textHint:      darkMode ? "#56323A" : "#B08570"
    readonly property color messageMetaOutgoing: darkMode ? "#F0C8CE" : "#F7E8EA"
    readonly property color messageMetaIncoming: darkMode ? "#C8929A" : "#6B4639"
    readonly property color controlText: darkMode ? "#F2D8DD" : "#3D2217"

    // ── Accent ───────────────────────────────────────────
    readonly property color accent:      "#C91122"
    readonly property color accentHover: "#FF2738"
    readonly property color accentDark:  "#650710"
    readonly property color accentDim:   darkMode ? "#4A060C" : "#E8CCC8"

    // ── Status ───────────────────────────────────────────
    readonly property color success: "#E3172A"
    readonly property color error:   "#FF2738"
    readonly property color warning: "#8F0B16"

    // ── Borders ──────────────────────────────────────────
    readonly property color separator: darkMode ? "#251015" : "#D4C0B2"
    readonly property color border:    darkMode ? "#3A1118" : "#C2A898"

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
