#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-"$SCRIPT_DIR/build/ParanoiaUiClient-release"}"
QT_PREFIX="${QT_PREFIX:-}"

if [[ -z "$QT_PREFIX" && -z "${CMAKE_PREFIX_PATH:-}" ]]; then
    shopt -s nullglob
    QT_CANDIDATES=("$HOME"/Qt/*/gcc_64 /opt/Qt/*/gcc_64)
    shopt -u nullglob

    for candidate in "${QT_CANDIDATES[@]}"; do
        if [[ -f "$candidate/lib/cmake/Qt6/Qt6Config.cmake" ]]; then
            QT_PREFIX="$candidate"
            break
        fi
    done
fi

CMAKE_ARGS=(-S "$SCRIPT_DIR" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release)

if [[ -n "$QT_PREFIX" ]]; then
    if [[ ! -f "$QT_PREFIX/lib/cmake/Qt6/Qt6Config.cmake" ]]; then
        echo "Qt6Config.cmake не найден в QT_PREFIX=$QT_PREFIX" >&2
        echo "Укажите путь к Qt, например: QT_PREFIX=\$HOME/Qt/6.10.1/gcc_64 bash run.sh" >&2
        exit 1
    fi

    CMAKE_ARGS+=(-DCMAKE_PREFIX_PATH="$QT_PREFIX")
    export LD_LIBRARY_PATH="$QT_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export QT_PLUGIN_PATH="$QT_PREFIX/plugins${QT_PLUGIN_PATH:+:$QT_PLUGIN_PATH}"
    export QML2_IMPORT_PATH="$QT_PREFIX/qml${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"
elif [[ -n "${CMAKE_PREFIX_PATH:-}" ]]; then
    CMAKE_ARGS+=(-DCMAKE_PREFIX_PATH="$CMAKE_PREFIX_PATH")
fi

cmake "${CMAKE_ARGS[@]}"

cmake --build "$BUILD_DIR" --config Release --parallel

APP="$BUILD_DIR/appParanoiaUiClient"
if [[ ! -x "$APP" && -x "$BUILD_DIR/Release/appParanoiaUiClient" ]]; then
    APP="$BUILD_DIR/Release/appParanoiaUiClient"
fi

if [[ ! -x "$APP" ]]; then
    echo "Не найден исполняемый файл appParanoiaUiClient в $BUILD_DIR" >&2
    exit 1
fi

exec "$APP"
