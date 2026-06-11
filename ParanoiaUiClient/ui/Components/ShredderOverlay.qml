import QtQuick

// Анимация удаления сообщения «шредер»: накрывает пузырь (sourceItem), снимает его
// в N вертикальных полосок (ShaderEffectSource по sourceRect-слайсам) и роняет их
// вниз с поворотом и затуханием — как бумага в шредере. Эмитит finished().
//
// Создаётся ПО ТРЕБОВАНИЮ через Loader (только для удаляемого сообщения), поэтому
// N одноразовых захватов (live:false) — без перф-нагрузки на остальные пузыри.
Item {
    id: root

    property Item sourceItem
    property int strips: 16
    property int duration: 720
    signal finished()

    // Размер берём от parent (Loader, заякоренный на пузырь) — внутри Loader якориться
    // к самому sourceItem нельзя (другой parent-chain). Захват полосок идёт по
    // sourceItem (см. ShaderEffectSource ниже).
    anchors.fill: parent
    z: 50

    property real progress: 0
    readonly property real slot: width / Math.max(1, strips)

    function frac(x) { return x - Math.floor(x) }
    function seedFor(i) { return frac(Math.sin((i + 1) * 12.9898) * 43758.5453) }

    Repeater {
        model: root.strips
        ShaderEffectSource {
            id: strip
            readonly property int idx: index
            readonly property real seed: root.seedFor(index)
            // Эффективный прогресс со стаггером слева-направо (как подача в шредер).
            readonly property real p: Math.max(0, Math.min(1,
                (root.progress - idx * 0.012) / (1 - root.strips * 0.012)))

            width: root.slot - 1.0          // 1px зазор между полосками = «разрез»
            height: root.height
            live: false                      // одноразовый захват
            smooth: true
            sourceItem: root.sourceItem
            sourceRect: Qt.rect(idx * root.slot, 0, root.slot, root.height)

            transformOrigin: Item.Center
            x: idx * root.slot + (seed - 0.5) * p * 12
            y: p * p * root.height * (2.0 + seed * 1.8)
            rotation: (idx % 2 === 0 ? 1 : -1) * p * (5 + seed * 18)
            opacity: Math.max(0, 1.0 - p * 1.2)
        }
    }

    // Захват live:false происходит на первом отрендеренном кадре. Даём кадр на
    // захват (полоски в p=0 точно накрывают пузырь — глитча не видно), затем прячем
    // оригинал и роняем полоски.
    Timer {
        id: captureTimer
        interval: 32
        onTriggered: {
            if (root.sourceItem) root.sourceItem.opacity = 0
            shredAnim.start()
        }
    }
    Component.onCompleted: captureTimer.start()

    NumberAnimation {
        id: shredAnim
        target: root
        property: "progress"
        from: 0; to: 1
        duration: root.duration
        easing.type: Easing.InQuad
        onStopped: root.finished()
    }
}
