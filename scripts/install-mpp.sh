#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
rootfs="${1:-}"
asset_dir="${2:-}"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ "$rootfs" == /* && -d "$rootfs" && "$rootfs" != / &&
   "$asset_dir" == /* ]] ||
    die "usage: $0 <absolute-rootfs> <absolute-platform-asset-directory>"

runtime_deb="$("${SCRIPT_DIR}/find-local-deb.sh" "$asset_dir" mpp-runtime)"
vpu_deb="$("${SCRIPT_DIR}/find-local-deb.sh" "$asset_dir" mpp-vpu-runtime)"
demos_deb="$("${SCRIPT_DIR}/find-local-deb.sh" "$asset_dir" mpp-qa-tools)"
packages=(librockchip-mpp1 librockchip-vpu0 rockchip-mpp-demos)
debs=("$runtime_deb" "$vpu_deb" "$demos_deb")
temporary_debs=()
cleanup() {
    local temporary
    for temporary in "${temporary_debs[@]}"; do
        rm -f -- "$rootfs$temporary"
    done
}
trap cleanup EXIT

for index in "${!debs[@]}"; do
    [[ "$(dpkg-deb -f "${debs[$index]}" Package)" == "${packages[$index]}" &&
       "$(dpkg-deb -f "${debs[$index]}" Architecture)" == arm64 ]] ||
        die "unexpected MPP ARM64 package: ${debs[$index]}"
    temporary="/tmp/$(basename "${debs[$index]}")"
    install -D -m 0644 "${debs[$index]}" "$rootfs$temporary"
    temporary_debs+=("$temporary")
    debs[$index]="$temporary"
done

chroot "$rootfs" dpkg -i "${debs[@]}"
cleanup
temporary_debs=()
chroot "$rootfs" ldconfig
chroot "$rootfs" apt-mark hold "${packages[@]}"

install -D -m 0644 "${PROJECT_DIR}/package/mpp/99-rockchip-mpp.rules" \
    "$rootfs/etc/udev/rules.d/99-rockchip-mpp.rules"
install -D -m 0755 "${PROJECT_DIR}/tests/target/test-mpp.sh" \
    "$rootfs/usr/libexec/ubuntu-mpp-qa"

[[ -s "$rootfs/usr/lib/aarch64-linux-gnu/librockchip_mpp.so.0" &&
   -x "$rootfs/usr/bin/mpi_enc_test" &&
   -x "$rootfs/usr/bin/mpi_dec_test" &&
   -x "$rootfs/usr/libexec/ubuntu-mpp-qa" &&
   -s "$rootfs/etc/udev/rules.d/99-rockchip-mpp.rules" ]] ||
    die "MPP runtime installation is incomplete"

printf 'mpp.package=%s\n' "${packages[0]}"
printf 'mpp.version=%s\n' "$(dpkg-deb -f "$runtime_deb" Version)"
trap - EXIT
