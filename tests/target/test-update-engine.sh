#!/usr/bin/env bash
set -Eeuo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
[[ "$(id -u)" -eq 0 ]] || die "run as root on the target"
command -v updateEngine >/dev/null || die "updateEngine is not installed"
[[ -d /dev/block/by-name ]] || die "missing /dev/block/by-name"

before="$(sha256sum /dev/block/by-name/misc)"
boot_id="$(cat /proc/sys/kernel/random/boot_id)"
# The display branch must remain read-only even with the reboot flag.
misc="$(updateEngine --misc=display --reboot 2>&1)" || die "cannot read misc BCB"
grep -q 'bootloader.command' <<<"$misc" || die "unexpected misc display output"
[[ "$before" == "$(sha256sum /dev/block/by-name/misc)" ]] || die "misc changed"
[[ "$boot_id" == "$(cat /proc/sys/kernel/random/boot_id)" ]] || die "unexpected reboot"
printf '%s\n' "$misc"
echo "UPDATE_ENGINE_READ_ONLY_CHECK_OK"
