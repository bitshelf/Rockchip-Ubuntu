#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAGE_SCRIPT="${PROJECT_DIR}/scripts/stage-sdk-assets.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

make_test_deb() {
    local architecture="$1" output_deb="$2" headers_release="${3:-$release}"
    local package_root="${tmp_dir}/deb-${architecture}"
    install -d "${package_root}/DEBIAN" "${package_root}/usr/share/test-headers"
    printf '%s\n' \
        'Package: linux-headers-test' \
        'Version: 1.0-test' \
        "Architecture: ${architecture}" \
        'Maintainer: Test <test@example.invalid>' \
        'Description: test kernel headers' >"${package_root}/DEBIAN/control"
    printf 'header\n' >"${package_root}/usr/share/test-headers/header.h"
    rm -rf "${package_root}/usr/src"
    install -d "${package_root}/usr/src/linux-headers-${headers_release}/include/config"
    printf '%s\n' "$headers_release" >"${package_root}/usr/src/linux-headers-${headers_release}/include/config/kernel.release"
    dpkg-deb --build --root-owner-group "$package_root" "$output_deb" >/dev/null
}

sdk="${tmp_dir}/sdk"
output="${tmp_dir}/output"
soc=test-soc
release=6.99.1-test
install -d "$sdk/output/extlinux" \
    "$sdk/kernel" \
    "$sdk/output/linux-headers" \
    "$sdk/output/kernel-modules/lib/modules/${release}/kernel/drivers/test" \
    "$sdk/output/kernel-modules/lib/modules/${release}/kernel/drivers/unused"
printf 'kernel image\n' >"$sdk/output/extlinux/Image"
printf 'base dtb\n' >"$sdk/output/extlinux/board-under-test.dtb"
printf 'overlay\n' >"$sdk/output/extlinux/example.dtbo"
printf 'extlinux\n' >"$sdk/output/extlinux/extlinux.conf"
python3 "$PROJECT_DIR/tests/host/make-kernel-module-fixture.py" \
    "$sdk/output/kernel-modules/lib/modules/${release}/kernel/drivers/test/test.ko" "$release"
printf 'unused module\n' \
    >"$sdk/output/kernel-modules/lib/modules/${release}/kernel/drivers/unused/unused.ko"
cp "${PROJECT_DIR}/config/kernel/overlay-root.conf" "$sdk/kernel/.config"
printf 'kernel/fs/erofs/erofs.ko\n' \
    >"$sdk/output/kernel-modules/lib/modules/${release}/modules.builtin"
printf 'kernel/fs/erofs/erofs.ko: alias=fs-erofs\n' \
    >"$sdk/output/kernel-modules/lib/modules/${release}/modules.builtin.modinfo"
make_test_deb arm64 "$sdk/output/linux-headers/linux-headers-test_arm64.deb"
make_test_deb amd64 "$sdk/output/linux-headers/linux-headers-test_amd64.deb"
module_config="${tmp_dir}/modules.conf"
printf '%s\n' 'MODULE_ENTRIES=(' \
    '    "drivers/test/test.ko|kernel/drivers/test|test"' \
    ')' >"$module_config"
deb_config="${tmp_dir}/packages.conf"
printf '%s\n' 'DEB_ENTRIES=(' \
    '    "linux-headers/*_arm64.deb|arm64|kernel-headers"' \
    ')' >"$deb_config"
grep -Fq 'linux-headers/*_arm64.deb|arm64|kernel-headers' \
    "${PROJECT_DIR}/config/local-debs/packages.conf" ||
    fail "repository local DEB selection does not include ARM64 kernel headers"
bad_deb_config="${tmp_dir}/bad-packages.conf"
printf '%s\n' 'DEB_ENTRIES=(' \
    '    "linux-headers/*_amd64.deb|arm64|kernel-headers"' \
    ')' >"$bad_deb_config"
