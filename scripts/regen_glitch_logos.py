#!/usr/bin/env python3
# Перегенерация ui/Components/Logo{Symbol,Lockup}Glitch.qml из анимированных SVG.
#
# Шаг 1 (svgtoqml из Qt SDK; на машине без SDK — из docker ci-linux-qt-u22):
#   svgtoqml -c -p resources/design/logo_symbol_animated.svg /tmp/LogoSymbolGlitch.qml
#   svgtoqml -c -p resources/design/logo_lockup_animated.svg /tmp/LogoLockupGlitch.qml
# Шаг 2: этот скрипт: regen_glitch_logos.py <сырой.qml> <итоговый.qml>
#
# Зачем пост-обработка: сгенерированные ScriptAction в бесконечном цикле анимации
# на КАЖДОЙ итерации компилируют JS-выражение, а движок удерживает юниты навсегда
# (утечка Qt 6.10, тот же механизм течёт и в VectorImage с SMIL-SVG). Замены:
# ScriptAction-присваивания -> PropertyAction (без рантайм-выражений), активация
# transform-override -> один раз в Component.onCompleted (идемпотентна: флаг |=).
import re
import sys

src = open(sys.argv[1]).read()

activations = []


def take_activation(m):
    activations.append((m.group('g'), m.group('a')))
    return ''


src = re.sub(
    r'[ \t]*ScriptAction \{\n[ \t]*script: (?P<g>\w+)\.activateOverride\((?P<a>\w+)\)\n[ \t]*\}\n',
    take_activation, src)


def to_property_action(m):
    ind, tid, prop, val = m.groups()
    return f'{ind}PropertyAction {{ target: {tid}; property: "{prop}"; value: {val} }}\n'


src = re.sub(
    r'([ \t]*)ScriptAction \{\n[ \t]*script:(\w+)\.(\w+) = (-?[0-9.]+)\n[ \t]*\}\n',
    to_property_action, src)

assert 'ScriptAction' not in src, 'остались необработанные ScriptAction'
assert activations, 'не найдено ни одной активации override'

calls = '\n'.join(f'        {g}.activateOverride({a})'
                  for g, a in dict.fromkeys(activations))
marker = '    id: _qt_node0\n'
assert marker in src
src = src.replace(marker,
                  marker + '    Component.onCompleted: {\n' + calls + '\n    }\n', 1)

src = src.replace('import QtQuick.VectorImage\n', '', 1)
header = (
    '// Сгенерировано svgtoqml из %s + пост-обработка scripts/regen_glitch_logos.py\n'
    '// (см. шапку скрипта; руками не править - перегенерировать).\n'
) % re.search(r'Generated from SVG file (\S+)', src).group(1)
src = re.sub(r'^// Generated from SVG file \S+\n', header, src)
open(sys.argv[2], 'w').write(src)
print(f'{sys.argv[2]}: активаций {len(dict.fromkeys(activations))}, строк {src.count(chr(10))}')
