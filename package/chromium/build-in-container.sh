#!/usr/bin/env bash
set -Eeuo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

src=/chromium/src
depot_tools=/depot_tools
output=/out/chromium
jobs="${BUILD_JOBS:-$(nproc)}"
host_uid="${HOST_UID:?HOST_UID is required}"
host_gid="${HOST_GID:?HOST_GID is required}"

[[ -f "${src}/BUILD.gn" && -f "${src}/build/install-build-deps.sh" ]] ||
    die "CHROMIUM_SOURCE_DIR must point to a complete Chromium src checkout"
[[ -x "${depot_tools}/gclient" && -x "${depot_tools}/autoninja" ]] ||
    die "CHROMIUM_DEPOT_TOOLS_DIR is not a complete depot_tools checkout"
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || die "BUILD_JOBS must be positive"
[[ "$host_uid" =~ ^[0-9]+$ && "$host_gid" =~ ^[0-9]+$ ]] ||
    die "invalid host UID/GID"

version="${CHROMIUM_VERSION:?CHROMIUM_VERSION is required}"
actual_version="$(python3 - "$src/chrome/VERSION" <<'VERSION'
import sys
parts=dict(line.strip().split('=',1) for line in open(sys.argv[1]) if '=' in line)
print('.'.join(parts[k] for k in ('MAJOR','MINOR','BUILD','PATCH')))
VERSION
)"
[[ "$version" == "$actual_version" ]] ||
    die "source version $actual_version does not match requested $version"

export PATH="${depot_tools}:${PATH}"
export DEPOT_TOOLS_UPDATE=0

apply_rk3576_patches() {
    local patch_dir="${CHROMIUM_PATCH_DIR:-}"
    [[ -n "$patch_dir" ]] || return 0
    [[ -d "$patch_dir" ]] || die "Chromium RK3576 patch directory is missing: $patch_dir"
    [[ -s "$patch_dir/series" ]] || die "Chromium RK3576 patch series is missing: $patch_dir/series"
    while IFS= read -r patch_name; do
        [[ -z "$patch_name" ]] && continue
        if git -C "$src" apply --check "$patch_dir/$patch_name" 2>/dev/null; then
            git -C "$src" apply "$patch_dir/$patch_name"
        elif ! git -C "$src" apply --reverse --check "$patch_dir/$patch_name" 2>/dev/null; then
            die "Chromium patch does not apply: $patch_name"
        fi
    done <"$patch_dir/series"
}

if [[ "${CHROMIUM_BUILD_PHASE:-setup}" == setup ]]; then
    [[ "$EUID" -eq 0 ]] || die "Chromium dependency setup must run as root"
    info "Install Chromium build dependencies in the ephemeral container"
    "${src}/build/install-build-deps.sh" --no-prompt --no-chromeos-fonts
    exec setpriv --reuid="$host_uid" --regid="$host_gid" --clear-groups \
        env CHROMIUM_BUILD_PHASE=build \
            BUILD_JOBS="$jobs" HOST_UID="$host_uid" HOST_GID="$host_gid" \
            CHROMIUM_EXTRA_GN_ARGS="${CHROMIUM_EXTRA_GN_ARGS:-}" \
            CHROMIUM_PATCH_DIR="${CHROMIUM_PATCH_DIR:-}" \
            "$0"
fi
[[ "$EUID" -eq "$host_uid" ]] || die "failed to drop Chromium build privileges"
apply_rk3576_patches
info "Install the upstream ARM64 sysroot and refresh pinned toolchains"
python3 "${src}/build/linux/sysroot_scripts/install-sysroot.py" --arch=arm64
(
    cd /chromium
    gclient runhooks
)

build_dir="${src}/out/arm64-cross"
mkdir -p "$build_dir"
cp /workspace/package/chromium/args.gn "${build_dir}/args.gn"
if [[ -n "${CHROMIUM_EXTRA_GN_ARGS:-}" ]]; then
    printf '%s\n' "$CHROMIUM_EXTRA_GN_ARGS" >>"${build_dir}/args.gn"
fi

info "Generate ARM64 GN build"
gn gen "$build_dir"
info "Cross-build Chromium with ${jobs} jobs"
autoninja -C "$build_dir" -j "$jobs" chrome chrome_sandbox chromedriver

payload="${output}/payload/usr/lib/chromium-browser"
rm -rf -- "$output"
mkdir -p "$payload/locales"
required=(chrome chrome_sandbox chrome_crashpad_handler icudtl.dat resources.pak)
for name in "${required[@]}"; do
    [[ -e "${build_dir}/${name}" ]] || die "missing Chromium output: $name"
    cp -a "${build_dir}/${name}" "$payload/"
done
optional=(chromedriver libEGL.so libGLESv2.so libffmpeg.so snapshot_blob.bin
    v8_context_snapshot.bin vk_swiftshader_icd.json libvk_swiftshader.so
    libvulkan.so.1)
for name in "${optional[@]}"; do
    [[ ! -e "${build_dir}/${name}" ]] || cp -a "${build_dir}/${name}" "$payload/"
done
cp -a "${build_dir}"/*.pak "$payload/" 2>/dev/null || true
cp -a "${build_dir}/locales"/*.pak "$payload/locales/"
[[ ! -d "${build_dir}/swiftshader" ]] || cp -a "${build_dir}/swiftshader" "$payload/"
install -m 0644 "${src}/chrome/app/theme/chromium/linux/product_logo_256.png" \
    "${output}/payload/chromium.png"
chmod 4755 "${payload}/chrome_sandbox"

while IFS= read -r elf; do
    machine="$(readelf -h "$elf" | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p')"
    [[ "$machine" == AArch64 ]] || die "non-AArch64 Chromium ELF: $elf"
done < <(find "${output}/payload" -type f -exec sh -c \
    'file -b "$1" | grep -q "^ELF" && printf "%s\n" "$1"' _ {} \;)

echo "CHROMIUM_ARM64_PAYLOAD_OK"