if SDK_DIR="$sdk" BUILD_OUTPUT_DIR="${tmp_dir}/bad-output" SOC_MODEL="$soc" \
    SDK_KERNEL_CONFIG="$sdk/kernel/.config" \
    KERNEL_MODULE_CONFIG="$module_config" LOCAL_DEB_CONFIG="$bad_deb_config" \
    "$STAGE_SCRIPT" >"${tmp_dir}/bad-architecture.log" 2>&1; then
    fail "amd64 local DEB was accepted as an ARM64 input"
fi

install -d "$tmp_dir/iq"
printf '{"test_calibration":true}\n' >"$tmp_dir/iq/test_default_default.json"
CAMERA_IQ_DIR="$tmp_dir/iq" SDK_DIR="$sdk" BUILD_OUTPUT_DIR="$output" SOC_MODEL="$soc" \
    SDK_KERNEL_CONFIG="$sdk/kernel/.config" \
    KERNEL_MODULE_CONFIG="$module_config" LOCAL_DEB_CONFIG="$deb_config" \
    "$STAGE_SCRIPT"
asset_dir="${output}/platform-assets/${soc}"
cmp "$tmp_dir/iq/test_default_default.json" "$asset_dir/iqfiles/test_default_default.json" ||
    fail "selected camera calibration was not preserved"
grep -Fq './iqfiles/test_default_default.json' "$asset_dir/SHA256SUMS" ||
    fail "camera calibration is not covered by the asset checksum manifest"
grep -Fxq 'schema=ubuntu-platform-assets-v4' \
    "$asset_dir/.platform-asset-root" || fail "platform asset schema was not upgraded"
[[ "$(stat -c %a "$asset_dir")" == 2750 ]] ||
    fail "platform asset root is not readable by the build group"
[[ -s "$asset_dir/boot/Image" ]] || fail "kernel Image was not staged"
[[ -s "$asset_dir/boot/board-under-test.dtb" ]] || fail "DTB was not staged"
[[ -s "$asset_dir/boot/example.dtbo" ]] || fail "DT overlay was not staged"
[[ -s "$asset_dir/boot/kernel.config" ]] || fail "kernel config was not staged"
"${PROJECT_DIR}/scripts/check-kernel-config.sh" \
    "$asset_dir/boot/kernel.config" >/dev/null
[[ -s "$asset_dir/modules/lib/modules/${release}/modules.builtin" ]] ||
    fail "modules.builtin was not staged"
[[ -s "$asset_dir/modules/lib/modules/${release}/kernel/drivers/test/test.ko" ]] ||
    fail "selected kernel module was not staged"
[[ ! -e "$asset_dir/modules/lib/modules/${release}/kernel/drivers/unused/unused.ko" ]] ||
    fail "unselected kernel module was staged"
[[ "$(find "$asset_dir/modules" -type f -name '*.ko' | wc -l)" -eq 1 ]] ||
    fail "unexpected kernel module count"
[[ "$(<"$asset_dir/kernel-release")" == "$release" ]] ||
    fail "kernel release was not discovered from the SDK output"
headers_deb="$asset_dir/debs/linux-headers-test_arm64.deb"
[[ -s "$headers_deb" ]] || fail "selected ARM64 local DEB was not staged"
[[ ! -e "$asset_dir/debs/linux-headers-test_amd64.deb" ]] ||
    fail "unselected amd64 local DEB was staged"
grep -Fq $'linux-headers/linux-headers-test_arm64.deb\tlinux-headers-test_arm64.deb\tlinux-headers-test\t1.0-test\tarm64\tkernel-headers' \
    "$asset_dir/local-deb-manifest.tsv" || fail "local DEB manifest is incomplete"
SDK_DIR="$sdk" BUILD_OUTPUT_DIR="$output" SOC_MODEL="$soc" \
    SDK_KERNEL_CONFIG="$sdk/kernel/.config" \
    KERNEL_MODULE_CONFIG="$module_config" LOCAL_DEB_CONFIG="$deb_config" \
    "$STAGE_SCRIPT" --check

