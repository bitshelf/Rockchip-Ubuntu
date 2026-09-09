#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_SCRIPT="${PROJECT_DIR}/scripts/build-bootfs.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

! grep -q '\.dtbo' \
    "${PROJECT_DIR}/config/bootfs/bootfs.conf" ||
    fail "bootfs policy still names a DT overlay"

asset_dir="${tmp_dir}/platform-assets/test-soc"
install -d "$asset_dir/boot" \
    "$asset_dir/modules/lib/modules/6.99-test/kernel/drivers/test" \
    "$asset_dir/debs"
printf 'schema=ubuntu-platform-assets-v4\n' >"$asset_dir/.platform-asset-root"
printf 'schema=ubuntu-platform-assets-v4\nsoc=test-soc\n' >"$asset_dir/asset-info"
printf 'kernel\n' >"$asset_dir/boot/Image"
cp "${PROJECT_DIR}/config/kernel/overlay-root.conf" "$asset_dir/boot/kernel.config"
printf '6.99-test\n' >"$asset_dir/kernel-release"
printf 'module\n' \
    >"$asset_dir/modules/lib/modules/6.99-test/kernel/drivers/test/test.ko"
printf 'drivers/test/test.ko\tkernel/drivers/test/test.ko\ttest\n' \
    >"$asset_dir/module-manifest.tsv"
printf 'kernel/fs/overlayfs/overlay.ko\n' \
    >"$asset_dir/modules/lib/modules/6.99-test/modules.builtin"
printf 'kernel/fs/overlayfs/overlay.ko: alias=fs-overlay\n' \
    >"$asset_dir/modules/lib/modules/6.99-test/modules.builtin.modinfo"

cat >"${tmp_dir}/base.dts" <<'EOF'
/dts-v1/;
/ { compatible = "test,board"; };
EOF
cat >"${tmp_dir}/overlay.dts" <<'EOF'
/dts-v1/;
/plugin/;
/ { fragment@0 { target-path = "/"; __overlay__ { test-property; }; }; };
EOF
cat >"${tmp_dir}/repository-overlay.dtso" <<'EOF'
/dts-v1/;
/plugin/;
/ {
    fragment@0 {
        target-path = "/";
        __overlay__ { ubuntu,repository-overlay = "compiled"; };
    };
};
EOF
dtc -q -I dts -O dtb -o "$asset_dir/boot/test-board.dtb" "${tmp_dir}/base.dts"
dtc -q -@ -I dts -O dtb -o "$asset_dir/boot/test-overlay.dtbo" \
    "${tmp_dir}/overlay.dts"

deb_root="${tmp_dir}/deb"
install -d "$deb_root/DEBIAN"
printf '%s\n' \
    'Package: test-headers' \
    'Version: 1-test' \
    'Architecture: arm64' \
    'Maintainer: Test <test@example.invalid>' \
    'Description: bootfs fixture' >"$deb_root/DEBIAN/control"
dpkg-deb --build --root-owner-group "$deb_root" \
    "$asset_dir/debs/test-headers_arm64.deb" >/dev/null
printf 'linux-headers/test-headers_arm64.deb\ttest-headers_arm64.deb\ttest-headers\t1-test\tarm64\tkernel-headers\n' \
    >"$asset_dir/local-deb-manifest.tsv"
(
    cd "$asset_dir"
    find . -type f ! -name SHA256SUMS -print0 | sort -z |
        xargs -0 sha256sum >SHA256SUMS
)

config="${tmp_dir}/bootfs.conf"
cat >"$config" <<'EOF'
BOOTFS_SIZE_MB=64
BOOTFS_LABEL=test-boot
BOOTFS_BASE_DTB=test-board.dtb
BOOTFS_INSTALLED_DTB=board.dtb
BOOTFS_TIMEOUT=5
BOOTFS_CMDLINE="root=PARTLABEL=test-root rootwait rw"
EOF
overlay_dir="${tmp_dir}/repository-dts"
install -d "$overlay_dir"
cp "${tmp_dir}/repository-overlay.dtso" "$overlay_dir/"
output="${tmp_dir}/output/images/test.bootfs.img"
BUILD_OUTPUT_DIR="${tmp_dir}/output" SOC_MODEL=test-soc \
    PLATFORM_ASSET_DIR="$asset_dir" BOOTFS_CONFIG="$config" \
    DTS_OVERLAY_DIR="$overlay_dir" \
    BOOTFS_OUTPUT="$output" "$BUILD_SCRIPT"
