#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

fail() { echo "FAIL: $*" >&2; exit 1; }
command -v modetest >/dev/null || fail "modetest is required (install libdrm-tests)"
busid="${DRM_BUSID:-display-subsystem}"
planes="$(modetest -M rockchip -D "$busid" -p 2>&1)" || fail "modetest could not query DRM planes"
# Every plane's enum lists Cursor, including Primary and Overlay planes.
# Only the current immutable type value identifies a cursor plane.
awk '
    /^[[:space:]]*[0-9]+ type:/ {in_type=1; next}
    in_type && /^[[:space:]]*value:/ {if ($2 == 2) found=1; in_type=0}
    END {exit !found}
' <<<"$planes" || fail "DRM exposes no cursor plane on $busid"
connectors="$(modetest -M rockchip -D "$busid" -c 2>&1)" || fail "connector query failed"
awk '$1 ~ /^[0-9]+$/ && $3 == "connected" {found=1} END {exit !found}' \
    <<<"$connectors" || fail "no connected DRM connector reported"

if [[ "${DRM_CURSOR_DESKTOP:-0}" == 1 ]]; then
    [[ -n "${WAYLAND_DISPLAY:-}" ]] || fail "DRM_CURSOR_DESKTOP=1 requires WAYLAND_DISPLAY"
    [[ -n "${XDG_SESSION_ID:-}" ]] || fail "run from the local GNOME user session"
    [[ "$(loginctl show-session "$XDG_SESSION_ID" -p Type --value)" == wayland &&
       "$(loginctl show-session "$XDG_SESSION_ID" -p Class --value)" == user &&
       "$(loginctl show-session "$XDG_SESSION_ID" -p Active --value)" == yes &&
       "$(loginctl show-session "$XDG_SESSION_ID" -p Remote --value)" == no &&
       "$(loginctl show-session "$XDG_SESSION_ID" -p User --value)" == "$(id -u)" ]] ||
        fail "not the active local Wayland user session"
    pgrep -u "$(id -u)" -x gnome-shell >/dev/null || fail "user has no GNOME Shell"
    command -v gsettings >/dev/null || fail "gsettings is required for desktop cursor QA"
    gsettings get org.gnome.desktop.interface cursor-size >/dev/null \
        || fail "GNOME cursor settings are unavailable"
    echo "DRM_CURSOR_DESKTOP_SESSION_OK display=$WAYLAND_DISPLAY"
fi
echo "DRM_CURSOR_PLANE_OK busid=$busid (capability only; hardware cursor use and visual QA pending)"
