#!/usr/bin/env bash
# Добандливание сторонних shared-библиотек в Linux-пакет клиента.
# FFmpeg/OpenH264 у нас статические (вкомпилены в бинарь), но opus/hunspell и
# не-системные транзитивные зависимости Qt-мультимедиа остаются shared — их
# кладём в lib/ рядом с бинарём (RPATH уже = $ORIGIN/../lib).
#
# Системный стек (glibc, libstdc++, графика/X/wayland/drm, dbus, glib,
# fontconfig, pulse/alsa) НЕ бандлим — он приходит с хоста и совместим вниз.
#
# Usage: scripts/bundle_linux_libs.sh <package_dir>   # с bin/Paranoia и lib/
set -euo pipefail

PKG="${1:?usage: bundle_linux_libs.sh <package_dir>}"
BIN="$PKG/bin/Paranoia"
LIBDIR="$PKG/lib"
test -x "$BIN" || { echo "ERROR: $BIN not found" >&2; exit 1; }
mkdir -p "$LIBDIR"

# Либы, которые ДОЛЖНЫ приходить с хоста (совместимы вниз) — не бандлим.
DENY='^(ld-linux|libc\.so|libm\.so|libdl\.so|libpthread\.so|librt\.so|libresolv\.so|libutil\.so|libnsl\.so|libanl|libBrokenLocale|libcrypt\.so|libstdc\+\+\.so|libgcc_s\.so|libGL|libEGL|libGLX|libGLdispatch|libOpenGL|libGLU|libglapi|libdrm|libgbm|libX11|libxcb|libXext|libXrender|libXi\.|libXfixes|libXrandr|libXcursor|libXcomposite|libXdamage|libXtst|libXss|libxshmfence|libXau|libXdmcp|libXxf86vm|libxkbcommon|libwayland|libdbus-1|libglib-2|libgobject-2|libgio-2|libgmodule-2|libgthread-2|libpcre|libffi|libfontconfig|libfreetype|libexpat|libuuid|libpulse|libasound|libselinux|libsystemd|libudev|libz\.so)'

collect_closure() {
    local seen=" " queue=("$@") out=()
    while [ "${#queue[@]}" -gt 0 ]; do
        local cur="${queue[0]}"; queue=("${queue[@]:1}")
        case "$seen" in *" $cur "*) continue;; esac
        seen="$seen$cur "
        while read -r dep; do
            [ -n "$dep" ] || continue
            local base; base=$(basename "$dep")
            echo "$base" | grep -qE "$DENY" && continue
            out+=("$dep"); queue+=("$dep")
        done < <(ldd "$cur" 2>/dev/null | sed -n 's/.* => \(\/[^ ]*\).*/\1/p')
    done
    printf '%s\n' "${out[@]}" | sort -u
}

mapfile -t CLOSURE < <(collect_closure "$BIN" "$LIBDIR"/libQt6*.so.* 2>/dev/null)

copied=0
for dep in "${CLOSURE[@]}"; do
    base=$(basename "$dep")
    [ -e "$LIBDIR/$base" ] && continue
    [ "$base" = "Paranoia" ] && continue
    cp -L "$dep" "$LIBDIR/$base"
    copied=$((copied+1))
done
echo "bundle_linux_libs: добавлено $copied либ в $LIBDIR"

miss=$(LD_LIBRARY_PATH="$LIBDIR" ldd "$BIN" 2>/dev/null | grep -c "not found" || true)
if [ "$miss" != "0" ]; then
    echo "ERROR: после бандлинга остались ненайденные либы:" >&2
    LD_LIBRARY_PATH="$LIBDIR" ldd "$BIN" | grep "not found" >&2
    exit 1
fi
echo "bundle_linux_libs: все зависимости разрешены (not found = 0)"
