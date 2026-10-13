#!/usr/bin/env bash
set -Eeuo pipefail
rootfs="${1:-}"
[[ "$rootfs" == /* && "$rootfs" != / && -d "$rootfs" && ! -L "$rootfs" ]] || {
    echo 'ERROR: rootfs must be an absolute directory other than /' >&2; exit 2;
}
# A Server image never gains a desktop through this installer.
[[ -x "$rootfs/usr/bin/gnome-shell" ]] || exit 0
[[ -f "$rootfs/usr/lib/systemd/system/gdm.service" ||
   -f "$rootfs/lib/systemd/system/gdm.service" ]] || {
    echo 'ERROR: GNOME rootfs has no GDM unit' >&2; exit 1;
}
[[ -s "$rootfs/usr/share/wayland-sessions/ubuntu.desktop" ]] || {
    echo 'ERROR: Ubuntu Wayland session is missing' >&2; exit 1;
}
systemctl --root="$rootfs" enable gdm.service
systemctl --root="$rootfs" set-default graphical.target
install -D -m 0644 \
    "$(dirname "${BASH_SOURCE[0]}")/../config/desktop/10-firstboot-greeter.conf" \
    "$rootfs/etc/systemd/system/ubuntu-firstboot.service.d/10-firstboot-greeter.conf"
# GDM uses its packaged Wayland policy. No autologin or manufacturing user.
install -d "$rootfs/etc/gdm3" "$rootfs/etc/X11"
printf '/usr/sbin/gdm3\n' >"$rootfs/etc/X11/default-display-manager"
schema_dir="$rootfs/usr/share/glib-2.0/schemas"
install -D -m 0644 \
    "$(dirname "${BASH_SOURCE[0]}")/../config/desktop/90-rockchip-desktop.gschema.override" \
    "$schema_dir/90-rockchip-desktop.gschema.override"
# Compiled GSettings data is architecture independent. The host tool also
# supports the x86/QEMU assembly path without invoking a target binary.
glib-compile-schemas --strict "$schema_dir"
install -D -m 0644 \
    "$(dirname "${BASH_SOURCE[0]}")/../config/desktop/fcitx5-notifications.conf" \
    "$rootfs/etc/skel/.config/fcitx5/conf/notifications.conf"

# The graphical network panel uses NetworkManager. Convert only the inherited
# wired seed; customer-provided NetworkManager policy is left intact.
network_seed="$rootfs/var/lib/cloud/seed/nocloud/network-config"
if [[ -f "$network_seed" ]]; then
    sed -i -E 's/^([[:space:]]*renderer:[[:space:]]*)networkd[[:space:]]*$/\1NetworkManager/' "$network_seed"
fi
systemctl --root="$rootfs" enable NetworkManager.service
systemctl --root="$rootfs" disable systemd-networkd.service systemd-networkd.socket

# Select a tested browser backend explicitly; each board supplies its policy.
backend="${CHROMIUM_WEBGPU_BACKEND:-auto}"
case "$backend" in
    auto) ;;
    gles-compat)
        install -D -m 0644 \
            "$(dirname "${BASH_SOURCE[0]}")/../config/desktop/chromium-webgpu-gles-compat" \
            "$rootfs/etc/chromium/rockchip-webgpu-backend"
        ;;
    *) echo "ERROR: invalid CHROMIUM_WEBGPU_BACKEND: $backend" >&2; exit 1 ;;
esac
