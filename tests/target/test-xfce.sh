#!/usr/bin/env bash
set -Eeuo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
(( EUID == 0 )) || fail 'run as root to inspect Xorg device access'
source /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_ID" == 26.04 ]] || fail 'not Ubuntu 26.04'
systemctl is-active --quiet display-manager.service || fail 'display manager is inactive'
[[ "$(readlink -f /etc/systemd/system/display-manager.service)" == */lightdm.service ]] || fail 'display manager is not LightDM'
enabled=0
for status in /sys/class/drm/card*-*/status; do
    [[ -f "$status" ]] || continue
    printf '%s=%s\n' "$status" "$(cat "$status")"
    if [[ "$(cat "$status")" == connected && "$(cat "${status%/status}/enabled")" == enabled ]]; then
        ((enabled+=1))
    fi
done
(( enabled > 0 )) || fail 'no enabled physical display'
found=0
while read -r session _; do
    # A PAM/SSH session may disappear after list-sessions. Read one snapshot;
    # ignore only a vanished session, while retaining all desktop/GPU checks.
    properties="$(loginctl show-session "$session" -p Class -p Type -p Active -p Remote -p User 2>/dev/null)" || continue
    class= type= active= remote= uid=
    while IFS='=' read -r key value; do
        case "$key" in
            Class) class=$value;;
            Type) type=$value;;
            Active) active=$value;;
            Remote) remote=$value;;
            User) uid=$value;;
        esac
    done <<<"$properties"
    [[ "$class" == user && "$type" == x11 && "$active" == yes && "$remote" == no ]] || continue
    [[ "$uid" =~ ^[0-9]+$ ]] || continue
    user="$(getent passwd "$uid" | cut -d: -f1)"
    pid="$(pgrep -u "$uid" -x xfce4-session | sed -n 1p)"
    [[ -n "$pid" ]] || continue
    pgrep -u "$uid" -x xfwm4 >/dev/null || fail 'XFWM is absent'
    display="$(tr '\0' '\n' <"/proc/$pid/environ" | sed -n 's/^DISPLAY=//p')"
    authority="$(tr '\0' '\n' <"/proc/$pid/environ" | sed -n 's/^XAUTHORITY=//p')"
    [[ -n "$authority" ]] || authority="$(getent passwd "$uid" | cut -d: -f6)/.Xauthority"
    env_args=(DISPLAY="$display" XAUTHORITY="$authority" XDG_RUNTIME_DIR="/run/user/$uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus")
    renderer="$(runuser -u "$user" -- env "${env_args[@]}" glxinfo -B)"
    printf '%s\n' "$renderer"
    grep -Eiq 'Mali|Panfrost|Panthor|ARM' <<<"$renderer" || fail 'GLX is not using Mali hardware'
    ! grep -Eiq 'llvmpipe|softpipe|software rasterizer' <<<"$renderer" || fail 'GLX software fallback'
    power="$(runuser -u "$user" -- env "${env_args[@]}" xset q)"
    printf '%s\n' "$power"
    grep -Eq 'timeout:[[:space:]]+0' <<<"$power" || fail 'Xserver screen blanking is enabled'
    grep -Eq 'DPMS is Disabled|Server does not have the DPMS Extension' <<<"$power" || fail 'DPMS is enabled'
    printf 'session=%s uid=%s display=%s\n' "$session" "$uid" "$display"
    found=1
    break
done < <(loginctl list-sessions --no-legend --no-pager)
(( found == 1 )) || fail 'no active local XFCE Xserver session'
gpu_fd=0
display_fd=0
while read -r pid; do
    for fd in /proc/"$pid"/fd/*; do
        device="$(readlink "$fd" 2>/dev/null || true)"
        [[ "$device" == /dev/dri/* || "$device" == /dev/mali* ]] || continue
        driver="$(basename "$(readlink -f "/sys/class/drm/${device##*/}/device/driver" 2>/dev/null || true)")"
        if [[ "$driver" == rockchip || "$driver" == rockchip-drm ]]; then
            printf 'xorg.pid=%s display.device=%s driver=%s\n' "$pid" "$device" "$driver"
            display_fd=1
        fi
        [[ "$driver" == panfrost || "$driver" == panthor || "$device" == /dev/mali* ]] || continue
        printf 'xorg.pid=%s gpu.device=%s driver=%s\n' "$pid" "$device" "$driver"
        gpu_fd=1
    done
done < <(pgrep -x Xorg || true)
(( gpu_fd == 1 )) || fail 'Xorg has no Mali hardware device open'
(( display_fd == 1 )) || fail 'Xorg has no Rockchip KMS display device open'
dpkg-query -W lightdm xfce4-session xfwm4 xserver-xorg-core
echo 'XFCE_XSERVER_HARDWARE_OK'
