#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cc_aarch64="${CC_AARCH64:-aarch64-linux-gnu-gcc}"
if ! command -v "$cc_aarch64" >/dev/null; then
    echo 'SKIP: Chromium DEB fixture test needs an AArch64 C compiler'
    exit 0
fi
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
payload="$tmp/out/chromium/payload/usr/lib/chromium-browser"
mkdir -p "$payload"
printf 'int main(void) { return 0; }\n' >"$tmp/main.c"
"$cc_aarch64" "$tmp/main.c" -o "$payload/chrome"
CROSS_OUTPUT_DIR="$tmp/out" CHROMIUM_VERSION=153.0.8010.36 "$root/package/chromium/pack-deb.sh"
deb="$tmp/out/packages/chromium/chromium_153.0.8010.36_arm64.deb"
[[ "$(dpkg-deb -f "$deb" Architecture)" == arm64 ]]
dpkg-deb -x "$deb" "$tmp/extract"
readelf -h "$tmp/extract/usr/lib/chromium-browser/chrome" | grep -q AArch64
# Make the fixture foreign on both x86_64 and native ARM64 hosts.  The ELF
# e_machine field is two bytes at offset 18; EM_X86_64 is 62 (little-endian).
cp "$payload/chrome" "$payload/foreign-helper"
printf '\076\000' | dd of="$payload/foreign-helper" bs=1 seek=18 conv=notrunc \
    status=none
readelf -h "$payload/foreign-helper" | grep -q 'Advanced Micro Devices X86-64'
if CROSS_OUTPUT_DIR="$tmp/out" CHROMIUM_VERSION=153.0.8010.36 "$root/package/chromium/pack-deb.sh" >"$tmp/rejected" 2>&1; then
    echo 'FAIL: foreign architecture accepted' >&2; exit 1
fi
grep -q non-AArch64 "$tmp/rejected"
echo 'Chromium DEB fixture and foreign-ELF rejection passed (not a browser build)'