[[ -s "$output" ]] || fail "bootfs image was not created"
[[ -s "${output}.sha256" ]] || fail "bootfs checksum was not created"
[[ -s "${output}.build-info" ]] || fail "bootfs build evidence was not created"
grep -Fxq 'enabled.overlays=repository-overlay.dtbo' "${output}.build-info" ||
    fail "build evidence does not record the directory-selected overlay"
BUILD_OUTPUT_DIR="${tmp_dir}/output" SOC_MODEL=test-soc \
    PLATFORM_ASSET_DIR="${tmp_dir}/removed-platform-assets" \
    BOOTFS_CONFIG="$config" BOOTFS_TEMPLATE="${tmp_dir}/removed-template" \
    DTS_OVERLAY_DIR="$overlay_dir" \
    BOOTFS_INITRD="${tmp_dir}/removed-initrd" \
    BOOTFS_OUTPUT="$output" "$BUILD_SCRIPT" --check

extlinux="${tmp_dir}/extlinux.conf"
debugfs -R "dump /extlinux/extlinux.conf ${extlinux}" "$output" >/dev/null 2>&1
grep -Fq 'linux /Image' "$extlinux" || fail "kernel path is missing"
grep -Fq 'fdt /dtb/board.dtb' "$extlinux" || fail "DTB path is missing"
grep -Fq 'fdtoverlays /overlays/repository-overlay.dtbo' "$extlinux" ||
    fail "overlay-directory input is not enabled"
! grep -Fq '/overlays/test-overlay.dtbo' "$extlinux" ||
    fail "platform-asset overlay was unexpectedly enabled"
debugfs -R 'stat /overlays/test-overlay.dtbo' "$output" 2>/dev/null |
    grep -Eq '^Inode:.*Type: regular' ||
    fail "platform-asset overlay was not installed"
base_dtb="${tmp_dir}/base.dtb"
compiled_dtbo="${tmp_dir}/repository-overlay.dtbo"
merged_dtb="${tmp_dir}/merged.dtb"
debugfs -R "dump /dtb/board.dtb ${base_dtb}" "$output" >/dev/null 2>&1
debugfs -R "dump /overlays/repository-overlay.dtbo ${compiled_dtbo}" \
    "$output" >/dev/null 2>&1
fdtoverlay -i "$base_dtb" -o "$merged_dtb" "$compiled_dtbo"
[[ "$(fdtget -t s "$merged_dtb" / ubuntu,repository-overlay)" == compiled ]] ||
    fail "offline merged DTB does not contain the repository overlay property"
grep -Fq 'root=PARTLABEL=test-root' "$extlinux" || fail "root label is missing"
debugfs -R 'stat /Image' "$output" 2>/dev/null |
    grep -Eq 'User:[[:space:]]+0[[:space:]]+Group:[[:space:]]+0' ||
    fail "bootfs payload is not owned by root"
[[ "$(stat -c %a "$output")" == 644 ]] || fail "bootfs image mode is not 0644"
dumpe2fs -h "$output" 2>/dev/null | grep -Eq '^Filesystem features:.*orphan_file' &&
    fail "bootfs enables orphan_file"

printf 'tampered\n' >>"$output"
if BUILD_OUTPUT_DIR="${tmp_dir}/output" SOC_MODEL=test-soc \
    PLATFORM_ASSET_DIR="$asset_dir" BOOTFS_CONFIG="$config" \
    DTS_OVERLAY_DIR="$overlay_dir" \
    BOOTFS_OUTPUT="$output" "$BUILD_SCRIPT" --check \
    >"${tmp_dir}/tamper.log" 2>&1; then
    fail "modified bootfs image passed checksum validation"
fi

echo "Independent bootfs build checks passed"
