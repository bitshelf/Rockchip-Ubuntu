#!/usr/bin/env bash
set -Eeuo pipefail
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/usr/share/alsa/ucm2" "$root/usr/share/wireplumber"
scripts/install-audio-customization.sh "$root"
test -s "$root/usr/share/alsa/ucm2/conf.d/rockchip-hdmi/rockchip-hdmi.conf"
grep -Fq 'monitor.alsa.rules' \
    "$root/usr/share/wireplumber/wireplumber.conf.d/51-rockchip-alsa-names.conf"
test -s tests/target/test-audio-real.sh
bash -n tests/target/test-audio-real.sh
echo "Audio UCM2/WirePlumber customization checks passed"
