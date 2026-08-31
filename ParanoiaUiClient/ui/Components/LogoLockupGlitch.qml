// Сгенерировано svgtoqml из logo_lockup_animated.svg + пост-обработка scripts/regen_glitch_logos.py
// (см. шапку скрипта; руками не править - перегенерировать).
import QtQuick
import QtQuick.VectorImage.Helpers
import QtQuick.Shapes

Item {
    implicitWidth: 1220
    implicitHeight: 260
    component AnimationsInfo : QtObject
    {
        property bool paused: false
        property int loops: 1
        signal restart()
    }
    property AnimationsInfo animations : AnimationsInfo {}
    transform: [
        Scale { xScale: width / 1220; yScale: height / 260 }
    ]
    id: _qt_node0
    Component.onCompleted: {
        _qt_node3_transform_base_group.activateOverride(_qt_node3_transform_group_0)
        _qt_node5_transform_base_group.activateOverride(_qt_node5_transform_group_0)
        _qt_node6_transform_base_group.activateOverride(_qt_node6_transform_group_0)
        _qt_node8_transform_base_group.activateOverride(_qt_node8_transform_group_0)
        _qt_node9_transform_base_group.activateOverride(_qt_node9_transform_group_0)
        _qt_node10_transform_base_group.activateOverride(_qt_node10_transform_group_0)
        _qt_node11_transform_base_group.activateOverride(_qt_node11_transform_group_0)
        _qt_node12_transform_base_group.activateOverride(_qt_node12_transform_group_0)
        _qt_node14_transform_base_group.activateOverride(_qt_node14_transform_group_0)
        _qt_node15_transform_base_group.activateOverride(_qt_node15_transform_group_0)
        _qt_node16_transform_base_group.activateOverride(_qt_node16_transform_group_0)
        _qt_node17_transform_base_group.activateOverride(_qt_node17_transform_group_0)
        _qt_node19_transform_base_group.activateOverride(_qt_node19_transform_group_0)
        _qt_node30_transform_base_group.activateOverride(_qt_node30_transform_group_0)
        _qt_node31_transform_base_group.activateOverride(_qt_node31_transform_group_0)
        _qt_node32_transform_base_group.activateOverride(_qt_node32_transform_group_0)
        _qt_node33_transform_base_group.activateOverride(_qt_node33_transform_group_0)
        _qt_node34_transform_base_group.activateOverride(_qt_node34_transform_group_0)
    }
    Shape {
        objectName: "combined-lockup-field"
        id: _qt_node1
        preferredRendererType: Shape.CurveRenderer
    }
    Item { // Structure node
        id: _qt_node2
        transform: TransformGroup {
            id: _qt_node2_transform_base_group
            Matrix4x4 { matrix: PlanarTransform.fromAffineMatrix(0.86, 0, 0, 0.86, 46, 14)}
        }
        Item { // Structure node
            objectName: "symbol-motion-shell"
            id: _qt_node3
            transform: TransformGroup {
                id: _qt_node3_transform_base_group
                TransformGroup {
                    id: _qt_node3_transform_group_0
                    Translate { id: _qt_node3_transform_0_0 }
                }
            }
            Connections { target: _qt_node0.animations; function onRestart() {_qt_node3_transform_animation.restart() } }
            ParallelAnimation {
                id:_qt_node3_transform_animation
                loops: _qt_node0.animations.loops
                paused: _qt_node0.animations.paused
                running: true
                onLoopsChanged: { if (running) { restart() } }
                SequentialAnimation {
                    loops: Animation.Infinite
                    ParallelAnimation {
                        SequentialAnimation {
                            ParallelAnimation {
                                PropertyAction { target: _qt_node3_transform_0_0; property: "x"; value: 0 }
                                PropertyAction { target: _qt_node3_transform_0_0; property: "y"; value: 0 }
                            }
                            ParallelAnimation {
                                PropertyAnimation {
                                    duration: 1440
                                    target: _qt_node3_transform_0_0
                                    property: "x"
                                    to: 3
                                }
                                PropertyAnimation {
                                    duration: 1440
                                    target: _qt_node3_transform_0_0
                                    property: "y"
                                    to: -1
                                }
                            }
                            ParallelAnimation {
                                PropertyAnimation {
                                    duration: 1440
                                    target: _qt_node3_transform_0_0
                                    property: "x"
                                    to: -4
                                }
                                PropertyAnimation {
                                    duration: 1440
                                    target: _qt_node3_transform_0_0
                                    property: "y"
                                    to: 2
                                }
                            }
                            ParallelAnimation {
                                PropertyAnimation {
                                    duration: 1440
                                    target: _qt_node3_transform_0_0
                                    property: "x"
                                    to: 2
                                }
                                PropertyAnimation {
                                    duration: 1440
                                    target: _qt_node3_transform_0_0
                                    property: "y"
                                    to: 0
                                }
                            }
                            ParallelAnimation {
                                PropertyAnimation {
                                    duration: 1440
                                    target: _qt_node3_transform_0_0
                                    property: "x"
                                    to: 0
                                }
                                PropertyAnimation {
                                    duration: 1440
                                    target: _qt_node3_transform_0_0
                                    property: "y"
                                    to: 0
                                }
                            }
                            PauseAnimation { duration: 1440 }
                        }
                    }
                }
            }
            Item { // Structure node
                objectName: "symbol-memory-wipe"
                id: _qt_node4
                Shape {
                    preferredRendererType: Shape.CurveRenderer
                    objectName: "motion-split-left"
                    id: _qt_node5
                    transform: TransformGroup {
                        id: _qt_node5_transform_base_group
                        TransformGroup {
                            id: _qt_node5_transform_group_0
                            Translate { id: _qt_node5_transform_0_0 }
                        }
                    }
                    Connections { target: _qt_node0.animations; function onRestart() {_qt_node5_transform_animation.restart() } }
                    ParallelAnimation {
                        id:_qt_node5_transform_animation
                        loops: _qt_node0.animations.loops
                        paused: _qt_node0.animations.paused
                        running: true
                        onLoopsChanged: { if (running) { restart() } }
                        SequentialAnimation {
                            loops: Animation.Infinite
                            ParallelAnimation {
                                SequentialAnimation {
                                    ParallelAnimation {
                                        PropertyAction { target: _qt_node5_transform_0_0; property: "x"; value: 0 }
                                        PropertyAction { target: _qt_node5_transform_0_0; property: "y"; value: 0 }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 900
                                            target: _qt_node5_transform_0_0
                                            property: "x"
                                            to: -10
                                        }
                                        PropertyAnimation {
                                            duration: 900
                                            target: _qt_node5_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 900
                                            target: _qt_node5_transform_0_0
                                            property: "x"
                                            to: -35
                                        }
                                        PropertyAnimation {
                                            duration: 900
                                            target: _qt_node5_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 900
                                            target: _qt_node5_transform_0_0
                                            property: "x"
                                            to: -65
                                        }
                                        PropertyAnimation {
                                            duration: 900
                                            target: _qt_node5_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 900
                                            target: _qt_node5_transform_0_0
                                            property: "x"
                                            to: -90
                                        }
                                        PropertyAnimation {
                                            duration: 900
                                            target: _qt_node5_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 900
                                            target: _qt_node5_transform_0_0
                                            property: "x"
                                            to: -45
                                        }
                                        PropertyAnimation {
                                            duration: 900
                                            target: _qt_node5_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 900
                                            target: _qt_node5_transform_0_0
                                            property: "x"
                                            to: -15
                                        }
                                        PropertyAnimation {
                                            duration: 900
                                            target: _qt_node5_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 900
                                            target: _qt_node5_transform_0_0
                                            property: "x"
                                            to: 0
                                        }
                                        PropertyAnimation {
                                            duration: 900
                                            target: _qt_node5_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                    PauseAnimation { duration: 900 }
                                }
                            }
                        }
                    }
                    ShapePath {
                        id: _qt_shapePath_0
                        objectName: "svg_path:symbol-left-upper-facet"
                        strokeColor: "transparent"
                        fillColor: "#ff8f0b16"
                        fillRule: ShapePath.WindingFill
                        pathHints: ShapePath.PathQuadratic | ShapePath.PathNonIntersecting | ShapePath.PathNonOverlappingControlPointTriangles
                        PathSvg { path: "M 36 86 L 110 38 L 128 84 L 91 113 L 37 110 L 36 86 " }
                    }
                    ShapePath {
                        id: _qt_shapePath_1
                        objectName: "svg_path:symbol-left-middle-facet"
                        strokeColor: "transparent"
                        fillColor: "#ffc91122"
                        fillRule: ShapePath.WindingFill
                        pathHints: ShapePath.PathQuadratic | ShapePath.PathNonIntersecting | ShapePath.PathNonOverlappingControlPointTriangles
                        PathSvg { path: "M 37 110 L 91 113 L 121 138 L 82 181 L 29 153 L 56 132 L 37 110 " }
                    }
                    ShapePath {
                        id: _qt_shapePath_2
                        objectName: "svg_path:symbol-left-lower-facet"
                        strokeColor: "transparent"
                        fillColor: "#ff650710"
                        fillRule: ShapePath.WindingFill
                        pathHints: ShapePath.PathQuadratic | ShapePath.PathNonIntersecting | ShapePath.PathNonOverlappingControlPointTriangles
                        PathSvg { path: "M 29 153 L 82 181 L 121 190 L 99 219 L 29 153 " }
                    }
                }
                Shape {
                    preferredRendererType: Shape.CurveRenderer
                    objectName: "motion-split-right"
                    id: _qt_node6
                    transform: TransformGroup {
                        id: _qt_node6_transform_base_group
                        TransformGroup {
                            id: _qt_node6_transform_group_0
                            Translate { id: _qt_node6_transform_0_0 }
                        }
                    }
                    Connections { target: _qt_node0.animations; function onRestart() {_qt_node6_transform_animation.restart() } }
                    ParallelAnimation {
                        id:_qt_node6_transform_animation
                        loops: _qt_node0.animations.loops
                        paused: _qt_node0.animations.paused
                        running: true
                        onLoopsChanged: { if (running) { restart() } }
                        SequentialAnimation {
                            loops: Animation.Infinite
                            ParallelAnimation {
                                SequentialAnimation {
                                    ParallelAnimation {
                                        PropertyAction { target: _qt_node6_transform_0_0; property: "x"; value: 0 }
                                        PropertyAction { target: _qt_node6_transform_0_0; property: "y"; value: 0 }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 900
                                            target: _qt_node6_transform_0_0
                                            property: "x"
                                            to: 12
                                        }
                                        PropertyAnimation {
                                            duration: 900
                                            target: _qt_node6_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 900
                                            target: _qt_node6_transform_0_0
                                            property: "x"
                                            to: 40
                                        }
                                        PropertyAnimation {
                                            duration: 900
                                            target: _qt_node6_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 900
                                            target: _qt_node6_transform_0_0
                                            property: "x"
                                            to: 75
                                        }
                                        PropertyAnimation {
                                            duration: 900
                                            target: _qt_node6_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 900
                                            target: _qt_node6_transform_0_0
                                            property: "x"
                                            to: 105
                                        }
                                        PropertyAnimation {
                                            duration: 900
                                            target: _qt_node6_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 900
                                            target: _qt_node6_transform_0_0
                                            property: "x"
                                            to: 52
                                        }
                                        PropertyAnimation {
                                            duration: 900
                                            target: _qt_node6_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 900
                                            target: _qt_node6_transform_0_0
                                            property: "x"
                                            to: 18
                                        }
                                        PropertyAnimation {
                                            duration: 900
                                            target: _qt_node6_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 900
                                            target: _qt_node6_transform_0_0
                                            property: "x"
                                            to: 0
                                        }
                                        PropertyAnimation {
                                            duration: 900
                                            target: _qt_node6_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                    PauseAnimation { duration: 900 }
                                }
                            }
                        }
                    }
                    ShapePath {
                        id: _qt_shapePath_3
                        objectName: "svg_path:symbol-top-right-facet"
                        strokeColor: "transparent"
                        fillColor: "#ffc91122"
                        fillRule: ShapePath.WindingFill
                        pathHints: ShapePath.PathQuadratic | ShapePath.PathNonIntersecting | ShapePath.PathNonOverlappingControlPointTriangles
                        PathSvg { path: "M 110 38 L 153 26 L 202 66 L 128 84 L 110 38 " }
                    }
                    ShapePath {
                        id: _qt_shapePath_4
                        objectName: "svg_path:symbol-right-middle-facet"
                        strokeColor: "transparent"
                        fillColor: "#ff8f0b16"
                        fillRule: ShapePath.WindingFill
                        pathHints: ShapePath.PathQuadratic | ShapePath.PathNonIntersecting | ShapePath.PathNonOverlappingControlPointTriangles
                        PathSvg { path: "M 128 84 L 202 66 L 224 121 L 174 142 L 136 119 L 128 84 " }
                    }
                    ShapePath {
                        id: _qt_shapePath_5
                        objectName: "svg_path:symbol-right-lower-facet"
                        strokeColor: "transparent"
                        fillColor: "#ffc91122"
                        fillRule: ShapePath.WindingFill
                        pathHints: ShapePath.PathQuadratic | ShapePath.PathNonIntersecting | ShapePath.PathNonOverlappingControlPointTriangles
                        PathSvg { path: "M 121 138 L 174 142 L 211 187 L 141 226 L 121 190 L 121 138 " }
                    }
                }
                Item { // Structure node
                    objectName: "motion-signal-tear"
                    id: _qt_node7
                    opacity: 0.86
                    Shape {
                        objectName: "symbol-tear-left"
                        id: _qt_node8
                        transform: TransformGroup {
                            id: _qt_node8_transform_base_group
                            TransformGroup {
                                id: _qt_node8_transform_group_0
                                Translate { id: _qt_node8_transform_0_0 }
                            }
                        }
                        Connections { target: _qt_node0.animations; function onRestart() {_qt_node8_transform_animation.restart() } }
                        ParallelAnimation {
                            id:_qt_node8_transform_animation
                            loops: _qt_node0.animations.loops
                            paused: _qt_node0.animations.paused
                            running: true
                            onLoopsChanged: { if (running) { restart() } }
                            SequentialAnimation {
                                loops: Animation.Infinite
                                ParallelAnimation {
                                    SequentialAnimation {
                                        ParallelAnimation {
                                            PropertyAction { target: _qt_node8_transform_0_0; property: "x"; value: 0 }
                                            PropertyAction { target: _qt_node8_transform_0_0; property: "y"; value: 0 }
                                        }
                                        ParallelAnimation {
                                            PropertyAnimation {
                                                duration: 588
                                                target: _qt_node8_transform_0_0
                                                property: "x"
                                                to: -16
                                            }
                                            PropertyAnimation {
                                                duration: 588
                                                target: _qt_node8_transform_0_0
                                                property: "y"
                                                to: 0
                                            }
                                        }
                                        ParallelAnimation {
                                            PropertyAnimation {
                                                duration: 587
                                                target: _qt_node8_transform_0_0
                                                property: "x"
                                                to: 11
                                            }
                                            PropertyAnimation {
                                                duration: 587
                                                target: _qt_node8_transform_0_0
                                                property: "y"
                                                to: 0
                                            }
                                        }
                                        ParallelAnimation {
                                            PropertyAnimation {
                                                duration: 588
                                                target: _qt_node8_transform_0_0
                                                property: "x"
                                                to: -5
                                            }
                                            PropertyAnimation {
                                                duration: 588
                                                target: _qt_node8_transform_0_0
                                                property: "y"
                                                to: 0
                                            }
                                        }
                                        ParallelAnimation {
                                            PropertyAnimation {
                                                duration: 587
                                                target: _qt_node8_transform_0_0
                                                property: "x"
                                                to: 0
                                            }
                                            PropertyAnimation {
                                                duration: 587
                                                target: _qt_node8_transform_0_0
                                                property: "y"
                                                to: 0
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        preferredRendererType: Shape.CurveRenderer
                        ShapePath {
                            id: _qt_shapePath_6
                            objectName: "svg_path:symbol-tear-left"
                            strokeColor: "transparent"
                            fillColor: "#ffff2738"
                            fillRule: ShapePath.WindingFill
                            pathHints: ShapePath.PathQuadratic | ShapePath.PathNonIntersecting | ShapePath.PathNonOverlappingControlPointTriangles
                            PathSvg { path: "M 18 95 L 46 95 L 46 105 L 18 105 L 18 95 " }
                        }
                    }
                    Shape {
                        objectName: "symbol-tear-right"
                        id: _qt_node9
                        transform: TransformGroup {
                            id: _qt_node9_transform_base_group
                            TransformGroup {
                                id: _qt_node9_transform_group_0
                                Translate { id: _qt_node9_transform_0_0 }
                            }
                        }
                        Connections { target: _qt_node0.animations; function onRestart() {_qt_node9_transform_animation.restart() } }
                        ParallelAnimation {
                            id:_qt_node9_transform_animation
                            loops: _qt_node0.animations.loops
                            paused: _qt_node0.animations.paused
                            running: true
                            onLoopsChanged: { if (running) { restart() } }
                            SequentialAnimation {
                                loops: Animation.Infinite
                                ParallelAnimation {
                                    SequentialAnimation {
                                        ParallelAnimation {
                                            PropertyAction { target: _qt_node9_transform_0_0; property: "x"; value: 0 }
                                            PropertyAction { target: _qt_node9_transform_0_0; property: "y"; value: 0 }
                                        }
                                        ParallelAnimation {
                                            PropertyAnimation {
                                                duration: 588
                                                target: _qt_node9_transform_0_0
                                                property: "x"
                                                to: 20
                                            }
                                            PropertyAnimation {
                                                duration: 588
                                                target: _qt_node9_transform_0_0
                                                property: "y"
                                                to: 0
                                            }
                                        }
                                        ParallelAnimation {
                                            PropertyAnimation {
                                                duration: 587
                                                target: _qt_node9_transform_0_0
                                                property: "x"
                                                to: -12
                                            }
                                            PropertyAnimation {
                                                duration: 587
                                                target: _qt_node9_transform_0_0
                                                property: "y"
                                                to: 0
                                            }
                                        }
                                        ParallelAnimation {
                                            PropertyAnimation {
                                                duration: 588
                                                target: _qt_node9_transform_0_0
                                                property: "x"
                                                to: 7
                                            }
                                            PropertyAnimation {
                                                duration: 588
                                                target: _qt_node9_transform_0_0
                                                property: "y"
                                                to: 0
                                            }
                                        }
                                        ParallelAnimation {
                                            PropertyAnimation {
                                                duration: 587
                                                target: _qt_node9_transform_0_0
                                                property: "x"
                                                to: 0
                                            }
                                            PropertyAnimation {
                                                duration: 587
                                                target: _qt_node9_transform_0_0
                                                property: "y"
                                                to: 0
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        preferredRendererType: Shape.CurveRenderer
                        ShapePath {
                            id: _qt_shapePath_7
                            objectName: "svg_path:symbol-tear-right"
                            strokeColor: "transparent"
                            fillColor: "#ffff2738"
                            fillRule: ShapePath.WindingFill
                            pathHints: ShapePath.PathQuadratic | ShapePath.PathNonIntersecting | ShapePath.PathNonOverlappingControlPointTriangles
                            PathSvg { path: "M 205 147 L 238 147 L 238 156 L 205 156 L 205 147 " }
                        }
                    }
                    Shape {
                        objectName: "symbol-tear-lower"
                        id: _qt_node10
                        transform: TransformGroup {
                            id: _qt_node10_transform_base_group
                            TransformGroup {
                                id: _qt_node10_transform_group_0
                                Translate { id: _qt_node10_transform_0_0 }
                            }
                        }
                        Connections { target: _qt_node0.animations; function onRestart() {_qt_node10_transform_animation.restart() } }
                        ParallelAnimation {
                            id:_qt_node10_transform_animation
                            loops: _qt_node0.animations.loops
                            paused: _qt_node0.animations.paused
                            running: true
                            onLoopsChanged: { if (running) { restart() } }
                            SequentialAnimation {
                                loops: Animation.Infinite
                                ParallelAnimation {
                                    SequentialAnimation {
                                        ParallelAnimation {
                                            PropertyAction { target: _qt_node10_transform_0_0; property: "x"; value: 0 }
                                            PropertyAction { target: _qt_node10_transform_0_0; property: "y"; value: 0 }
                                        }
                                        ParallelAnimation {
                                            PropertyAnimation {
                                                duration: 588
                                                target: _qt_node10_transform_0_0
                                                property: "x"
                                                to: -10
                                            }
                                            PropertyAnimation {
                                                duration: 588
                                                target: _qt_node10_transform_0_0
                                                property: "y"
                                                to: 0
                                            }
                                        }
                                        ParallelAnimation {
                                            PropertyAnimation {
                                                duration: 587
                                                target: _qt_node10_transform_0_0
                                                property: "x"
                                                to: 15
                                            }
                                            PropertyAnimation {
                                                duration: 587
                                                target: _qt_node10_transform_0_0
                                                property: "y"
                                                to: 0
                                            }
                                        }
                                        ParallelAnimation {
                                            PropertyAnimation {
                                                duration: 588
                                                target: _qt_node10_transform_0_0
                                                property: "x"
                                                to: 4
                                            }
                                            PropertyAnimation {
                                                duration: 588
                                                target: _qt_node10_transform_0_0
                                                property: "y"
                                                to: 0
                                            }
                                        }
                                        ParallelAnimation {
                                            PropertyAnimation {
                                                duration: 587
                                                target: _qt_node10_transform_0_0
                                                property: "x"
                                                to: 0
                                            }
                                            PropertyAnimation {
                                                duration: 587
                                                target: _qt_node10_transform_0_0
                                                property: "y"
                                                to: 0
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        preferredRendererType: Shape.CurveRenderer
                        ShapePath {
                            id: _qt_shapePath_8
                            objectName: "svg_path:symbol-tear-lower"
                            strokeColor: "transparent"
                            fillColor: "#ff8f0b16"
                            fillRule: ShapePath.WindingFill
                            pathHints: ShapePath.PathQuadratic | ShapePath.PathNonIntersecting | ShapePath.PathNonOverlappingControlPointTriangles
                            PathSvg { path: "M 53 203 L 85 203 L 85 210 L 53 210 L 53 203 " }
                        }
                    }
                }
                Shape {
                    preferredRendererType: Shape.CurveRenderer
                    objectName: "motion-jitter-fragments"
                    id: _qt_node11
                    opacity: 0.66
                    transform: TransformGroup {
                        id: _qt_node11_transform_base_group
                        TransformGroup {
                            id: _qt_node11_transform_group_0
                            Translate { id: _qt_node11_transform_0_0 }
                        }
                    }
                    Connections { target: _qt_node0.animations; function onRestart() {_qt_node11_transform_animation.restart() } }
                    ParallelAnimation {
                        id:_qt_node11_transform_animation
                        loops: _qt_node0.animations.loops
                        paused: _qt_node0.animations.paused
                        running: true
                        onLoopsChanged: { if (running) { restart() } }
                        SequentialAnimation {
                            loops: Animation.Infinite
                            ParallelAnimation {
                                SequentialAnimation {
                                    ParallelAnimation {
                                        PropertyAction { target: _qt_node11_transform_0_0; property: "x"; value: 0 }
                                        PropertyAction { target: _qt_node11_transform_0_0; property: "y"; value: 0 }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 220
                                            target: _qt_node11_transform_0_0
                                            property: "x"
                                            to: 12
                                        }
                                        PropertyAnimation {
                                            duration: 220
                                            target: _qt_node11_transform_0_0
                                            property: "y"
                                            to: -3
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 220
                                            target: _qt_node11_transform_0_0
                                            property: "x"
                                            to: -9
                                        }
                                        PropertyAnimation {
                                            duration: 220
                                            target: _qt_node11_transform_0_0
                                            property: "y"
                                            to: 2
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 220
                                            target: _qt_node11_transform_0_0
                                            property: "x"
                                            to: 4
                                        }
                                        PropertyAnimation {
                                            duration: 220
                                            target: _qt_node11_transform_0_0
                                            property: "y"
                                            to: 1
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 220
                                            target: _qt_node11_transform_0_0
                                            property: "x"
                                            to: 0
                                        }
                                        PropertyAnimation {
                                            duration: 220
                                            target: _qt_node11_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                    PauseAnimation { duration: 220 }
                                }
                            }
                        }
                    }
                    ShapePath {
                        id: _qt_shapePath_9
                        objectName: "svg_path:symbol-jitter-top"
                        strokeColor: "transparent"
                        fillColor: "#ff4a060c"
                        fillRule: ShapePath.WindingFill
                        pathHints: ShapePath.PathQuadratic | ShapePath.PathNonIntersecting | ShapePath.PathNonOverlappingControlPointTriangles
                        PathSvg { path: "M 189 38 L 210 38 L 210 45 L 189 45 L 189 38 " }
                    }
                    ShapePath {
                        id: _qt_shapePath_10
                        objectName: "svg_path:symbol-jitter-left"
                        strokeColor: "transparent"
                        fillColor: "#ff4a060c"
                        fillRule: ShapePath.WindingFill
                        pathHints: ShapePath.PathQuadratic | ShapePath.PathNonIntersecting | ShapePath.PathNonOverlappingControlPointTriangles
                        PathSvg { path: "M 12 129 L 35 129 L 35 136 L 12 136 L 12 129 " }
                    }
                    ShapePath {
                        id: _qt_shapePath_11
                        objectName: "svg_path:symbol-jitter-bottom"
                        strokeColor: "transparent"
                        fillColor: "#ff4a060c"
                        fillRule: ShapePath.WindingFill
                        pathHints: ShapePath.PathQuadratic | ShapePath.PathNonIntersecting | ShapePath.PathNonOverlappingControlPointTriangles
                        PathSvg { path: "M 153 220 L 183 220 L 183 227 L 153 227 L 153 220 " }
                    }
                }
                Shape {
                    preferredRendererType: Shape.CurveRenderer
                    objectName: "motion-digital-collapse"
                    id: _qt_node12
                    transform: TransformGroup {
                        id: _qt_node12_transform_base_group
                        TransformGroup {
                            id: _qt_node12_transform_group_0
                            Translate { id: _qt_node12_transform_0_0 }
                        }
                    }
                    Connections { target: _qt_node0.animations; function onRestart() {_qt_node12_transform_animation.restart() } }
                    ParallelAnimation {
                        id:_qt_node12_transform_animation
                        loops: _qt_node0.animations.loops
                        paused: _qt_node0.animations.paused
                        running: true
                        onLoopsChanged: { if (running) { restart() } }
                        SequentialAnimation {
                            loops: Animation.Infinite
                            ParallelAnimation {
                                SequentialAnimation {
                                    ParallelAnimation {
                                        PropertyAction { target: _qt_node12_transform_0_0; property: "x"; value: 0 }
                                        PropertyAction { target: _qt_node12_transform_0_0; property: "y"; value: 0 }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 1440
                                            target: _qt_node12_transform_0_0
                                            property: "x"
                                            to: 9
                                        }
                                        PropertyAnimation {
                                            duration: 1440
                                            target: _qt_node12_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 1440
                                            target: _qt_node12_transform_0_0
                                            property: "x"
                                            to: -7
                                        }
                                        PropertyAnimation {
                                            duration: 1440
                                            target: _qt_node12_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 1440
                                            target: _qt_node12_transform_0_0
                                            property: "x"
                                            to: 3
                                        }
                                        PropertyAnimation {
                                            duration: 1440
                                            target: _qt_node12_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 1440
                                            target: _qt_node12_transform_0_0
                                            property: "x"
                                            to: 0
                                        }
                                        PropertyAnimation {
                                            duration: 1440
                                            target: _qt_node12_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                    PauseAnimation { duration: 1440 }
                                }
                            }
                        }
                    }
                    ShapePath {
                        id: _qt_shapePath_12
                        objectName: "svg_path:symbol-collapse-cut-a"
                        strokeColor: "transparent"
                        fillColor: "#ff050406"
                        fillRule: ShapePath.WindingFill
                        pathHints: ShapePath.PathQuadratic | ShapePath.PathNonIntersecting | ShapePath.PathNonOverlappingControlPointTriangles
                        PathSvg { path: "M 71 132 L 118 132 L 118 141 L 65 141 L 71 132 " }
                    }
                    ShapePath {
                        id: _qt_shapePath_13
                        objectName: "svg_path:symbol-collapse-cut-b"
                        strokeColor: "transparent"
                        fillColor: "#ff050406"
                        fillRule: ShapePath.WindingFill
                        pathHints: ShapePath.PathQuadratic | ShapePath.PathNonIntersecting | ShapePath.PathNonOverlappingControlPointTriangles
                        PathSvg { path: "M 148 84 L 198 84 L 190 93 L 151 93 L 148 84 " }
                    }
                }
            }
            Item { // Structure node
                objectName: "symbol-memory-shards"
                id: _qt_node13
                opacity: 0
                Shape {
                    objectName: "memory-shard-a"
                    id: _qt_node14
                    transform: TransformGroup {
                        id: _qt_node14_transform_base_group
                        TransformGroup {
                            id: _qt_node14_transform_group_0
                            Translate { id: _qt_node14_transform_0_0 }
                        }
                    }
                    Connections { target: _qt_node0.animations; function onRestart() {_qt_node14_transform_animation.restart() } }
                    ParallelAnimation {
                        id:_qt_node14_transform_animation
                        loops: _qt_node0.animations.loops
                        paused: _qt_node0.animations.paused
                        running: true
                        onLoopsChanged: { if (running) { restart() } }
                        SequentialAnimation {
                            loops: Animation.Infinite
                            ParallelAnimation {
                                SequentialAnimation {
                                    ParallelAnimation {
                                        PropertyAction { target: _qt_node14_transform_0_0; property: "x"; value: 0 }
                                        PropertyAction { target: _qt_node14_transform_0_0; property: "y"; value: 0 }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node14_transform_0_0
                                            property: "x"
                                            to: -18
                                        }
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node14_transform_0_0
                                            property: "y"
                                            to: -2
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node14_transform_0_0
                                            property: "x"
                                            to: 26
                                        }
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node14_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node14_transform_0_0
                                            property: "x"
                                            to: -42
                                        }
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node14_transform_0_0
                                            property: "y"
                                            to: -1
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node14_transform_0_0
                                            property: "x"
                                            to: 58
                                        }
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node14_transform_0_0
                                            property: "y"
                                            to: 1
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node14_transform_0_0
                                            property: "x"
                                            to: -24
                                        }
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node14_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node14_transform_0_0
                                            property: "x"
                                            to: 0
                                        }
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node14_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                }
                            }
                        }
                    }
                    preferredRendererType: Shape.CurveRenderer
                    ShapePath {
                        id: _qt_shapePath_14
                        objectName: "svg_path:memory-shard-a"
                        strokeColor: "transparent"
                        fillColor: "#ffff2738"
                        fillRule: ShapePath.WindingFill
                        pathHints: ShapePath.PathQuadratic | ShapePath.PathNonIntersecting | ShapePath.PathNonOverlappingControlPointTriangles
                        PathSvg { path: "M 36 73 L 192 73 L 192 81 L 36 81 L 36 73 " }
                    }
                }
                Shape {
                    objectName: "memory-shard-b"
                    id: _qt_node15
                    transform: TransformGroup {
                        id: _qt_node15_transform_base_group
                        TransformGroup {
                            id: _qt_node15_transform_group_0
                            Translate { id: _qt_node15_transform_0_0 }
                        }
                    }
                    Connections { target: _qt_node0.animations; function onRestart() {_qt_node15_transform_animation.restart() } }
                    ParallelAnimation {
                        id:_qt_node15_transform_animation
                        loops: _qt_node0.animations.loops
                        paused: _qt_node0.animations.paused
                        running: true
                        onLoopsChanged: { if (running) { restart() } }
                        SequentialAnimation {
                            loops: Animation.Infinite
                            ParallelAnimation {
                                SequentialAnimation {
                                    ParallelAnimation {
                                        PropertyAction { target: _qt_node15_transform_0_0; property: "x"; value: 0 }
                                        PropertyAction { target: _qt_node15_transform_0_0; property: "y"; value: 0 }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node15_transform_0_0
                                            property: "x"
                                            to: 22
                                        }
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node15_transform_0_0
                                            property: "y"
                                            to: 1
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node15_transform_0_0
                                            property: "x"
                                            to: -31
                                        }
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node15_transform_0_0
                                            property: "y"
                                            to: -1
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node15_transform_0_0
                                            property: "x"
                                            to: 46
                                        }
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node15_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node15_transform_0_0
                                            property: "x"
                                            to: -54
                                        }
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node15_transform_0_0
                                            property: "y"
                                            to: 2
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node15_transform_0_0
                                            property: "x"
                                            to: 18
                                        }
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node15_transform_0_0
                                            property: "y"
                                            to: -1
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node15_transform_0_0
                                            property: "x"
                                            to: 0
                                        }
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node15_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                }
                            }
                        }
                    }
                    preferredRendererType: Shape.CurveRenderer
                    ShapePath {
                        id: _qt_shapePath_15
                        objectName: "svg_path:memory-shard-b"
                        strokeColor: "transparent"
                        fillColor: "#ff8f0b16"
                        fillRule: ShapePath.WindingFill
                        pathHints: ShapePath.PathQuadratic | ShapePath.PathNonIntersecting | ShapePath.PathNonOverlappingControlPointTriangles
                        PathSvg { path: "M 18 116 L 216 116 L 216 123 L 18 123 L 18 116 " }
                    }
                }
                Shape {
                    objectName: "memory-shard-c"
                    id: _qt_node16
                    transform: TransformGroup {
                        id: _qt_node16_transform_base_group
                        TransformGroup {
                            id: _qt_node16_transform_group_0
                            Translate { id: _qt_node16_transform_0_0 }
                        }
                    }
                    Connections { target: _qt_node0.animations; function onRestart() {_qt_node16_transform_animation.restart() } }
                    ParallelAnimation {
                        id:_qt_node16_transform_animation
                        loops: _qt_node0.animations.loops
                        paused: _qt_node0.animations.paused
                        running: true
                        onLoopsChanged: { if (running) { restart() } }
                        SequentialAnimation {
                            loops: Animation.Infinite
                            ParallelAnimation {
                                SequentialAnimation {
                                    ParallelAnimation {
                                        PropertyAction { target: _qt_node16_transform_0_0; property: "x"; value: 0 }
                                        PropertyAction { target: _qt_node16_transform_0_0; property: "y"; value: 0 }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node16_transform_0_0
                                            property: "x"
                                            to: -12
                                        }
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node16_transform_0_0
                                            property: "y"
                                            to: 2
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node16_transform_0_0
                                            property: "x"
                                            to: 38
                                        }
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node16_transform_0_0
                                            property: "y"
                                            to: -2
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node16_transform_0_0
                                            property: "x"
                                            to: -34
                                        }
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node16_transform_0_0
                                            property: "y"
                                            to: 1
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node16_transform_0_0
                                            property: "x"
                                            to: 62
                                        }
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node16_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node16_transform_0_0
                                            property: "x"
                                            to: -28
                                        }
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node16_transform_0_0
                                            property: "y"
                                            to: 1
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node16_transform_0_0
                                            property: "x"
                                            to: 0
                                        }
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node16_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                }
                            }
                        }
                    }
                    preferredRendererType: Shape.CurveRenderer
                    ShapePath {
                        id: _qt_shapePath_16
                        objectName: "svg_path:memory-shard-c"
                        strokeColor: "transparent"
                        fillColor: "#ffc91122"
                        fillRule: ShapePath.WindingFill
                        pathHints: ShapePath.PathQuadratic | ShapePath.PathNonIntersecting | ShapePath.PathNonOverlappingControlPointTriangles
                        PathSvg { path: "M 54 154 L 222 154 L 222 162 L 54 162 L 54 154 " }
                    }
                }
                Shape {
                    objectName: "memory-shard-d"
                    id: _qt_node17
                    transform: TransformGroup {
                        id: _qt_node17_transform_base_group
                        TransformGroup {
                            id: _qt_node17_transform_group_0
                            Translate { id: _qt_node17_transform_0_0 }
                        }
                    }
                    Connections { target: _qt_node0.animations; function onRestart() {_qt_node17_transform_animation.restart() } }
                    ParallelAnimation {
                        id:_qt_node17_transform_animation
                        loops: _qt_node0.animations.loops
                        paused: _qt_node0.animations.paused
                        running: true
                        onLoopsChanged: { if (running) { restart() } }
                        SequentialAnimation {
                            loops: Animation.Infinite
                            ParallelAnimation {
                                SequentialAnimation {
                                    ParallelAnimation {
                                        PropertyAction { target: _qt_node17_transform_0_0; property: "x"; value: 0 }
                                        PropertyAction { target: _qt_node17_transform_0_0; property: "y"; value: 0 }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node17_transform_0_0
                                            property: "x"
                                            to: 30
                                        }
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node17_transform_0_0
                                            property: "y"
                                            to: -1
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node17_transform_0_0
                                            property: "x"
                                            to: -26
                                        }
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node17_transform_0_0
                                            property: "y"
                                            to: 1
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node17_transform_0_0
                                            property: "x"
                                            to: 52
                                        }
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node17_transform_0_0
                                            property: "y"
                                            to: -2
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node17_transform_0_0
                                            property: "x"
                                            to: -60
                                        }
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node17_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node17_transform_0_0
                                            property: "x"
                                            to: 22
                                        }
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node17_transform_0_0
                                            property: "y"
                                            to: 1
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node17_transform_0_0
                                            property: "x"
                                            to: 0
                                        }
                                        PropertyAnimation {
                                            duration: 1200
                                            target: _qt_node17_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                }
                            }
                        }
                    }
                    preferredRendererType: Shape.CurveRenderer
                    ShapePath {
                        id: _qt_shapePath_17
                        objectName: "svg_path:memory-shard-d"
                        strokeColor: "transparent"
                        fillColor: "#ff4a060c"
                        fillRule: ShapePath.WindingFill
                        pathHints: ShapePath.PathQuadratic | ShapePath.PathNonIntersecting | ShapePath.PathNonOverlappingControlPointTriangles
                        PathSvg { path: "M 74 197 L 186 197 L 186 204 L 74 204 L 74 197 " }
                    }
                }
            }
        }
    }
    Item { // Structure node
        id: _qt_node18
        transform: TransformGroup {
            id: _qt_node18_transform_base_group
            Matrix4x4 { matrix: PlanarTransform.fromAffineMatrix(1.26, 0, 0, 1.26, 340, 71)}
        }
        Item { // Structure node
            objectName: "wordmark-motion-shell"
            id: _qt_node19
            transform: TransformGroup {
                id: _qt_node19_transform_base_group
                TransformGroup {
                    id: _qt_node19_transform_group_0
                    Translate { id: _qt_node19_transform_0_0 }
                }
            }
            Connections { target: _qt_node0.animations; function onRestart() {_qt_node19_transform_animation.restart() } }
            ParallelAnimation {
                id:_qt_node19_transform_animation
                loops: _qt_node0.animations.loops
                paused: _qt_node0.animations.paused
                running: true
                onLoopsChanged: { if (running) { restart() } }
                SequentialAnimation {
                    loops: Animation.Infinite
                    ParallelAnimation {
                        SequentialAnimation {
                            ParallelAnimation {
                                PropertyAction { target: _qt_node19_transform_0_0; property: "x"; value: 0 }
                                PropertyAction { target: _qt_node19_transform_0_0; property: "y"; value: 0 }
                            }
                            ParallelAnimation {
                                PropertyAnimation {
                                    duration: 1440
                                    target: _qt_node19_transform_0_0
                                    property: "x"
                                    to: -3
                                }
                                PropertyAnimation {
                                    duration: 1440
                                    target: _qt_node19_transform_0_0
                                    property: "y"
                                    to: 1
                                }
                            }
                            ParallelAnimation {
                                PropertyAnimation {
                                    duration: 1440
                                    target: _qt_node19_transform_0_0
                                    property: "x"
                                    to: 4
                                }
                                PropertyAnimation {
                                    duration: 1440
                                    target: _qt_node19_transform_0_0
                                    property: "y"
                                    to: -1
                                }
                            }
                            ParallelAnimation {
                                PropertyAnimation {
                                    duration: 1440
                                    target: _qt_node19_transform_0_0
                                    property: "x"
                                    to: -1
                                }
                                PropertyAnimation {
                                    duration: 1440
                                    target: _qt_node19_transform_0_0
                                    property: "y"
                                    to: 0
                                }
                            }
                            ParallelAnimation {
                                PropertyAnimation {
                                    duration: 1440
                                    target: _qt_node19_transform_0_0
                                    property: "x"
                                    to: 0
                                }
                                PropertyAnimation {
                                    duration: 1440
                                    target: _qt_node19_transform_0_0
                                    property: "y"
                                    to: 0
                                }
                            }
                            PauseAnimation { duration: 1440 }
                        }
                    }
                }
            }
            Item { // Structure node
                objectName: "wordmark-base"
                id: _qt_node20
                Shape {
                    preferredRendererType: Shape.CurveRenderer
                    objectName: "word-P"
                    id: _qt_node21
                    ShapePath {
                        id: _qt_shapePath_18
                        strokeColor: "#ff5d0710"
                        strokeWidth: 10
                        capStyle: ShapePath.SquareCap
                        joinStyle: ShapePath.MiterJoin
                        miterLimit: 4
                        fillColor: "transparent"
                        fillRule: ShapePath.WindingFill
                        pathHints: ShapePath.PathQuadratic
                        PathSvg { path: "M 3 103 L 3 3 L 44 3 L 60 19 L 60 46 L 44 62 L 3 62 " }
                    }
                    ShapePath {
                        id: _qt_shapePath_19
                        strokeColor: "#ffe3172a"
                        strokeWidth: 10
                        capStyle: ShapePath.SquareCap
                        joinStyle: ShapePath.MiterJoin
                        miterLimit: 4
                        fillColor: "transparent"
                        fillRule: ShapePath.WindingFill
                        pathHints: ShapePath.PathQuadratic
                        PathSvg { path: "M 0 100 L 0 0 L 41 0 L 57 16 L 57 43 L 41 59 L 0 59 " }
                    }
                }
                Shape {
                    preferredRendererType: Shape.CurveRenderer
                    objectName: "word-A-1"
                    id: _qt_node22
                    transform: TransformGroup {
                        id: _qt_node22_transform_base_group
                        Translate { x: 76; y: 0}
                    }
                    ShapePath {
                        id: _qt_shapePath_20
                        strokeColor: "#ff5d0710"
                        strokeWidth: 10
                        capStyle: ShapePath.SquareCap
                        joinStyle: ShapePath.MiterJoin
                        miterLimit: 4
                        fillColor: "transparent"
                        fillRule: ShapePath.WindingFill
                        pathHints: ShapePath.PathQuadratic
                        PathSvg { path: "M 3 103 L 31 3 L 59 103 M 15 63 L 47 63 " }
                    }
                    ShapePath {
                        id: _qt_shapePath_21
                        strokeColor: "#ffe3172a"
                        strokeWidth: 10
                        capStyle: ShapePath.SquareCap
                        joinStyle: ShapePath.MiterJoin
                        miterLimit: 4
                        fillColor: "transparent"
                        fillRule: ShapePath.WindingFill
                        pathHints: ShapePath.PathQuadratic
                        PathSvg { path: "M 0 100 L 28 0 L 56 100 M 12 60 L 44 60 " }
                    }
                }
                Shape {
                    preferredRendererType: Shape.CurveRenderer
                    objectName: "word-R"
                    id: _qt_node23
                    transform: TransformGroup {
                        id: _qt_node23_transform_base_group
                        Translate { x: 152; y: 0}
                    }
                    ShapePath {
                        id: _qt_shapePath_22
                        strokeColor: "#ff5d0710"
                        strokeWidth: 10
                        capStyle: ShapePath.SquareCap
                        joinStyle: ShapePath.MiterJoin
                        miterLimit: 4
                        fillColor: "transparent"
                        fillRule: ShapePath.WindingFill
                        pathHints: ShapePath.PathQuadratic
                        PathSvg { path: "M 3 103 L 3 3 L 44 3 L 60 19 L 60 46 L 44 62 L 3 62 M 31 62 L 63 103 " }
                    }
                    ShapePath {
                        id: _qt_shapePath_23
                        strokeColor: "#ffe3172a"
                        strokeWidth: 10
                        capStyle: ShapePath.SquareCap
                        joinStyle: ShapePath.MiterJoin
                        miterLimit: 4
                        fillColor: "transparent"
                        fillRule: ShapePath.WindingFill
                        pathHints: ShapePath.PathQuadratic
                        PathSvg { path: "M 0 100 L 0 0 L 41 0 L 57 16 L 57 43 L 41 59 L 0 59 M 28 59 L 60 100 " }
                    }
                }
                Shape {
                    preferredRendererType: Shape.CurveRenderer
                    objectName: "word-A-2"
                    id: _qt_node24
                    transform: TransformGroup {
                        id: _qt_node24_transform_base_group
                        Translate { x: 228; y: 0}
                    }
                    ShapePath {
                        id: _qt_shapePath_24
                        strokeColor: "#ff5d0710"
                        strokeWidth: 10
                        capStyle: ShapePath.SquareCap
                        joinStyle: ShapePath.MiterJoin
                        miterLimit: 4
                        fillColor: "transparent"
                        fillRule: ShapePath.WindingFill
                        pathHints: ShapePath.PathQuadratic
                        PathSvg { path: "M 3 103 L 31 3 L 59 103 M 15 63 L 47 63 " }
                    }
                    ShapePath {
                        id: _qt_shapePath_25
                        strokeColor: "#ffe3172a"
                        strokeWidth: 10
                        capStyle: ShapePath.SquareCap
                        joinStyle: ShapePath.MiterJoin
                        miterLimit: 4
                        fillColor: "transparent"
                        fillRule: ShapePath.WindingFill
                        pathHints: ShapePath.PathQuadratic
                        PathSvg { path: "M 0 100 L 28 0 L 56 100 M 12 60 L 44 60 " }
                    }
                }
                Shape {
                    preferredRendererType: Shape.CurveRenderer
                    objectName: "word-N"
                    id: _qt_node25
                    transform: TransformGroup {
                        id: _qt_node25_transform_base_group
                        Translate { x: 304; y: 0}
                    }
                    ShapePath {
                        id: _qt_shapePath_26
                        strokeColor: "#ff5d0710"
                        strokeWidth: 10
                        capStyle: ShapePath.SquareCap
                        joinStyle: ShapePath.MiterJoin
                        miterLimit: 4
                        fillColor: "transparent"
                        fillRule: ShapePath.WindingFill
                        pathHints: ShapePath.PathQuadratic
                        PathSvg { path: "M 3 103 L 3 3 L 61 103 L 61 3 " }
                    }
                    ShapePath {
                        id: _qt_shapePath_27
                        strokeColor: "#ffe3172a"
                        strokeWidth: 10
                        capStyle: ShapePath.SquareCap
                        joinStyle: ShapePath.MiterJoin
                        miterLimit: 4
                        fillColor: "transparent"
                        fillRule: ShapePath.WindingFill
                        pathHints: ShapePath.PathQuadratic
                        PathSvg { path: "M 0 100 L 0 0 L 58 100 L 58 0 " }
                    }
                }
                Shape {
                    preferredRendererType: Shape.CurveRenderer
                    objectName: "word-O"
                    id: _qt_node26
                    transform: TransformGroup {
                        id: _qt_node26_transform_base_group
                        Translate { x: 386; y: 0}
                    }
                    ShapePath {
                        id: _qt_shapePath_28
                        strokeColor: "#ff5d0710"
                        strokeWidth: 10
                        capStyle: ShapePath.SquareCap
                        joinStyle: ShapePath.MiterJoin
                        miterLimit: 4
                        fillColor: "#00000000"
                        fillRule: ShapePath.WindingFill
                        pathHints: ShapePath.PathQuadratic | ShapePath.PathNonIntersecting | ShapePath.PathNonOverlappingControlPointTriangles
                        PathSvg { path: "M 17 3 L 47 3 L 61 17 L 61 89 L 47 103 L 17 103 L 3 89 L 3 17 L 17 3 " }
                    }
                    ShapePath {
                        id: _qt_shapePath_29
                        strokeColor: "#ffe3172a"
                        strokeWidth: 10
                        capStyle: ShapePath.SquareCap
                        joinStyle: ShapePath.MiterJoin
                        miterLimit: 4
                        fillColor: "#00000000"
                        fillRule: ShapePath.WindingFill
                        pathHints: ShapePath.PathQuadratic | ShapePath.PathNonIntersecting | ShapePath.PathNonOverlappingControlPointTriangles
                        PathSvg { path: "M 14 0 L 44 0 L 58 14 L 58 86 L 44 100 L 14 100 L 0 86 L 0 14 L 14 0 " }
                    }
                }
                Shape {
                    preferredRendererType: Shape.CurveRenderer
                    objectName: "word-I"
                    id: _qt_node27
                    transform: TransformGroup {
                        id: _qt_node27_transform_base_group
                        Translate { x: 466; y: 0}
                    }
                    ShapePath {
                        id: _qt_shapePath_30
                        strokeColor: "#ff5d0710"
                        strokeWidth: 10
                        capStyle: ShapePath.SquareCap
                        joinStyle: ShapePath.MiterJoin
                        miterLimit: 4
                        fillColor: "transparent"
                        fillRule: ShapePath.WindingFill
                        pathHints: ShapePath.PathQuadratic
                        PathSvg { path: "M 3 3 L 47 3 M 25 3 L 25 103 M 3 103 L 47 103 " }
                    }
                    ShapePath {
                        id: _qt_shapePath_31
                        strokeColor: "#ffe3172a"
                        strokeWidth: 10
                        capStyle: ShapePath.SquareCap
                        joinStyle: ShapePath.MiterJoin
                        miterLimit: 4
                        fillColor: "transparent"
                        fillRule: ShapePath.WindingFill
                        pathHints: ShapePath.PathQuadratic
                        PathSvg { path: "M 0 0 L 44 0 M 22 0 L 22 100 M 0 100 L 44 100 " }
                    }
                }
                Shape {
                    preferredRendererType: Shape.CurveRenderer
                    objectName: "word-A-3"
                    id: _qt_node28
                    transform: TransformGroup {
                        id: _qt_node28_transform_base_group
                        Translate { x: 526; y: 0}
                    }
                    ShapePath {
                        id: _qt_shapePath_32
                        strokeColor: "#ff5d0710"
                        strokeWidth: 10
                        capStyle: ShapePath.SquareCap
                        joinStyle: ShapePath.MiterJoin
                        miterLimit: 4
                        fillColor: "transparent"
                        fillRule: ShapePath.WindingFill
                        pathHints: ShapePath.PathQuadratic
                        PathSvg { path: "M 3 103 L 31 3 L 59 103 M 15 63 L 47 63 " }
                    }
                    ShapePath {
                        id: _qt_shapePath_33
                        strokeColor: "#ffe3172a"
                        strokeWidth: 10
                        capStyle: ShapePath.SquareCap
                        joinStyle: ShapePath.MiterJoin
                        miterLimit: 4
                        fillColor: "transparent"
                        fillRule: ShapePath.WindingFill
                        pathHints: ShapePath.PathQuadratic
                        PathSvg { path: "M 0 100 L 28 0 L 56 100 M 12 60 L 44 60 " }
                    }
                }
            }
            Item { // Structure node
                objectName: "wordmark-motion-signal-tear"
                id: _qt_node29
                opacity: 0.86
                Shape {
                    objectName: "wordmark-tear-a"
                    id: _qt_node30
                    transform: TransformGroup {
                        id: _qt_node30_transform_base_group
                        TransformGroup {
                            id: _qt_node30_transform_group_0
                            Translate { id: _qt_node30_transform_0_0 }
                        }
                    }
                    Connections { target: _qt_node0.animations; function onRestart() {_qt_node30_transform_animation.restart() } }
                    ParallelAnimation {
                        id:_qt_node30_transform_animation
                        loops: _qt_node0.animations.loops
                        paused: _qt_node0.animations.paused
                        running: true
                        onLoopsChanged: { if (running) { restart() } }
                        SequentialAnimation {
                            loops: Animation.Infinite
                            ParallelAnimation {
                                SequentialAnimation {
                                    ParallelAnimation {
                                        PropertyAction { target: _qt_node30_transform_0_0; property: "x"; value: 0 }
                                        PropertyAction { target: _qt_node30_transform_0_0; property: "y"; value: 0 }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 588
                                            target: _qt_node30_transform_0_0
                                            property: "x"
                                            to: -16
                                        }
                                        PropertyAnimation {
                                            duration: 588
                                            target: _qt_node30_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 587
                                            target: _qt_node30_transform_0_0
                                            property: "x"
                                            to: 11
                                        }
                                        PropertyAnimation {
                                            duration: 587
                                            target: _qt_node30_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 588
                                            target: _qt_node30_transform_0_0
                                            property: "x"
                                            to: -5
                                        }
                                        PropertyAnimation {
                                            duration: 588
                                            target: _qt_node30_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 587
                                            target: _qt_node30_transform_0_0
                                            property: "x"
                                            to: 0
                                        }
                                        PropertyAnimation {
                                            duration: 587
                                            target: _qt_node30_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                }
                            }
                        }
                    }
                    preferredRendererType: Shape.CurveRenderer
                    ShapePath {
                        id: _qt_shapePath_34
                        objectName: "svg_path:wordmark-tear-a"
                        strokeColor: "transparent"
                        fillColor: "#ffff2738"
                        fillRule: ShapePath.WindingFill
                        pathHints: ShapePath.PathQuadratic | ShapePath.PathNonIntersecting | ShapePath.PathNonOverlappingControlPointTriangles
                        PathSvg { path: "M 165 20 L 200 20 L 200 27 L 165 27 L 165 20 " }
                    }
                }
                Shape {
                    objectName: "wordmark-tear-b"
                    id: _qt_node31
                    transform: TransformGroup {
                        id: _qt_node31_transform_base_group
                        TransformGroup {
                            id: _qt_node31_transform_group_0
                            Translate { id: _qt_node31_transform_0_0 }
                        }
                    }
                    Connections { target: _qt_node0.animations; function onRestart() {_qt_node31_transform_animation.restart() } }
                    ParallelAnimation {
                        id:_qt_node31_transform_animation
                        loops: _qt_node0.animations.loops
                        paused: _qt_node0.animations.paused
                        running: true
                        onLoopsChanged: { if (running) { restart() } }
                        SequentialAnimation {
                            loops: Animation.Infinite
                            ParallelAnimation {
                                SequentialAnimation {
                                    ParallelAnimation {
                                        PropertyAction { target: _qt_node31_transform_0_0; property: "x"; value: 0 }
                                        PropertyAction { target: _qt_node31_transform_0_0; property: "y"; value: 0 }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 588
                                            target: _qt_node31_transform_0_0
                                            property: "x"
                                            to: 20
                                        }
                                        PropertyAnimation {
                                            duration: 588
                                            target: _qt_node31_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 587
                                            target: _qt_node31_transform_0_0
                                            property: "x"
                                            to: -12
                                        }
                                        PropertyAnimation {
                                            duration: 587
                                            target: _qt_node31_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 588
                                            target: _qt_node31_transform_0_0
                                            property: "x"
                                            to: 7
                                        }
                                        PropertyAnimation {
                                            duration: 588
                                            target: _qt_node31_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 587
                                            target: _qt_node31_transform_0_0
                                            property: "x"
                                            to: 0
                                        }
                                        PropertyAnimation {
                                            duration: 587
                                            target: _qt_node31_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                }
                            }
                        }
                    }
                    preferredRendererType: Shape.CurveRenderer
                    ShapePath {
                        id: _qt_shapePath_35
                        objectName: "svg_path:wordmark-tear-b"
                        strokeColor: "transparent"
                        fillColor: "#ffff2738"
                        fillRule: ShapePath.WindingFill
                        pathHints: ShapePath.PathQuadratic | ShapePath.PathNonIntersecting | ShapePath.PathNonOverlappingControlPointTriangles
                        PathSvg { path: "M 420 66 L 458 66 L 458 73 L 420 73 L 420 66 " }
                    }
                }
                Shape {
                    objectName: "wordmark-tear-c"
                    id: _qt_node32
                    transform: TransformGroup {
                        id: _qt_node32_transform_base_group
                        TransformGroup {
                            id: _qt_node32_transform_group_0
                            Translate { id: _qt_node32_transform_0_0 }
                        }
                    }
                    Connections { target: _qt_node0.animations; function onRestart() {_qt_node32_transform_animation.restart() } }
                    ParallelAnimation {
                        id:_qt_node32_transform_animation
                        loops: _qt_node0.animations.loops
                        paused: _qt_node0.animations.paused
                        running: true
                        onLoopsChanged: { if (running) { restart() } }
                        SequentialAnimation {
                            loops: Animation.Infinite
                            ParallelAnimation {
                                SequentialAnimation {
                                    ParallelAnimation {
                                        PropertyAction { target: _qt_node32_transform_0_0; property: "x"; value: 0 }
                                        PropertyAction { target: _qt_node32_transform_0_0; property: "y"; value: 0 }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 588
                                            target: _qt_node32_transform_0_0
                                            property: "x"
                                            to: -10
                                        }
                                        PropertyAnimation {
                                            duration: 588
                                            target: _qt_node32_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 587
                                            target: _qt_node32_transform_0_0
                                            property: "x"
                                            to: 15
                                        }
                                        PropertyAnimation {
                                            duration: 587
                                            target: _qt_node32_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 588
                                            target: _qt_node32_transform_0_0
                                            property: "x"
                                            to: 4
                                        }
                                        PropertyAnimation {
                                            duration: 588
                                            target: _qt_node32_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                    ParallelAnimation {
                                        PropertyAnimation {
                                            duration: 587
                                            target: _qt_node32_transform_0_0
                                            property: "x"
                                            to: 0
                                        }
                                        PropertyAnimation {
                                            duration: 587
                                            target: _qt_node32_transform_0_0
                                            property: "y"
                                            to: 0
                                        }
                                    }
                                }
                            }
                        }
                    }
                    preferredRendererType: Shape.CurveRenderer
                    ShapePath {
                        id: _qt_shapePath_36
                        objectName: "svg_path:wordmark-tear-c"
                        strokeColor: "transparent"
                        fillColor: "#ff610710"
                        fillRule: ShapePath.WindingFill
                        pathHints: ShapePath.PathQuadratic | ShapePath.PathNonIntersecting | ShapePath.PathNonOverlappingControlPointTriangles
                        PathSvg { path: "M 532 88 L 576 88 L 576 95 L 532 95 L 532 88 " }
                    }
                }
            }
            Shape {
                preferredRendererType: Shape.CurveRenderer
                objectName: "wordmark-motion-jitter-fragments"
                id: _qt_node33
                opacity: 0.66
                transform: TransformGroup {
                    id: _qt_node33_transform_base_group
                    TransformGroup {
                        id: _qt_node33_transform_group_0
                        Translate { id: _qt_node33_transform_0_0 }
                    }
                }
                Connections { target: _qt_node0.animations; function onRestart() {_qt_node33_transform_animation.restart() } }
                ParallelAnimation {
                    id:_qt_node33_transform_animation
                    loops: _qt_node0.animations.loops
                    paused: _qt_node0.animations.paused
                    running: true
                    onLoopsChanged: { if (running) { restart() } }
                    SequentialAnimation {
                        loops: Animation.Infinite
                        ParallelAnimation {
                            SequentialAnimation {
                                ParallelAnimation {
                                    PropertyAction { target: _qt_node33_transform_0_0; property: "x"; value: 0 }
                                    PropertyAction { target: _qt_node33_transform_0_0; property: "y"; value: 0 }
                                }
                                ParallelAnimation {
                                    PropertyAnimation {
                                        duration: 220
                                        target: _qt_node33_transform_0_0
                                        property: "x"
                                        to: 12
                                    }
                                    PropertyAnimation {
                                        duration: 220
                                        target: _qt_node33_transform_0_0
                                        property: "y"
                                        to: -3
                                    }
                                }
                                ParallelAnimation {
                                    PropertyAnimation {
                                        duration: 220
                                        target: _qt_node33_transform_0_0
                                        property: "x"
                                        to: -9
                                    }
                                    PropertyAnimation {
                                        duration: 220
                                        target: _qt_node33_transform_0_0
                                        property: "y"
                                        to: 2
                                    }
                                }
                                ParallelAnimation {
                                    PropertyAnimation {
                                        duration: 220
                                        target: _qt_node33_transform_0_0
                                        property: "x"
                                        to: 4
                                    }
                                    PropertyAnimation {
                                        duration: 220
                                        target: _qt_node33_transform_0_0
                                        property: "y"
                                        to: 1
                                    }
                                }
                                ParallelAnimation {
                                    PropertyAnimation {
                                        duration: 220
                                        target: _qt_node33_transform_0_0
                                        property: "x"
                                        to: 0
                                    }
                                    PropertyAnimation {
                                        duration: 220
                                        target: _qt_node33_transform_0_0
                                        property: "y"
                                        to: 0
                                    }
                                }
                                PauseAnimation { duration: 220 }
                            }
                        }
                    }
                }
                ShapePath {
                    id: _qt_shapePath_37
                    objectName: "svg_path:wordmark-jitter-a"
                    strokeColor: "transparent"
                    fillColor: "#ff610710"
                    fillRule: ShapePath.WindingFill
                    pathHints: ShapePath.PathQuadratic | ShapePath.PathNonIntersecting | ShapePath.PathNonOverlappingControlPointTriangles
                    PathSvg { path: "M 69 11 L 87 11 L 87 18 L 69 18 L 69 11 " }
                }
                ShapePath {
                    id: _qt_shapePath_38
                    objectName: "svg_path:wordmark-jitter-b"
                    strokeColor: "transparent"
                    fillColor: "#ff610710"
                    fillRule: ShapePath.WindingFill
                    pathHints: ShapePath.PathQuadratic | ShapePath.PathNonIntersecting | ShapePath.PathNonOverlappingControlPointTriangles
                    PathSvg { path: "M 284 105 L 314 105 L 314 112 L 284 112 L 284 105 " }
                }
                ShapePath {
                    id: _qt_shapePath_39
                    objectName: "svg_path:wordmark-jitter-c"
                    strokeColor: "transparent"
                    fillColor: "#ff610710"
                    fillRule: ShapePath.WindingFill
                    pathHints: ShapePath.PathQuadratic | ShapePath.PathNonIntersecting | ShapePath.PathNonOverlappingControlPointTriangles
                    PathSvg { path: "M 491 27 L 517 27 L 517 34 L 491 34 L 491 27 " }
                }
            }
        }
    }
    Shape {
        preferredRendererType: Shape.CurveRenderer
        objectName: "combined-lockup-corruption-burst"
        id: _qt_node34
        opacity: 0.62
        transform: TransformGroup {
            id: _qt_node34_transform_base_group
            TransformGroup {
                id: _qt_node34_transform_group_0
                Translate { id: _qt_node34_transform_0_0 }
            }
        }
        Connections { target: _qt_node0.animations; function onRestart() {_qt_node34_transform_animation.restart() } }
        ParallelAnimation {
            id:_qt_node34_transform_animation
            loops: _qt_node0.animations.loops
            paused: _qt_node0.animations.paused
            running: true
            onLoopsChanged: { if (running) { restart() } }
            SequentialAnimation {
                loops: Animation.Infinite
                ParallelAnimation {
                    SequentialAnimation {
                        ParallelAnimation {
                            PropertyAction { target: _qt_node34_transform_0_0; property: "x"; value: 0 }
                            PropertyAction { target: _qt_node34_transform_0_0; property: "y"; value: 0 }
                        }
                        ParallelAnimation {
                            PropertyAnimation {
                                duration: 1440
                                target: _qt_node34_transform_0_0
                                property: "x"
                                to: -22
                            }
                            PropertyAnimation {
                                duration: 1440
                                target: _qt_node34_transform_0_0
                                property: "y"
                                to: -2
                            }
                        }
                        ParallelAnimation {
                            PropertyAnimation {
                                duration: 1440
                                target: _qt_node34_transform_0_0
                                property: "x"
                                to: 18
                            }
                            PropertyAnimation {
                                duration: 1440
                                target: _qt_node34_transform_0_0
                                property: "y"
                                to: 3
                            }
                        }
                        ParallelAnimation {
                            PropertyAnimation {
                                duration: 1440
                                target: _qt_node34_transform_0_0
                                property: "x"
                                to: -6
                            }
                            PropertyAnimation {
                                duration: 1440
                                target: _qt_node34_transform_0_0
                                property: "y"
                                to: 0
                            }
                        }
                        ParallelAnimation {
                            PropertyAnimation {
                                duration: 1440
                                target: _qt_node34_transform_0_0
                                property: "x"
                                to: 0
                            }
                            PropertyAnimation {
                                duration: 1440
                                target: _qt_node34_transform_0_0
                                property: "y"
                                to: 0
                            }
                        }
                        PauseAnimation { duration: 1440 }
                    }
                }
            }
        }
        ShapePath {
            id: _qt_shapePath_40
            objectName: "svg_path:combined-burst-a"
            strokeColor: "transparent"
            fillColor: "#ff4a060c"
            fillRule: ShapePath.WindingFill
            pathHints: ShapePath.PathQuadratic | ShapePath.PathNonIntersecting | ShapePath.PathNonOverlappingControlPointTriangles
            PathSvg { path: "M 1118 42 L 1160 42 L 1160 50 L 1118 50 L 1118 42 " }
        }
        ShapePath {
            id: _qt_shapePath_41
            objectName: "svg_path:combined-burst-b"
            strokeColor: "transparent"
            fillColor: "#ff8f0b16"
            fillRule: ShapePath.WindingFill
            pathHints: ShapePath.PathQuadratic | ShapePath.PathNonIntersecting | ShapePath.PathNonOverlappingControlPointTriangles
            PathSvg { path: "M 1163 199 L 1192 199 L 1192 207 L 1163 207 L 1163 199 " }
        }
        ShapePath {
            id: _qt_shapePath_42
            objectName: "svg_path:combined-burst-c"
            strokeColor: "transparent"
            fillColor: "#ff4a060c"
            fillRule: ShapePath.WindingFill
            pathHints: ShapePath.PathQuadratic | ShapePath.PathNonIntersecting | ShapePath.PathNonOverlappingControlPointTriangles
            PathSvg { path: "M 276 227 L 313 227 L 313 234 L 276 234 L 276 227 " }
        }
    }
}
