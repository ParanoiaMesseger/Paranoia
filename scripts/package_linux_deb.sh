#!/usr/bin/env bash
# Сборка нативного .deb для Linux-клиента Paranoia (замена Qt IFW).
#
# Почему не IFW: IFW-инсталлятор ставил приложение в ~/Paranoia, из-за чего
# иконка (share/icons/hicolor/...) НЕ попадала в XDG-путь поиска иконок
# (~/.local/share, /usr/share) — и не отображалась ни в меню, ни в доке.
# .deb кладёт приложение в /opt/Paranoia, а .desktop и иконку — в /usr/share
# (штатный XDG-путь), и postinst обновляет кэш иконок + desktop-базу. Иконка
# гарантированно прописывается.
#
# Layout пакета:
#   /opt/Paranoia/{bin,lib,plugins,qml,translations}   — self-contained app
#   /usr/bin/paranoia                                   — symlink на лаунчер
#   /usr/share/applications/app.paranoia.client.desktop
#   /usr/share/icons/hicolor/scalable/apps/app.paranoia.client.svg
#
# Использование:
#   package_linux_deb.sh --package <build_client/package> --out <out.deb> \
#                        --version X.Y.Z [--arch amd64]
set -euo pipefail

PKG=""; OUT=""; VERSION=""; ARCH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --package) PKG="$2"; shift 2;;
    --out)     OUT="$2"; shift 2;;
    --version) VERSION="$2"; shift 2;;
    --arch)    ARCH="$2"; shift 2;;
    *) echo "package_linux_deb: unknown arg '$1'" >&2; exit 2;;
  esac
done
ARCH="${ARCH:-$(dpkg --print-architecture)}"
test -d "$PKG" || { echo "package_linux_deb: package dir not found: $PKG" >&2; exit 1; }
test -n "$OUT" || { echo "package_linux_deb: --out is required" >&2; exit 2; }
test -n "$VERSION" || { echo "package_linux_deb: --version is required" >&2; exit 2; }

echo "package_linux_deb: package=$PKG out=$OUT version=$VERSION arch=$ARCH"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/paranoia-deb.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APPROOT="$STAGE/opt/Paranoia"
mkdir -p "$APPROOT" "$STAGE/usr/bin" \
         "$STAGE/usr/share/applications" \
         "$STAGE/usr/share/icons/hicolor/scalable/apps" \
         "$STAGE/DEBIAN"

# 1. Приложение → /opt/Paranoia (всё, кроме share/ — он раскладывается в /usr).
for d in bin lib plugins qml translations resources; do
  [ -d "$PKG/$d" ] && cp -a "$PKG/$d" "$APPROOT/"
done
test -x "$APPROOT/bin/Paranoia" || { echo "package_linux_deb: bin/Paranoia не найден в пакете" >&2; exit 1; }

# 2. Иконка → /usr/share/icons/hicolor/scalable/apps (XDG-путь — главное исправление).
ICON_SRC="$PKG/share/icons/hicolor/scalable/apps/app.paranoia.client.svg"
test -f "$ICON_SRC" || { echo "package_linux_deb: иконка не найдена: $ICON_SRC" >&2; exit 1; }
install -m 644 "$ICON_SRC" "$STAGE/usr/share/icons/hicolor/scalable/apps/app.paranoia.client.svg"

# 3. Лаунчер-обёртка: корректно задаёт QT_QPA_PLATFORM (в .desktop Exec символ ';'
#    зарезервирован и ломает разбор — поэтому env-логика тут, а не в .desktop).
cat > "$APPROOT/bin/paranoia-launcher" <<'LAUNCH'
#!/bin/sh
# Предпочитаем Wayland, откат на X11 (xcb).
exec env QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland;xcb}" /opt/Paranoia/bin/Paranoia "$@"
LAUNCH
chmod 755 "$APPROOT/bin/paranoia-launcher"
ln -s /opt/Paranoia/bin/paranoia-launcher "$STAGE/usr/bin/paranoia"

# 4. .desktop → /usr/share/applications. Icon=app.paranoia.client (по имени —
#    резолвится из hicolor/scalable/apps выше).
cat > "$STAGE/usr/share/applications/app.paranoia.client.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=Paranoia
Comment=Secure messaging client
Exec=/opt/Paranoia/bin/paranoia-launcher %U
Icon=app.paranoia.client
Terminal=false
Categories=Network;InstantMessaging;
StartupNotify=true
StartupWMClass=ParanoiaUiClient
DESK

# 5. DEBIAN/control. Qt/FFmpeg/ICU вшиты в /opt/Paranoia/lib (bundle_linux_libs.sh),
#    поэтому в Depends — только базовый рантайм; X11/Wayland/glib есть на любом
#    десктопном Ubuntu.
INSTALLED_KB="$(du -sk "$STAGE/opt" "$STAGE/usr" 2>/dev/null | awk '{s+=$1} END{print s+0}')"
cat > "$STAGE/DEBIAN/control" <<CTRL
Package: paranoia
Version: $VERSION
Section: net
Priority: optional
Architecture: $ARCH
Maintainer: Paranoia <noreply@paranoia.app>
Installed-Size: $INSTALLED_KB
Depends: libc6, libstdc++6
Description: Paranoia secure messaging client
 End-to-end encrypted messenger with VoIP and file sharing.
CTRL

# 6. postinst/postrm — обновление кэша иконок hicolor и desktop-базы. Именно
#    этого не делал IFW → иконка не появлялась до перелогина/ручного refresh.
cat > "$STAGE/DEBIAN/postinst" <<'POST'
#!/bin/sh
set -e
if [ "$1" = "configure" ]; then
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>/dev/null || true
    fi
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database -q /usr/share/applications 2>/dev/null || true
    fi
fi
exit 0
POST
cat > "$STAGE/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
set -e
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>/dev/null || true
    fi
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database -q /usr/share/applications 2>/dev/null || true
    fi
fi
exit 0
POSTRM
chmod 755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/postrm"

# 7. Сборка пакета.
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
dpkg-deb --build --root-owner-group "$STAGE" "$OUT" >/dev/null
echo "package_linux_deb: built -> $OUT"
ls -lh "$OUT"
echo "--- control ---"; dpkg-deb --field "$OUT" Package Version Architecture Installed-Size Depends
echo "--- desktop/icon в пакете ---"
dpkg-deb --contents "$OUT" | grep -E "applications/.*desktop|icons/.*svg|usr/bin/paranoia$|opt/Paranoia/bin/Paranoia$"
