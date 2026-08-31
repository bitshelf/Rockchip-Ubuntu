#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_SCRIPT="${PROJECT_DIR}/scripts/build-server.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

mapfile -d '' -t definitions < <(
    find "${PROJECT_DIR}/config/ubuntu-image" -maxdepth 1 -type f \
        -name '*-server-arm64.yaml.in' -print0 | sort -z
)
(( ${#definitions[@]} == 1 )) ||
    fail "expected one Server ARM64 definition, found ${#definitions[@]}"
DEFINITION="${definitions[0]}"

output="$(BUILD_OUTPUT_DIR="${tmp_dir}/build" UBUNTU_IMAGE=/bin/true \
    "$BUILD_SCRIPT" --check)"
image="$(sed -n 's/^image=//p' <<<"$output")"
IFS=/ read -r series version variant architecture extra <<<"$image"
[[ -n "$series" && -n "$version" && "$variant" == server &&
    "$architecture" == arm64 && -z "$extra" ]] ||
    fail "invalid Server ARM64 image selection: $image"
grep -Fq "output=${tmp_dir}/build" <<<"$output" ||
    fail "BUILD_OUTPUT_DIR environment override was not honored"
mirror="$(sed -n 's/^mirror=//p' <<<"$output")"
[[ "$mirror" == https://*/ubuntu-ports/ ]] ||
    fail "invalid default Ubuntu ports mirror: $mirror"
grep -Fq '@UBUNTU_PORTS_MIRROR@' "$DEFINITION" ||
    fail "rootfs mirror template placeholder is missing"
grep -Fq 'names: [rockchip-server]' "$DEFINITION" ||
    fail "product Server seed is missing"
seed="${PROJECT_DIR}/config/ubuntu-image/seeds/rockchip-server"
apt_policy="${PROJECT_DIR}/config/ubuntu-image/apt.conf"
grep -Fq 'rockchip-server: minimal' "$BUILD_SCRIPT" ||
    fail "product seed is not registered in the Canonical ubuntu seed repository"
for forbidden in linux-firmware linux-firmware-raspi unattended-upgrades \
        ubuntu-release-upgrader-core thunderbird libreoffice libreoffice-core; do
    grep -Fq " * !${forbidden}" "$seed" ||
        fail "source seed does not forbid ${forbidden}"
done
! grep -Fq 'ubuntu-server-minimal' "$seed" ||
    fail "ubuntu-server-minimal hard-depends on the forbidden release upgrader"
grep -Fq 'APT::Install-Recommends "false";' "$apt_policy" ||
    fail "rootfs package installation still follows recommends"
grep -Fq -- '--thru create_chroot' "$BUILD_SCRIPT" ||
    fail "build does not stop before rootfs package selection"
grep -Fq '99-rockchip-product-policy' "$BUILD_SCRIPT" ||
    fail "rootfs APT policy is not installed before package selection"
grep -Fq -- '--resume' "$BUILD_SCRIPT" ||
    fail "ubuntu-image state machine is not resumed after applying APT policy"
grep -Fq 'openssh-server' "$DEFINITION" ||
    fail "Server SSH package is missing"
grep -Fq 'device-tree-compiler' "$DEFINITION" ||
    fail "DTS overlay target validation tools are missing"
if grep -Eq '\$\{UI_OUTPUT\}/ubuntu-[0-9]' "$BUILD_SCRIPT"; then
    fail "ubuntu-image output names are hard-coded in the build script"
fi
grep -Fq 'find_single_artifact' "$BUILD_SCRIPT" ||
    fail "ubuntu-image outputs are not discovered from the output directory"
if grep -Eni 'erofs|overlayfs|dtbo|\.ko|weston|chromium|rime' "$DEFINITION"; then
    fail "a later feature leaked into the base Server definition"
fi
if BUILD_OUTPUT_DIR=relative UBUNTU_IMAGE=/bin/true "$BUILD_SCRIPT" --check \
    >"${tmp_dir}/relative.log" 2>&1; then
    fail "relative BUILD_OUTPUT_DIR was accepted"
fi

echo "Ubuntu 26 Server build checks passed"
