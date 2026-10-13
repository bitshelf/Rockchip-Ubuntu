#!/usr/bin/env bash
set -Eeuo pipefail
mode="${1:-session}"
die() { echo "FAIL: $*" >&2; exit 1; }
[[ "$mode" == greeter || "$mode" == session ]] || die 'usage: test-gnome.sh [greeter|session]'
(( EUID == 0 )) || die 'run as root to inspect compositor devices'
# shellcheck disable=SC1091
source /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_ID" == 26.04 ]] || die 'not Ubuntu 26.04'
systemctl is-active --quiet display-manager.service || die 'display manager is not active'
[[ "$(readlink -f /etc/systemd/system/display-manager.service)" == */gdm.service ]] || die 'display manager is not GDM'
connected=0
enabled=0
for status in /sys/class/drm/card*-*/status; do
    [[ -f "$status" ]] || continue
    [[ "$(cat "$status")" != connected ]] || ((connected+=1))
    printf '%s=%s\n' "$status" "$(cat "$status")"
    if [[ "$(cat "$status")" == connected && -f "${status%/status}/enabled" &&
          "$(cat "${status%/status}/enabled")" == enabled ]]; then
        ((enabled+=1))
    fi
done
(( connected > 0 )) || die 'no connected physical display'
(( enabled > 0 )) || die 'connected displays are disabled or blanked'
expected_class=user
[[ "$mode" != greeter ]] || expected_class=greeter
found=0
while read -r session _; do
    [[ -n "$session" ]] || continue
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
    [[ "$class" == "$expected_class" && "$type" == wayland && "$active" == yes && "$remote" == no ]] || continue
    [[ "$uid" =~ ^[0-9]+$ ]] || continue
    while read -r pid; do
        [[ -n "$pid" ]] || continue
        maps="$(cat "/proc/$pid/maps")"
        ! grep -Ei 'swrast|kms_swrast|llvmpipe|softpipe' <<<"$maps" || die 'software renderer loaded by GNOME'
        grep -Ei 'libmali|panfrost|panthor|libgallium' <<<"$maps" || die 'GNOME has no graphics driver library'
        gpu_fd=0
        for fd in /proc/"$pid"/fd/*; do
            device="$(readlink "$fd" 2>/dev/null || true)"
            case "$device" in
                /dev/mali[0-9]*) gpu_fd=1;;
                /dev/dri/card*|/dev/dri/renderD*)
                    driver="$(basename "$(readlink -f "/sys/class/drm/${device##*/}/device/driver")")"
                    case "$driver" in panfrost|panthor) gpu_fd=1; printf 'gpu.device=%s driver=%s\n' "$device" "$driver";; esac
                    ;;
            esac
        done
        (( gpu_fd == 1 )) || die 'GNOME has no open GPU rendering device'
        printf 'session=%s class=%s type=%s uid=%s compositor.pid=%s\n' "$session" "$class" "$type" "$uid" "$pid"
        found=1
    done < <(pgrep -u "$uid" -x gnome-shell || true)
done < <(loginctl list-sessions --no-legend --no-pager)
(( found == 1 )) || die "no active local $expected_class GNOME Wayland session"
dpkg-query -W gdm3 gnome-shell ubuntu-session
echo "GNOME_${mode^^}_WAYLAND_GPU_OK"
