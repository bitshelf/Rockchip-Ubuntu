#!/usr/bin/env bash
set -Eeuo pipefail
rootfs="${1:?usage: $0 ROOTFS}"
source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../config/customization/fcitx5" && pwd)"
install -D -m 0644 "$source_root/profile" "$rootfs/etc/skel/.config/fcitx5/profile"
install -D -m 0644 "$source_root/org.fcitx.Fcitx5.desktop" \
  "$rootfs/etc/skel/.config/autostart/org.fcitx.Fcitx5.desktop"
install -D -m 0644 "$source_root/fcitx5.conf" \
  "$rootfs/etc/skel/.config/environment.d/fcitx5.conf"
rime_args=(--rootfs "$rootfs")
if [[ -n "${RIME_ICE_ARCHIVE:-}" ]]; then
  [[ "$RIME_ICE_ARCHIVE" == /* && -s "$RIME_ICE_ARCHIVE" ]] || {
    echo "invalid RIME_ICE_ARCHIVE: $RIME_ICE_ARCHIVE" >&2
    exit 1
  }
  rime_args+=(--archive "$RIME_ICE_ARCHIVE")
fi
[[ -z "${RIME_ICE_RESOLVED_URL:-}" ]] || rime_args+=(--resolved-url "$RIME_ICE_RESOLVED_URL")
python3 "$(dirname "${BASH_SOURCE[0]}")/install-rime-ice.py" "${rime_args[@]}"
grep -Fxq 'GTK_IM_MODULE=fcitx' "$rootfs/etc/skel/.config/environment.d/fcitx5.conf"
test -s "$rootfs/etc/skel/.local/share/fcitx5/rime/rime_ice.schema.yaml"
