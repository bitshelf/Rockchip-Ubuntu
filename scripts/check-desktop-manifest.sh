#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
variant="${1:-}" manifest="${2:-}"
[[ -s "$manifest" ]] || { echo 'ERROR: package manifest is missing' >&2; exit 1; }
case "$variant" in
    desktop)
        while read -r package rest; do
            [[ -n "$package" && "$package" != \#* ]] || continue
            awk -v p="$package" '$1 == p || $1 == p ":arm64" {found=1} END {exit !found}' "$manifest" || {
                echo "ERROR: GNOME package missing: $package" >&2; exit 1;
            }
        done <"$PROJECT_DIR/config/ubuntu-image/desktop.packages"
        ! awk '{print $1}' "$manifest" | grep -E '^(xfce4|xfwm4|lightdm|weston)([-:]|$)' || {
            echo 'ERROR: another desktop stack leaked into GNOME' >&2; exit 1;
        }
        ;;
    server)
        ! awk '{print $1}' "$manifest" | grep -E '^(gnome-shell|gdm3|ubuntu-session|xfce4|xfwm4|lightdm|weston|blueman|chromium|glmark2|mesa-utils)([-:]|$)' || {
            echo 'ERROR: desktop payload leaked into Server' >&2; exit 1;
        }
        ;;
    *) echo "ERROR: unknown variant: $variant" >&2; exit 2 ;;
esac
echo "Package boundary passed: $variant"