checker="$PROJECT_DIR/scripts/check-kernel-assets.py"
if python3 "$checker" --release 6.98.1-test \
        --module "$asset_dir/modules/lib/modules/$release/kernel/drivers/test/test.ko" \
        >"$tmp_dir/stale-module.log" 2>&1; then
    fail "valid ARM64 module from another kernel was accepted"
fi
if python3 "$checker" --release 6.98.1-test --headers "$headers_deb" \
        >"$tmp_dir/stale-headers.log" 2>&1; then
    fail "valid ARM64 headers from another kernel were accepted"
fi
foreign_module="$tmp_dir/foreign.ko"
python3 "$PROJECT_DIR/tests/host/make-kernel-module-fixture.py" "$foreign_module" "$release"
python3 - "$foreign_module" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
data = bytearray(path.read_bytes())
data[18:20] = (62).to_bytes(2, 'little')  # x86-64, same release string
path.write_bytes(data)
PY
if python3 "$checker" --release "$release" --module "$foreign_module" \
        >"$tmp_dir/foreign-module.log" 2>&1; then
    fail "x86-64 module with matching release was accepted"
fi

bundle="${tmp_dir}/artifacts/platform-assets-${soc}.tar.zst"
BUILD_OUTPUT_DIR="$output" SOC_MODEL="$soc" PLATFORM_ASSET_DIR="$asset_dir" \
    "${PROJECT_DIR}/scripts/pack-platform-assets.sh" "$bundle" >/dev/null
[[ -s "$bundle" && -s "${bundle}.sha256" ]] ||
    fail "platform asset bundle was not created"
mv "$asset_dir" "${asset_dir}.before-fetch"
BUILD_OUTPUT_DIR="$output" SOC_MODEL="$soc" PLATFORM_ASSET_DIR="$asset_dir" \
    "${PROJECT_DIR}/scripts/fetch-platform-assets.sh" "$bundle" >/dev/null
[[ -s "$asset_dir/boot/Image" && -s "$asset_dir/SHA256SUMS" ]] ||
    fail "downloaded platform assets were not installed"
cmp "$asset_dir/local-deb-manifest.tsv" \
    "${asset_dir}.before-fetch/local-deb-manifest.tsv" >/dev/null ||
    fail "platform asset bundle changed its manifest"

make_test_deb arm64 "$tmp_dir/stale-headers.deb" 6.98.1-test
cp "$tmp_dir/stale-headers.deb" "$headers_deb"
(
    cd "$asset_dir"
    find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS
)
if SDK_DIR="$sdk" BUILD_OUTPUT_DIR="$output" SOC_MODEL="$soc" \
    SDK_KERNEL_CONFIG="$sdk/kernel/.config" \
    KERNEL_MODULE_CONFIG="$module_config" LOCAL_DEB_CONFIG="$deb_config" \
    "$STAGE_SCRIPT" --check >"$tmp_dir/stale-bundle.log" 2>&1; then
    fail "checksummed bundle with stale headers was accepted"
fi
# Re-staging valid SDK outputs must repair a checksummed old generation.
SDK_DIR="$sdk" BUILD_OUTPUT_DIR="$output" SOC_MODEL="$soc" \
    SDK_KERNEL_CONFIG="$sdk/kernel/.config" \
    KERNEL_MODULE_CONFIG="$module_config" LOCAL_DEB_CONFIG="$deb_config" \
    "$STAGE_SCRIPT" >"$tmp_dir/restage.log" 2>&1
python3 "$checker" --release "$release" --headers "$headers_deb" >/dev/null

printf 'tampered\n' >>"$headers_deb"
if SDK_DIR="$sdk" BUILD_OUTPUT_DIR="$output" SOC_MODEL="$soc" \
    SDK_KERNEL_CONFIG="$sdk/kernel/.config" \
    KERNEL_MODULE_CONFIG="$module_config" LOCAL_DEB_CONFIG="$deb_config" \
    "$STAGE_SCRIPT" --check >"${tmp_dir}/tamper.log" 2>&1; then
    fail "checksum verification accepted a modified local DEB"
fi

echo "SDK platform asset staging checks passed"
