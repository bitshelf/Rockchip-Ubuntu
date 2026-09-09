#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
initramfs_script="${PROJECT_DIR}/config/overlay-root/initramfs/scripts/init-bottom/overlay-root"
initramfs_hook="${PROJECT_DIR}/config/overlay-root/initramfs/hooks/overlay-root"
fstab="${PROJECT_DIR}/config/overlay-root/fstab"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# These are literal implementation strings, not expressions for this shell.
# shellcheck disable=SC2016
grep -Fq 'e2fsck -pf "$OVERLAY_ROOT_DATA_DEVICE"' "$initramfs_script" ||
    fail "initramfs does not repair ext4 before mounting"
# shellcheck disable=SC2016
grep -Fq 'resize2fs "$OVERLAY_ROOT_DATA_DEVICE"' "$initramfs_script" ||
    fail "initramfs does not grow userdata to its partition"
grep -Fq 'refusing to format type:' "$initramfs_script" ||
    fail "unknown userdata filesystems are not rejected"
! grep -Eq '^[[:space:]]*mkfs(\.ext4)?[[:space:]]' "$initramfs_script" ||
    fail "initramfs can format persistent userdata"
# shellcheck disable=SC2016
grep -Fq 'upperdir=$data/upper,workdir=$data/work' "$initramfs_script" ||
    fail "whole-root OverlayFS layers are missing"
grep -Fq 'copy_file config /etc/overlay-root.conf /conf/overlay-root.conf' \
    "$initramfs_hook" || fail "initramfs configuration is not copied"
grep -Eq '^PARTLABEL=boot[[:space:]]+/boot[[:space:]]+ext4' "$fstab" ||
    fail "independent bootfs mount is missing"
! grep -Eq '^PARTLABEL=userdata[[:space:]]+' "$fstab" ||
    fail "fstab races initramfs for the userdata mount"

# Model an interrupted ext4 upper: mark the filesystem dirty, run the same
# preen policy used by initramfs, then grow it into a larger partition image.
userdata="${tmp_dir}/userdata.img"
e2fs_dir="$(dirname "$(command -v resize2fs)")"
for tool in mkfs.ext4 debugfs e2fsck dumpe2fs resize2fs; do
    [[ -x "${e2fs_dir}/${tool}" ]] || fail "incomplete e2fsprogs suite: ${e2fs_dir}"
done
truncate -s 64M "$userdata"
"${e2fs_dir}/mkfs.ext4" -q -F -L userdata "$userdata"
"${e2fs_dir}/debugfs" -w -R 'set_super_value state 0' "$userdata" >/dev/null 2>&1
set +e
"${e2fs_dir}/e2fsck" -pf "$userdata" >"${tmp_dir}/fsck.log" 2>&1
fsck_rc=$?
set -e
(( fsck_rc <= 1 )) || fail "dirty userdata recovery returned $fsck_rc"
"${e2fs_dir}/dumpe2fs" -h "$userdata" 2>/dev/null |
    grep -Eq '^Filesystem state:[[:space:]]+clean' ||
    fail "userdata did not return to a clean state"
truncate -s 96M "$userdata"
"${e2fs_dir}/resize2fs" "$userdata" >/dev/null
filesystem_blocks="$("${e2fs_dir}/dumpe2fs" -h "$userdata" 2>/dev/null |
    awk -F: '$1 == "Block count" {gsub(/[[:space:]]/, "", $2); print $2}')"
block_size="$("${e2fs_dir}/dumpe2fs" -h "$userdata" 2>/dev/null |
    awk -F: '$1 == "Block size" {gsub(/[[:space:]]/, "", $2); print $2}')"
(( filesystem_blocks * block_size >= 90 * 1024 * 1024 )) ||
    fail "userdata resize did not use the enlarged image"

echo "Overlay-root and power-loss recovery host checks passed"
