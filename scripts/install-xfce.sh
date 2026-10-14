#!/usr/bin/env bash
set -Eeuo pipefail
rootfs="${1:-}"
[[ "$rootfs" == /* && "$rootfs" != / && -d "$rootfs" && ! -L "$rootfs" ]] || {
    echo 'ERROR: rootfs must be an absolute directory other than /' >&2; exit 2;
}
[[ -x "$rootfs/usr/bin/xfce4-session" ]] || exit 0
project="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -s "$rootfs/usr/share/xsessions/xfce.desktop" &&
   -s "$rootfs/usr/lib/systemd/system/lightdm.service" ]] || {
    echo 'ERROR: XFCE Xserver session or LightDM unit is missing' >&2; exit 1;
}
systemctl --root="$rootfs" enable lightdm.service
systemctl --root="$rootfs" set-default graphical.target
install -D -m 0644 "$project/config/desktop/10-firstboot-greeter.conf" \
    "$rootfs/etc/systemd/system/ubuntu-firstboot.service.d/10-firstboot-greeter.conf"
install -D -m 0644 "$project/config/desktop/xfce/lightdm.conf" \
    "$rootfs/etc/lightdm/lightdm.conf.d/40-ubuntu-xfce.conf"
install -D -m 0644 "$project/config/desktop/xfce/20-rockchip-display.conf" \
    "$rootfs/etc/X11/xorg.conf.d/20-rockchip-display.conf"
install -D -m 0644 "$project/config/desktop/xfce/power-manager.xml" \
    "$rootfs/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-power-manager.xml"
install -D -m 0644 "$project/config/desktop/xfce/session-policy.desktop" \
    "$rootfs/etc/xdg/autostart/ubuntu-xfce-session-policy.desktop"
install -D -m 0755 "$project/package/xfce/usr/libexec/ubuntu-xfce-session-policy" \
    "$rootfs/usr/libexec/ubuntu-xfce-session-policy"
# Ubuntu's xfdesktop default names a Xubuntu artwork file that is absent
# from this minimal package set. Reuse xfdesktop4-data's bundled wallpaper.
wallpaper="$rootfs/usr/share/xfce4/backdrops/xubuntu-wallpaper.png"
if [[ ! -e "$wallpaper" && ! -L "$wallpaper" ]]; then
    [[ -s "$rootfs/usr/share/backgrounds/xfce/xfce-blue.jpg" ]] || {
        echo 'ERROR: bundled XFCE wallpaper is missing' >&2; exit 1;
    }
    install -d "$(dirname "$wallpaper")"
    ln -s ../../backgrounds/xfce/xfce-blue.jpg "$wallpaper"
fi
install -d "$rootfs/etc/X11" "$rootfs/etc/skel"
printf '/usr/sbin/lightdm\n' >"$rootfs/etc/X11/default-display-manager"
printf 'run_im fcitx5\n' >"$rootfs/etc/skel/.xinputrc"
cat >"$rootfs/etc/skel/.xsessionrc" <<'SESSION'
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
SESSION
network_seed="$rootfs/var/lib/cloud/seed/nocloud/network-config"
if [[ -f "$network_seed" ]]; then
    sed -i -E 's/^([[:space:]]*renderer:[[:space:]]*)networkd[[:space:]]*$/\1NetworkManager/' "$network_seed"
fi
systemctl --root="$rootfs" enable NetworkManager.service
systemctl --root="$rootfs" disable systemd-networkd.service systemd-networkd.socket
case "${CHROMIUM_WEBGPU_BACKEND:-auto}" in
    auto) ;;
    gles-compat)
        install -D -m 0644 "$project/config/desktop/chromium-webgpu-gles-compat" \
            "$rootfs/etc/chromium/rockchip-webgpu-backend" ;;
    *) echo 'ERROR: invalid CHROMIUM_WEBGPU_BACKEND' >&2; exit 1 ;;
esac
