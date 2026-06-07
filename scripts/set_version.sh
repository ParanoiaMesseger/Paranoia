#!/usr/bin/env bash
# Единая версия монорепозитория. Политика: версия сервера, всех библиотек,
# CLI и клиента совпадает. Этот скрипт — единственная точка смены версии:
# он правит [package] version во всех Rust-крейтах и project(... VERSION ...)
# в CMake Qt-клиента. Android versionCode, APP_VERSION и версии macOS-бандла
# выводятся из PROJECT_VERSION автоматически (см. ParanoiaUiClient/CMakeLists.txt),
# отдельно их менять не нужно.
#
# Usage:
#   scripts/set_version.sh 0.2.12      # установить версию
#   scripts/set_version.sh             # показать текущие версии и выйти
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Все компоненты с собственным определением версии.
CRATES=(ParanoiaServer ParanoiaLibrary ParanoiaEasyCli ParanoiaCover)
CMAKE_CLIENT="ParanoiaUiClient/CMakeLists.txt"

show_current() {
    echo "Текущие версии:"
    for c in "${CRATES[@]}"; do
        local f="$ROOT/$c/Cargo.toml"
        [ -f "$f" ] && printf "  %-20s %s\n" "$c" "$(awk -F'"' '/^\[/{p=($0=="[package]")} p&&/^[[:space:]]*version[[:space:]]*=/{print $2; exit}' "$f")"
    done
    [ -f "$ROOT/$CMAKE_CLIENT" ] && printf "  %-20s %s\n" "ParanoiaUiClient" \
        "$(grep -m1 -oE 'project\([^)]*VERSION [0-9]+\.[0-9]+\.[0-9]+' "$ROOT/$CMAKE_CLIENT" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
}

NEW="${1:-}"
if [ -z "$NEW" ]; then
    show_current
    exit 0
fi

if ! [[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Ошибка: версия должна быть в формате X.Y.Z (получено: '$NEW')" >&2
    exit 1
fi

echo "Устанавливаю версию $NEW во всех компонентах монорепо:"

# Rust-крейты: меняем строку version ТОЛЬКО внутри секции [package],
# не трогая version у зависимостей.
for c in "${CRATES[@]}"; do
    f="$ROOT/$c/Cargo.toml"
    if [ ! -f "$f" ]; then
        echo "  ! пропуск $c (нет $f)"
        continue
    fi
    awk -v v="$NEW" '
        /^\[/ { inpkg = ($0 == "[package]") }
        inpkg && !done && /^[[:space:]]*version[[:space:]]*=/ {
            sub(/version[[:space:]]*=[[:space:]]*"[^"]*"/, "version = \"" v "\"")
            done = 1
        }
        { print }
    ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    printf "  %-20s -> %s\n" "$c" "$NEW"
done

# Qt-клиент: project(<name> VERSION X.Y.Z ...)
cm="$ROOT/$CMAKE_CLIENT"
if [ -f "$cm" ]; then
    sed -i -E "s/(project\([^)]*VERSION )[0-9]+\.[0-9]+\.[0-9]+/\1$NEW/" "$cm"
    printf "  %-20s -> %s\n" "ParanoiaUiClient" "$NEW"
fi

echo
echo "Готово. Cargo.lock обновится при следующем 'cargo build' (или сразу:"
echo "  for d in ${CRATES[*]}; do (cd \"\$d\" && cargo update -p \"\$(awk -F'\\\"' '/^name/{print \$2; exit}' Cargo.toml)\" --precise $NEW >/dev/null 2>&1 || true); done )"
echo "Проверьте: git diff"
