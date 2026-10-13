#!/usr/bin/env bash
set -Eeuo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
for tool in mkfs.erofs fsck.erofs mkfs.ext4 e2fsck blkid; do
    command -v "$tool" >/dev/null || { echo "SKIP: firmware staging requires $tool"; exit 0; }
done
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
sdk="$work/sdk"
project="$sdk/ubuntu"
input="$work/input"
mkdir -p "$project/scripts" "$sdk/output/firmware" "$sdk/debian" "$input" "$work/lower"
cp "$repo/scripts/stage-sdk-firmware.sh" "$project/scripts/"
printf '#!/bin/sh\nexit 0\n' >"$sdk/build.sh"
chmod +x "$sdk/build.sh"
printf 'original SDK image\n' >"$sdk/debian/linaro-rootfs.img"
ln -s ../../debian/linaro-rootfs.img "$sdk/output/firmware/rootfs.img"
printf 'lower fixture\n' >"$work/lower/file"
mkfs.erofs "$input/rootfs.img" "$work/lower" >/dev/null
for name in boot userdata; do
    truncate -s 16M "$input/$name.img"
    mkfs.ext4 -q -F "$input/$name.img"
done
printf 'parameter fixture\n' >"$input/parameter.txt"
(cd "$input"; sha256sum boot.img rootfs.img userdata.img parameter.txt >SHA256SUMS)
SDK_DIR="$sdk" bash "$project/scripts/stage-sdk-firmware.sh" "$input" --check
[[ ! -e "$project/artifacts/ubuntu-rootfs.img" ]] || { echo 'check mutated output'; exit 1; }
SDK_DIR="$sdk" bash "$project/scripts/stage-sdk-firmware.sh" "$input"
[[ "$(readlink "$sdk/output/firmware/rootfs.img")" == ../../ubuntu/artifacts/ubuntu-rootfs.img ]]
cmp "$input/rootfs.img" "$sdk/output/firmware/rootfs.img"
grep -Fxq 'original SDK image' "$sdk/debian/linaro-rootfs.img"
printf 'corrupt\n' >>"$input/userdata.img"
if SDK_DIR="$sdk" bash "$project/scripts/stage-sdk-firmware.sh" "$input" >/dev/null 2>&1; then
    echo 'corrupt firmware passed staging'; exit 1
fi
cmp "$input/rootfs.img" "$project/artifacts/ubuntu-rootfs.img"
echo 'SDK firmware staging: artifact link, original image preservation and checksum rejection passed'
