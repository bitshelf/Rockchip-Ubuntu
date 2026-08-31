#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAGE_SCRIPT="${PROJECT_DIR}/scripts/stage-sdk-assets.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

sdk="${tmp_dir}/sdk"
output="${tmp_dir}/output"
soc=test-soc
release=6.99.1-test
install -d "$sdk/output/extlinux" \
    "$sdk/output/kernel-modules/lib/modules/${release}/kernel/drivers/test" \
    "$sdk/output/kernel-modules/lib/modules/${release}/kernel/drivers/unused"
printf 'kernel image\n' >"$sdk/output/extlinux/Image"
printf 'base dtb\n' >"$sdk/output/extlinux/board-under-test.dtb"
printf 'overlay\n' >"$sdk/output/extlinux/example.dtbo"
printf 'extlinux\n' >"$sdk/output/extlinux/extlinux.conf"
printf 'module\n' >"$sdk/output/kernel-modules/lib/modules/${release}/kernel/drivers/test/test.ko"
printf 'unused module\n' \
    >"$sdk/output/kernel-modules/lib/modules/${release}/kernel/drivers/unused/unused.ko"
module_config="${tmp_dir}/modules.conf"
printf '%s\n' 'MODULE_ENTRIES=(' \
    '    "drivers/test/test.ko|kernel/drivers/test|test"' \
    ')' >"$module_config"

SDK_DIR="$sdk" BUILD_OUTPUT_DIR="$output" SOC_MODEL="$soc" \
    KERNEL_MODULE_CONFIG="$module_config" \
    "$STAGE_SCRIPT"
asset_dir="${output}/platform-assets/${soc}"
[[ "$(stat -c %a "$asset_dir")" == 2750 ]] ||
    fail "platform asset root is not readable by the build group"
[[ -s "$asset_dir/boot/Image" ]] || fail "kernel Image was not staged"
[[ -s "$asset_dir/boot/board-under-test.dtb" ]] || fail "DTB was not staged"
[[ -s "$asset_dir/boot/example.dtbo" ]] || fail "DT overlay was not staged"
[[ -s "$asset_dir/modules/lib/modules/${release}/kernel/drivers/test/test.ko" ]] ||
    fail "selected kernel module was not staged"
[[ ! -e "$asset_dir/modules/lib/modules/${release}/kernel/drivers/unused/unused.ko" ]] ||
    fail "unselected kernel module was staged"
[[ "$(find "$asset_dir/modules" -type f -name '*.ko' | wc -l)" -eq 1 ]] ||
    fail "unexpected kernel module count"
[[ "$(<"$asset_dir/kernel-release")" == "$release" ]] ||
    fail "kernel release was not discovered from the SDK output"
SDK_DIR="$sdk" BUILD_OUTPUT_DIR="$output" SOC_MODEL="$soc" \
    KERNEL_MODULE_CONFIG="$module_config" \
    "$STAGE_SCRIPT" --check

printf 'tampered\n' >>"$asset_dir/boot/Image"
if SDK_DIR="$sdk" BUILD_OUTPUT_DIR="$output" SOC_MODEL="$soc" \
    KERNEL_MODULE_CONFIG="$module_config" \
    "$STAGE_SCRIPT" --check >"${tmp_dir}/tamper.log" 2>&1; then
    fail "checksum verification accepted a modified kernel Image"
fi

echo "SDK platform asset staging checks passed"
