#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
rootfs="${1:-}"
asset_dir="${2:-}"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ "$rootfs" == /* && -d "$rootfs" && "$rootfs" != / ]] ||
    die "usage: $0 <absolute-rootfs> <absolute-platform-asset-directory>"
[[ "$asset_dir" == /* ]] ||
    die "usage: $0 <absolute-rootfs> <absolute-platform-asset-directory>"

deb="$("${SCRIPT_DIR}/find-local-deb.sh" "$asset_dir" gpu-runtime)"
package="$(dpkg-deb -f "$deb" Package)"
architecture="$(dpkg-deb -f "$deb" Architecture)"
[[ "$package" == libmali-* && "$architecture" == arm64 ]] ||
    die "gpu-runtime is not an ARM64 libmali package: $deb"

temporary="/tmp/$(basename "$deb")"
install -D -m 0644 "$deb" "$rootfs$temporary"
chroot "$rootfs" dpkg -i "$temporary"
rm -f -- "$rootfs$temporary"
chroot "$rootfs" ldconfig
chroot "$rootfs" apt-mark hold "$package"

install -D -m 0644 "${PROJECT_DIR}/package/libmali/60-dma-heap.rules" \
    "$rootfs/etc/udev/rules.d/60-dma-heap.rules"

egl_path="$(chroot "$rootfs" ldconfig -p | awk '$1 == "libEGL.so.1" { print $NF; exit }')"
[[ "$egl_path" == /usr/lib/aarch64-linux-gnu/mali/* ]] ||
    die "libEGL.so.1 does not resolve to libmali: ${egl_path:-missing}"
[[ -s "$rootfs/usr/lib/aarch64-linux-gnu/libmali.so.1" &&
   -s "$rootfs/etc/udev/rules.d/60-dma-heap.rules" ]] ||
    die "libmali installation is incomplete"

printf 'libmali.package=%s\n' "$package"
printf 'libmali.version=%s\n' "$(dpkg-deb -f "$deb" Version)"
