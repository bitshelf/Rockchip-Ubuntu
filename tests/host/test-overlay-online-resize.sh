#!/usr/bin/env bash
set -Eeuo pipefail
(( EUID == 0 )) || { echo 'Run as root in a private mount namespace' >&2; exit 2; }
if [[ "${1:-}" != --namespace ]]; then
    exec unshare --mount --propagation private "$0" --namespace
fi
tmp="$(mktemp -d)"
loop=""
cleanup() {
    mountpoint -q "$tmp/mount" && umount "$tmp/mount"
    [[ -z "$loop" ]] || losetup -d "$loop"
    rm -rf -- "$tmp"
}
trap cleanup EXIT
truncate -s 64M "$tmp/userdata.img"
mkfs.ext4 -q -F -L userdata "$tmp/userdata.img"
e2fsck -pf "$tmp/userdata.img"
# Model the timestamp relation observed after initramfs fsck with an invalid
# RTC. The filesystem is clean, but its stored mount time is after lastcheck.
debugfs -w -R 'set_super_value mtime 2000000000' "$tmp/userdata.img" >/dev/null 2>&1
if resize2fs "$tmp/userdata.img" >"$tmp/offline.log" 2>&1; then
    echo 'FAIL: fixture did not reproduce offline resize rejection' >&2; exit 1
fi
grep -Fq "Please run 'e2fsck -f" "$tmp/offline.log"
truncate -s 96M "$tmp/userdata.img"
loop="$(losetup --find --show "$tmp/userdata.img")"
mkdir "$tmp/mount"
mount -t ext4 "$loop" "$tmp/mount"
printf 'persistent upper\n' >"$tmp/mount/sentinel"
resize2fs "$loop"
[[ "$(cat "$tmp/mount/sentinel")" == 'persistent upper' ]]
umount "$tmp/mount"
blocks="$(dumpe2fs -h "$loop" 2>/dev/null | awk -F: '$1=="Block count" {print $2}')"
size="$(dumpe2fs -h "$loop" 2>/dev/null | awk -F: '$1=="Block size" {print $2}')"
(( blocks * size >= 90 * 1024 * 1024 ))
e2fsck -fn "$loop"
echo 'OVERLAY_ONLINE_RESIZE_CLOCK_ROLLBACK_OK'
