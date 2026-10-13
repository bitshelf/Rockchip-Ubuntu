#!/usr/bin/env bash
# Stage verified ARM64 filesystem artifacts for the SDK's own updateimg hook.
set -Eeuo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die() { echo "ERROR: $*" >&2; exit 1; }
[[ $# -eq 1 || ( $# -eq 2 && $2 == --check ) ]] ||
    die 'usage: stage-sdk-firmware.sh <downloaded-firmware-directory> [--check]'
inputs="$(realpath "$1")"
SDK_DIR="${SDK_DIR:-$(dirname "$PROJECT_DIR")}"
firmware="$SDK_DIR/output/firmware"
rootfs_artifact="$PROJECT_DIR/artifacts/ubuntu-rootfs.img"
[[ -d "$inputs" && -s "$inputs/SHA256SUMS" ]] || die 'missing firmware directory or SHA256SUMS'
for tool in sha256sum blkid fsck.erofs e2fsck realpath install; do
    command -v "$tool" >/dev/null || die "missing staging dependency: $tool"
done
# Validate every required input before replacing any SDK artifact.
for file in boot.img rootfs.img userdata.img parameter.txt; do
    [[ -f "$inputs/$file" && ! -L "$inputs/$file" ]] || die "missing regular input: $file"
    checksum="$(awk -v name="$file" '$2 == name { print $1 }' "$inputs/SHA256SUMS")"
    [[ "$checksum" =~ ^[a-f0-9]{64}$ ]] || die "missing or ambiguous checksum: $file"
    [[ "$(sha256sum "$inputs/$file" | cut -d' ' -f1)" == "$checksum" ]] || die "checksum mismatch: $file"
done
[[ "$(blkid -p -s TYPE -o value "$inputs/boot.img")" == ext4 ]] || die 'boot.img must be ext4'
[[ "$(blkid -p -s TYPE -o value "$inputs/rootfs.img")" == erofs ]] || die 'rootfs.img must be EROFS'
[[ "$(blkid -p -s TYPE -o value "$inputs/userdata.img")" == ext4 ]] || die 'userdata.img must be ext4'
fsck.erofs "$inputs/rootfs.img" >/dev/null || die 'EROFS integrity check failed'
for file in boot.img userdata.img; do
    e2fsck -fn "$inputs/$file" >/dev/null 2>&1 || die "ext4 integrity check failed: $file"
done
[[ -x "$SDK_DIR/build.sh" && -d "$firmware" ]] || die 'missing SDK layout'
[[ $# -eq 1 ]] || { echo 'SDK firmware staging inputs verified'; exit 0; }
backup="$SDK_DIR/output/ubuntu-firmware-backup/$(date +%s)-$$"
mkdir -p "$backup"
replace() {
    local src="$1" dst="$2" name="$3"
    if [[ -e "$dst" || -L "$dst" ]]; then mv -- "$dst" "$backup/$name"; fi
    install -m 0644 "$src" "${dst}.ubuntu-stage.$$"
    mv -- "${dst}.ubuntu-stage.$$" "$dst"
}
mkdir -p "$PROJECT_DIR/artifacts"
replace "$inputs/rootfs.img" "$rootfs_artifact" ubuntu-rootfs.img
replace "$inputs/boot.img" "$firmware/boot.img" boot.img
replace "$inputs/userdata.img" "$firmware/userdata.img" userdata.img
replace "$inputs/parameter.txt" "$firmware/parameter.txt" parameter.txt
if [[ -e "$firmware/rootfs.img" || -L "$firmware/rootfs.img" ]]; then
    mv -- "$firmware/rootfs.img" "$backup/rootfs.img"
fi
ln -s "$(realpath --relative-to="$firmware" "$rootfs_artifact")" "$firmware/rootfs.img"
printf 'staged=%s\nbackup=%s\n' "$firmware" "$backup"
echo 'Run the SDK ./build.sh updateimg after checking Loader, U-Boot, recovery and package-file.'
