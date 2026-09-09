#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rootfs="${1:-}"
asset_dir="${2:-}"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ "$rootfs" == /* && -d "$rootfs" && "$rootfs" != / &&
   "$asset_dir" == /* ]] ||
    die "usage: $0 <absolute-rootfs> <absolute-platform-asset-directory>"

runtime_deb="$("${SCRIPT_DIR}/find-local-deb.sh" "$asset_dir" rga-runtime)"
development_deb="$("${SCRIPT_DIR}/find-local-deb.sh" "$asset_dir" rga-development)"
runtime_package="$(dpkg-deb -f "$runtime_deb" Package)"
development_package="$(dpkg-deb -f "$development_deb" Package)"
[[ "$runtime_package" == librga2 &&
   "$development_package" == librga-dev &&
   "$(dpkg-deb -f "$runtime_deb" Architecture)" == arm64 &&
   "$(dpkg-deb -f "$development_deb" Architecture)" == arm64 ]] ||
    die "RGA assets are not the expected ARM64 librga packages"

smoke="$(mktemp)"
trap 'rm -f -- "$smoke"' EXIT
"${SCRIPT_DIR}/build-rga-smoke.sh" "$asset_dir" "$smoke" >/dev/null

temporary="/tmp/$(basename "$runtime_deb")"
install -D -m 0644 "$runtime_deb" "$rootfs$temporary"
chroot "$rootfs" dpkg -i "$temporary"
rm -f -- "$rootfs$temporary"
chroot "$rootfs" ldconfig
chroot "$rootfs" apt-mark hold "$runtime_package"
install -D -m 0755 "$smoke" "$rootfs/usr/libexec/ubuntu-rga-smoke"

[[ -s "$rootfs/usr/lib/aarch64-linux-gnu/librga.so.2" &&
   -x "$rootfs/usr/libexec/ubuntu-rga-smoke" ]] ||
    die "RGA runtime installation is incomplete"
printf 'rga.package=%s\n' "$runtime_package"
printf 'rga.version=%s\n' "$(dpkg-deb -f "$runtime_deb" Version)"
