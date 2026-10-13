#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
for variant in server desktop; do
    BUILD_OUTPUT_DIR="$tmp/build" UBUNTU_IMAGE=/bin/true \
        "$PROJECT_DIR/build.sh" "$variant" --check >"$tmp/$variant.plan"
    grep -Fq "image=resolute/26.04/$variant/arm64" "$tmp/$variant.plan" || fail 'variant was ignored'
done
if UBUNTU_IMAGE=/bin/true "$PROJECT_DIR/scripts/build-server.sh" --variant nonsense --check >/dev/null 2>&1; then
    fail 'invalid variant was accepted'
fi
awk 'NF && $1 !~ /^#/ {print $1 " 1"}' "$PROJECT_DIR/config/ubuntu-image/desktop.packages" >"$tmp/manifest"
"$PROJECT_DIR/scripts/check-desktop-manifest.sh" desktop "$tmp/manifest"
if "$PROJECT_DIR/scripts/check-desktop-manifest.sh" server "$tmp/manifest" >/dev/null 2>&1; then
    fail 'Server accepted GNOME payload'
fi
sed '/^gdm3 /d' "$tmp/manifest" >"$tmp/missing"
if "$PROJECT_DIR/scripts/check-desktop-manifest.sh" desktop "$tmp/missing" >/dev/null 2>&1; then
    fail 'incomplete GNOME stack was accepted'
fi
mkdir -p "$tmp/server"
"$PROJECT_DIR/scripts/install-gnome.sh" "$tmp/server"
[[ ! -e "$tmp/server/etc/systemd" ]] || fail 'GNOME modified Server'
mkdir -p "$tmp/desktop/usr/bin" "$tmp/desktop/usr/lib/systemd/system" \
    "$tmp/desktop/usr/share/wayland-sessions" "$tmp/desktop/etc/X11" "$tmp/desktop/var/lib/cloud/seed/nocloud"
printf '#!/bin/sh\n' >"$tmp/desktop/usr/bin/gnome-shell"
chmod +x "$tmp/desktop/usr/bin/gnome-shell"
printf '[Unit]\nDescription=GDM fixture\n[Service]\nExecStart=/bin/true\n[Install]\nAlias=display-manager.service\n' >"$tmp/desktop/usr/lib/systemd/system/gdm.service"
printf '[Unit]\nDescription=Graphical fixture\n' >"$tmp/desktop/usr/lib/systemd/system/graphical.target"
printf '[Desktop Entry]\nName=Ubuntu\n' >"$tmp/desktop/usr/share/wayland-sessions/ubuntu.desktop"
printf '[Unit]\nDescription=NetworkManager fixture\n[Service]\nExecStart=/bin/true\n[Install]\nWantedBy=multi-user.target\n' >"$tmp/desktop/usr/lib/systemd/system/NetworkManager.service"
printf '[Unit]\nDescription=networkd fixture\n[Service]\nExecStart=/bin/true\n[Install]\nWantedBy=multi-user.target\n' >"$tmp/desktop/usr/lib/systemd/system/systemd-networkd.service"
printf '[Unit]\nDescription=networkd socket fixture\n[Socket]\nListenStream=/run/networkd-test\n[Install]\nWantedBy=sockets.target\n' >"$tmp/desktop/usr/lib/systemd/system/systemd-networkd.socket"
printf 'version: 2\nrenderer: networkd\n' >"$tmp/desktop/var/lib/cloud/seed/nocloud/network-config"
mkdir -p "$tmp/desktop/usr/share/glib-2.0/schemas"
cat >"$tmp/desktop/usr/share/glib-2.0/schemas/org.gnome.shell.gschema.xml" <<'XML'
<schemalist>
  <schema id="org.gnome.shell" path="/org/gnome/shell/">
    <key name="favorite-apps" type="as"><default>[]</default></key>
    <key name="enabled-extensions" type="as"><default>[]</default></key>
  </schema>
</schemalist>
XML
cat >"$tmp/desktop/usr/share/glib-2.0/schemas/org.gnome.desktop.session.gschema.xml" <<'XML'
<schemalist>
  <schema id="org.gnome.desktop.session" path="/org/gnome/desktop/session/">
    <key name="idle-delay" type="u"><default>300</default></key>
  </schema>
</schemalist>
XML
"$PROJECT_DIR/scripts/install-gnome.sh" "$tmp/desktop"
schema_dir="$tmp/desktop/usr/share/glib-2.0/schemas"
GSETTINGS_SCHEMA_DIR="$schema_dir" XDG_CURRENT_DESKTOP=ubuntu \
    gsettings get org.gnome.shell favorite-apps | grep -Fq chromium.desktop || fail 'Chromium favorite is missing'
GSETTINGS_SCHEMA_DIR="$schema_dir" XDG_CURRENT_DESKTOP=ubuntu \
    gsettings get org.gnome.shell enabled-extensions | grep -Fq kimpanel@kde.org || fail 'input panel is not enabled'
[[ "$(GSETTINGS_SCHEMA_DIR="$schema_dir" GSETTINGS_BACKEND=memory \
    gsettings get org.gnome.desktop.session idle-delay)" == 'uint32 0' ]] || fail 'automatic screen blanking is enabled'
grep -Fxq 'renderer: NetworkManager' "$tmp/desktop/var/lib/cloud/seed/nocloud/network-config" || fail 'desktop still uses networkd'

[[ "$(readlink "$tmp/desktop/etc/systemd/system/default.target")" == */graphical.target ]] || fail 'graphical target is not enabled'
[[ "$(readlink "$tmp/desktop/etc/systemd/system/display-manager.service")" == */gdm.service ]] || fail 'GDM is not enabled'
firstboot_override="$tmp/desktop/etc/systemd/system/ubuntu-firstboot.service.d/10-firstboot-greeter.conf"
[[ -s "$firstboot_override" ]] || fail 'desktop firstboot greeter override is missing'
grep -Fxq 'Type=exec' "$firstboot_override" || fail 'firstboot still blocks the greeter'
grep -Fxq 'Before=getty.target' "$firstboot_override" || fail 'serial getty ordering was lost'
[[ ! -e "$tmp/desktop/etc/chromium/rockchip-webgpu-backend" ]] || fail 'automatic policy forced a compatibility backend'
for soc in rk3576 rk3588; do
    SOC_MODEL="$soc" CHROMIUM_WEBGPU_BACKEND=gles-compat "$PROJECT_DIR/scripts/install-gnome.sh" "$tmp/desktop"
    [[ -s "$tmp/desktop/etc/chromium/rockchip-webgpu-backend" ]] || fail 'explicit backend was ignored'
    rm "$tmp/desktop/etc/chromium/rockchip-webgpu-backend"
done
if CHROMIUM_WEBGPU_BACKEND=invalid "$PROJECT_DIR/scripts/install-gnome.sh" "$tmp/desktop" >/dev/null 2>&1; then
    fail 'invalid backend was accepted'
fi
echo 'GNOME variant and Server isolation checks passed'
