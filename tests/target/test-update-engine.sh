#!/usr/bin/env bash
set -Eeuo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
[[ "$(id -u)" -eq 0 ]] || die "run as root on the target"
command -v updateEngine >/dev/null || die "updateEngine is not installed"
[[ -d /dev/block/by-name ]] || die "missing /dev/block/by-name"

misc="$(updateEngine --misc=display 2>&1)" || die "cannot read misc BCB"
grep -q 'bootloader.command' <<<"$misc" || die "unexpected misc display output"
echo "UPDATE_ENGINE_READ_ONLY_CHECK_OK"
