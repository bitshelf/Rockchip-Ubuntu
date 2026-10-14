#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf -- "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
awk 'NF && $1 !~ /^#/ {print $1, "fixture"}' "$PROJECT_DIR/config/ubuntu-image/desktop-xfce.packages" >"$tmp/manifest"
"$PROJECT_DIR/scripts/check-desktop-manifest.sh" desktop-xfce "$tmp/manifest"
printf 'gnome-shell fixture\n' >>"$tmp/manifest"
if "$PROJECT_DIR/scripts/check-desktop-manifest.sh" desktop-xfce "$tmp/manifest" >/dev/null 2>&1; then fail 'GNOME leaked into XFCE'; fi
sed '/^gnome-shell /d; /^lightdm /d' "$tmp/manifest" >"$tmp/missing"
if "$PROJECT_DIR/scripts/check-desktop-manifest.sh" desktop-xfce "$tmp/missing" >/dev/null 2>&1; then fail 'missing LightDM was accepted'; fi
mkdir "$tmp/server"
"$PROJECT_DIR/scripts/install-xfce.sh" "$tmp/server"
[[ ! -e "$tmp/server/etc" ]] || fail 'XFCE modified Server'
root="$tmp/xfce"
mkdir -p "$root/usr/bin" "$root/usr/lib/systemd/system" "$root/usr/share/xsessions" "$root/var/lib/cloud/seed/nocloud"
printf '#!/bin/sh\n' >"$root/usr/bin/xfce4-session"; chmod +x "$root/usr/bin/xfce4-session"
printf '[Desktop Entry]\nName=XFCE\n' >"$root/usr/share/xsessions/xfce.desktop"
cat >"$root/usr/lib/systemd/system/lightdm.service" <<'UNIT'
[Unit]
Description=LightDM fixture
[Service]
ExecStart=/bin/true
[Install]
Alias=display-manager.service
UNIT
printf '[Unit]\nDescription=Graphical fixture\n' >"$root/usr/lib/systemd/system/graphical.target"
cat >"$root/usr/lib/systemd/system/NetworkManager.service" <<'UNIT'
[Unit]
Description=Network fixture
[Service]
ExecStart=/bin/true
[Install]
WantedBy=multi-user.target
UNIT
printf '[Unit]\nDescription=networkd fixture\n' >"$root/usr/lib/systemd/system/systemd-networkd.service"
printf '[Unit]\nDescription=networkd socket fixture\n' >"$root/usr/lib/systemd/system/systemd-networkd.socket"
printf 'version: 2\nrenderer: networkd\n' >"$root/var/lib/cloud/seed/nocloud/network-config"
CHROMIUM_WEBGPU_BACKEND=gles-compat "$PROJECT_DIR/scripts/install-xfce.sh" "$root"
[[ "$(readlink "$root/etc/systemd/system/display-manager.service")" == */lightdm.service ]] || fail 'LightDM was not selected'
[[ "$(readlink "$root/etc/systemd/system/default.target")" == */graphical.target ]] || fail 'graphical target is missing'
grep -Fxq 'renderer: NetworkManager' "$root/var/lib/cloud/seed/nocloud/network-config" || fail 'network renderer was not migrated'
grep -Fxq 'xserver-command=X -s 0 -dpms' "$root/etc/lightdm/lightdm.conf.d/40-ubuntu-xfce.conf" || fail 'blanking was not disabled'
grep -Fxq 'run_im fcitx5' "$root/etc/skel/.xinputrc" || fail 'Xsession IM selection is missing'
grep -Fxq 'gles-compat' "$root/etc/chromium/rockchip-webgpu-backend" || fail 'browser policy is missing'
[[ ! -e "$root/etc/gdm3" && ! -e "$root/etc/skel/.config/fcitx5/conf/notifications.conf" ]] || fail 'GNOME policy leaked into XFCE'
python3 - "$root" <<'PY'
from pathlib import Path
import sys,xml.etree.ElementTree as ET
root=Path(sys.argv[1])
tree=ET.parse(root/'etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-power-manager.xml')
assert tree.find(".//property[@name='dpms-enabled']").get('value')=='false'
assert tree.find(".//property[@name='blank-on-ac']").get('value')=='0'
PY
echo 'XFCE manifest, Xserver policy and Server/GNOME isolation checks passed'
