#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
rootfs="${1:-}"
[[ "$rootfs" == /* && "$rootfs" != / && -d "$rootfs" && ! -L "$rootfs" ]] ||
    { echo "usage: $0 <rootfs-directory>" >&2; exit 2; }

# UCM2 is data, not a second mixer implementation.  Install the board
# profiles below alsa-ucm-conf's probe directory and leave unknown codecs to
# the upstream package.
source_root="$PROJECT_DIR/config/customization/audio"
install -d -m 0755 "$rootfs/usr/share/alsa/ucm2/conf.d"
cp -a "$source_root/ucm2/conf.d/." "$rootfs/usr/share/alsa/ucm2/conf.d/"

# WirePlumber 0.5 (Ubuntu Resolute/GNOME) loads declarative drop-ins from
# wireplumber.conf.d.  The Lua file is retained for older Noble images but is
# not installed into Resolute images by this helper.
install -D -m 0644 "$source_root/wireplumber/51-rockchip-alsa-names.conf" \
    "$rootfs/usr/share/wireplumber/wireplumber.conf.d/51-rockchip-alsa-names.conf"

test -s "$rootfs/usr/share/alsa/ucm2/conf.d/rockchip-hdmi/rockchip-hdmi.conf"
test -s "$rootfs/usr/share/wireplumber/wireplumber.conf.d/51-rockchip-alsa-names.conf"
