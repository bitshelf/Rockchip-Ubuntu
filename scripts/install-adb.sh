#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rootfs="${1:-}"

die() { echo "ERROR: $*" >&2; exit 1; }
[[ "$rootfs" == /* && -d "$rootfs" && "$rootfs" != / ]] ||
    die "usage: scripts/install-adb.sh <absolute-rootfs>"
[[ -x "$rootfs/usr/lib/android-sdk/platform-tools/adbd" ]] ||
    die "rootfs does not contain the Ubuntu adbd package"

# Ubuntu's Android adbd exports TMPDIR=/data/local/tmp to shell commands.
# Reuse the Linux temporary filesystem so mktemp and ADB push work there.
install -d -m 0755 "$rootfs/data/local"
if [[ ! -e "$rootfs/data/local/tmp" && ! -L "$rootfs/data/local/tmp" ]]; then
    ln -s /tmp "$rootfs/data/local/tmp"
fi

while IFS= read -r -d '' source; do
    relative="${source#"${PROJECT_DIR}/package/adb"}"
    mode=0644
    [[ "$relative" == /usr/libexec/rk-adbd-gadget ]] && mode=0755
    install -D -m "$mode" "$source" "$rootfs$relative"
done < <(find "${PROJECT_DIR}/package/adb" -type f -print0 | sort -z)

rm -f "$rootfs/etc/systemd/system/multi-user.target.wants/adbd.service"
install -d -m 0755 "$rootfs/etc/systemd/system/sysinit.target.wants"
ln -sfn ../adbd.service \
    "$rootfs/etc/systemd/system/sysinit.target.wants/adbd.service"
