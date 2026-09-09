#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
work="$(mktemp -d)"
cleanup() { rm -rf -- "$work"; }
trap cleanup EXIT
rootfs="$work/test.rootfs.erofs.img"
bootfs="$work/test.bootfs.img"
parameter="$work/parameter.txt"
truncate -s 1536M "$rootfs"
truncate -s 256M "$bootfs"
"$PROJECT_DIR/scripts/generate-factory-parameter.sh" \
    "$rootfs" "$bootfs" "$parameter" >/dev/null

grep -Eq '^CMDLINE: mtdparts=:.*\(boot\),.*\(recovery\),.*\(backup\),.*\(rootfs\),-@.*\(userdata:grow\)$' \
    "$parameter" || fail "factory partition order is invalid"
[[ "$(grep -o '(boot)' "$parameter" | wc -l)" -eq 1 ]] ||
    fail "factory parameter must contain exactly one boot partition"
! grep -q '(bootfs)' "$parameter" || fail "duplicate bootfs partition remains"
grep -q '0x00080000@0x00008000(boot)' "$parameter" ||
    fail "boot capacity does not match its filesystem image"
grep -q '0x00040000@0x00088000(recovery)' "$parameter" ||
    fail "recovery was not relocated after boot"
grep -q '0x00300000@0x000d8000(rootfs)' "$parameter" ||
    fail "rootfs capacity or offset is wrong"
! grep -q '(overlay' "$parameter" || fail "legacy overlay partition remains"

parameter_sha="$(sha256sum "$parameter" | awk '{print $1}')"
"$PROJECT_DIR/scripts/generate-factory-parameter.sh" \
    "$rootfs" "$bootfs" "$work/parameter.second" >/dev/null
[[ "$(sha256sum "$work/parameter.second" | awk '{print $1}')" == "$parameter_sha" ]] ||
    fail "factory parameter generation is not deterministic"

echo "Factory layout checks passed"
