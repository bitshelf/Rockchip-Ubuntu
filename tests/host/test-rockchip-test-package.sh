#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

source_dir="$tmp_dir/sdk/external/rockchip-test"
install -d "$source_dir/cpu" "$source_dir/gpu" "$source_dir/npu2/model/RK356X"
install -d "$source_dir/.git"
printf 'license\n' >"$source_dir/LICENSE"
printf 'ref: refs/heads/main\n' >"$source_dir/.git/HEAD"
for file in rockchip_test.sh cpu/cpu_test.sh gpu/gpu_test.sh npu2/npu_test.sh; do
    printf '#!/bin/bash\necho /data/rockchip-test /rockchip-test/\n' >"$source_dir/$file"
    chmod 0755 "$source_dir/$file"
done
printf 'model\n' >"$source_dir/npu2/model/RK356X/mobilenet_v1.rknn"

BUILD_OUTPUT_DIR="$tmp_dir/output" ROCKCHIP_TEST_SOURCE_DIR="$source_dir" \
    "$PROJECT_DIR/scripts/build-rockchip-test-package.sh" --check >/dev/null
BUILD_OUTPUT_DIR="$tmp_dir/output" ROCKCHIP_TEST_SOURCE_DIR="$source_dir" \
    "$PROJECT_DIR/scripts/build-rockchip-test-package.sh" >/dev/null
package="$(find "$tmp_dir/output/packages/rockchip-test" -type f -name '*.deb')"
[[ -s "$package" ]] || fail "package was not created"
[[ "$(dpkg-deb -f "$package" Architecture)" == all ]] || fail "package is not portable"
root="$tmp_dir/root"
install -d "$root"
dpkg-deb -x "$package" "$root"
[[ -x "$root/usr/bin/rockchip-test" && -x "$root/usr/libexec/rockchip-test-qa" ]] || fail "QA commands are missing"
[[ ! -e "$root/usr/lib/rockchip-test/.git" ]] || fail "source Git metadata was packaged"
grep -Fq '/var/lib/rockchip-test' "$root/usr/lib/rockchip-test/cpu/cpu_test.sh" || fail "state path was not ported"
! grep -Fq '/data/rockchip-test' "$root/usr/lib/rockchip-test/cpu/cpu_test.sh" || fail "legacy state path remains"
grep -Fq 'profile.server-headless' "$root/usr/libexec/rockchip-test-qa" || fail "Server profile is missing"
grep -Fq 'profile.desktop-display-manager' "$root/usr/libexec/rockchip-test-qa" || fail "Desktop profile is missing"
grep -Fq 'device.adb-host-network' "$root/usr/libexec/rockchip-test-qa" || fail "ADB host-network QA is missing"

echo "Rockchip test Debian package checks passed"
