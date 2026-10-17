#!/usr/bin/env bash
set -Eeuo pipefail
export PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MODE=build

usage() {
    cat <<'EOF'
usage: scripts/build-overlay-root.sh [--check]

Build an immutable EROFS lower, a seed ext4 userdata image, an OverlayFS
initramfs and the independent bootfs that carries it. --check validates the
three existing filesystem artifacts without unpacking the Server rootfs.
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

host_arch() {
    case "$(uname -m)" in
        aarch64|arm64) echo arm64 ;;
        x86_64|amd64) echo amd64 ;;
        *) die "unsupported build-host architecture: $(uname -m)" ;;
    esac
}

find_single_file() {
    local directory="$1" pattern="$2" description="$3"
    local -a matches=()
    mapfile -d '' -t matches < <(
        find "$directory" -maxdepth 1 -type f -name "$pattern" -print0 | sort -z
    )
    (( ${#matches[@]} == 1 )) ||
        die "expected one ${description} in ${directory}, found ${#matches[@]}"
    printf '%s\n' "${matches[0]}"
}

case "${1:-}" in
    "") ;;
    --check) MODE=check; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
(( $# == 0 )) || { usage >&2; exit 2; }

declare -A CALLER_ENV=()
for env_name in BLUETOOTH_ASSET_DIR ROOTFS_PACKAGE_MANIFEST ENABLE_CONSOLE_FIRSTBOOT FIRSTBOOT_PROFILE BUILD_OUTPUT_DIR SOC_MODEL PLATFORM_ASSET_DIR ROOTFS_TARBALL \
    EROFS_ROOTFS_IMAGE USERDATA_IMAGE USERDATA_SIZE_MB BOOTFS_OUTPUT \
    BOOTFS_CONFIG BOOTFS_TEMPLATE BOOTFS_BASE_DTB BOOTFS_INSTALLED_DTB \
    BOOTFS_SIZE_MB BOOTFS_LABEL BOOTFS_TIMEOUT BOOTFS_CMDLINE BOOTFS_REQUIRE_LOGOS \
    DTS_OVERLAY_DIR UPDATE_ENGINE_PACKAGE_DIR UPDATE_ENGINE_DEB \
    RIME_ICE_URL RIME_ICE_ARCHIVE RIME_ICE_RESOLVED_URL GPU_STACK CHROMIUM_WEBGPU_BACKEND; do
    if [[ -v "$env_name" ]]; then
        CALLER_ENV["$env_name"]="${!env_name}"
    fi
done
if [[ -f "${PROJECT_DIR}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${PROJECT_DIR}/.env"
    set +a
fi
for env_name in "${!CALLER_ENV[@]}"; do
    printf -v "$env_name" '%s' "${CALLER_ENV[$env_name]}"
    export "${env_name?}"
done

BLUETOOTH_ASSET_DIR="${BLUETOOTH_ASSET_DIR:-${PROJECT_DIR}/artifacts/bluetooth}"
export BLUETOOTH_ASSET_DIR
python3 "${PROJECT_DIR}/package/bluetooth/import-assets.py" check --inputs "$BLUETOOTH_ASSET_DIR" >/dev/null

HOST_ARCH="$(host_arch)"
if [[ "$HOST_ARCH" == arm64 ]]; then
    BUILD_OUTPUT_DIR="${BUILD_OUTPUT_DIR:-/var/lib/ubuntu-ci/build}"
else
    BUILD_OUTPUT_DIR="${BUILD_OUTPUT_DIR:-${PROJECT_DIR}/build}"
fi
SOC_MODEL="${SOC_MODEL:-}"
PLATFORM_ASSET_DIR="${PLATFORM_ASSET_DIR:-${BUILD_OUTPUT_DIR}/platform-assets/${SOC_MODEL}}"
IMAGES_DIR="${BUILD_OUTPUT_DIR}/images"
USERDATA_SIZE_MB="${USERDATA_SIZE_MB:-64}"
GPU_STACK="${GPU_STACK:-libmali}"
[[ "$GPU_STACK" == libmali || "$GPU_STACK" == panfrost ]] ||
    die "GPU_STACK must be libmali or panfrost"
USERDATA_IMAGE="${USERDATA_IMAGE:-${IMAGES_DIR}/userdata-${SOC_MODEL}.img}"
BOOTFS_OUTPUT="${BOOTFS_OUTPUT:-${IMAGES_DIR}/boot-${SOC_MODEL}.img}"
UPDATE_ENGINE_PACKAGE_DIR="${UPDATE_ENGINE_PACKAGE_DIR:-${BUILD_OUTPUT_DIR}/packages/update-engine}"

[[ "$SOC_MODEL" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "invalid SOC_MODEL: $SOC_MODEL"
for path in "$BUILD_OUTPUT_DIR" "$PLATFORM_ASSET_DIR" "$USERDATA_IMAGE" \
        "$BOOTFS_OUTPUT" "$UPDATE_ENGINE_PACKAGE_DIR"; do
    [[ "$path" == /* && "$path" != *[[:space:]]* ]] ||
        die "build paths must be absolute and contain no whitespace: $path"
done
[[ "$USERDATA_SIZE_MB" =~ ^[1-9][0-9]*$ ]] ||
    die "invalid USERDATA_SIZE_MB: $USERDATA_SIZE_MB"
(( USERDATA_SIZE_MB >= 32 )) || die "USERDATA_SIZE_MB must be at least 32"

if [[ -z "${EROFS_ROOTFS_IMAGE:-}" ]]; then
    if [[ "$MODE" == build ]]; then
        if [[ -z "${ROOTFS_TARBALL:-}" ]]; then
            ROOTFS_TARBALL="$(find_single_file "$IMAGES_DIR" '*.rootfs.tar.gz' 'Server rootfs tarball')"
        fi
        tar_name="$(basename "$ROOTFS_TARBALL")"
        [[ "$tar_name" == *.rootfs.tar.gz ]] ||
            die "ROOTFS_TARBALL must end in .rootfs.tar.gz: $tar_name"
        EROFS_ROOTFS_IMAGE="${IMAGES_DIR}/${tar_name%.rootfs.tar.gz}.rootfs.erofs.img"
    else
        EROFS_ROOTFS_IMAGE="$(find_single_file "$IMAGES_DIR" '*.rootfs.erofs.img' 'EROFS rootfs image')"
    fi
fi
[[ "$EROFS_ROOTFS_IMAGE" == /* && "$EROFS_ROOTFS_IMAGE" != *[[:space:]]* ]] ||
    die "EROFS_ROOTFS_IMAGE must be an absolute path without whitespace"

for tool in awk blkid debugfs e2fsck find fsck.erofs grep lsinitramfs \
    sha256sum stat; do
    command -v "$tool" >/dev/null || die "missing overlay-root validation dependency: $tool"
done

validate_checksum() {
    local artifact="$1" sidecar="${1}.sha256"
    [[ -s "$sidecar" ]] || die "missing artifact checksum: $sidecar"
    (cd "$(dirname "$artifact")" && sha256sum --quiet -c "$(basename "$sidecar")") ||
        die "artifact checksum failed: $artifact"
}

validate_artifacts() {
    local rootfs_type userdata_type userdata_label initrd_dir initrd tool
    [[ -s "$EROFS_ROOTFS_IMAGE" ]] || die "missing EROFS rootfs: $EROFS_ROOTFS_IMAGE"
    validate_checksum "$EROFS_ROOTFS_IMAGE"
    fsck.erofs "$EROFS_ROOTFS_IMAGE" >/dev/null ||
        die "EROFS integrity check failed: $EROFS_ROOTFS_IMAGE"
    rootfs_type="$(blkid -s TYPE -o value "$EROFS_ROOTFS_IMAGE" 2>/dev/null || true)"
    [[ "$rootfs_type" == erofs ]] || die "rootfs image is not EROFS"
    [[ $(( $(stat -c %s "$EROFS_ROOTFS_IMAGE") % 4096 )) -eq 0 ]] ||
        die "EROFS image is not 4 KiB aligned"

    [[ -s "$USERDATA_IMAGE" ]] || die "missing userdata image: $USERDATA_IMAGE"
    validate_checksum "$USERDATA_IMAGE"
    e2fsck -fn "$USERDATA_IMAGE" >/dev/null 2>&1 ||
        die "userdata ext4 check failed: $USERDATA_IMAGE"
    userdata_type="$(blkid -s TYPE -o value "$USERDATA_IMAGE" 2>/dev/null || true)"
    userdata_label="$(blkid -s LABEL -o value "$USERDATA_IMAGE" 2>/dev/null || true)"
    [[ "$userdata_type" == ext4 && "$userdata_label" == userdata ]] ||
        die "userdata image must be ext4 with LABEL=userdata"
    [[ "$(stat -c %s "$USERDATA_IMAGE")" -eq $((USERDATA_SIZE_MB * 1024 * 1024)) ]] ||
        die "userdata image size does not match USERDATA_SIZE_MB"
    BOOTFS_OUTPUT="$BOOTFS_OUTPUT" "${SCRIPT_DIR}/build-bootfs.sh" --check
    initrd_dir="$(mktemp -d)"
    trap 'rm -rf -- "$initrd_dir"' RETURN
    initrd="${initrd_dir}/initrd.img"
    debugfs -R "dump -p /initrd.img ${initrd}" "$BOOTFS_OUTPUT" >/dev/null 2>&1 ||
        die "bootfs does not contain /initrd.img"
    [[ -s "$initrd" ]] || die "bootfs initrd is empty"
    lsinitramfs "$initrd" >"${initrd_dir}/listing"
    grep -Eq '(^|/)scripts/init-bottom/overlay-root$' "${initrd_dir}/listing" ||
        die "initrd does not contain overlay-root init-bottom"
    grep -Eq '(^|/)conf/overlay-root.conf$' "${initrd_dir}/listing" ||
        die "initrd does not contain overlay-root configuration"
    for tool in blkid e2fsck resize2fs; do
        grep -Eq "(^|/)(usr/)?sbin/${tool}$" "${initrd_dir}/listing" ||
            die "initrd does not contain ${tool}"
    done
    trap - RETURN
    rm -rf -- "$initrd_dir"
}

if [[ "$MODE" == check ]]; then
    validate_artifacts
    info "EROFS lower, userdata upper and initramfs are valid"
    exit 0
fi

[[ "${ROOTFS_TARBALL:-}" == /* && -s "$ROOTFS_TARBALL" ]] ||
    die "missing absolute ROOTFS_TARBALL: ${ROOTFS_TARBALL:-}"
validate_checksum "$ROOTFS_TARBALL"
"${SCRIPT_DIR}/stage-sdk-assets.sh" --check
kernel_release="$(<"${PLATFORM_ASSET_DIR}/kernel-release")"
"${SCRIPT_DIR}/check-kernel-config.sh" \
    "${PLATFORM_ASSET_DIR}/boot/kernel.config"
for tool in chroot depmod dpkg-deb findmnt install jq python3 mkfs.erofs mkfs.ext4 \
        mount tar truncate umount; do
    command -v "$tool" >/dev/null || die "missing overlay-root build dependency: $tool"
done
[[ "$HOST_ARCH" == arm64 ]] ||
    die "overlay-root artifact assembly requires a native ARM64 build host"

if [[ "$EUID" -ne 0 ]]; then
    exec sudo \
        --preserve-env=PYTHONDONTWRITEBYTECODE \
        --preserve-env=UPDATE_ENGINE_DEB \
        --preserve-env=UPDATE_ENGINE_PACKAGE_DIR \
        --preserve-env=BOOTFS_CONFIG \
        --preserve-env=BOOTFS_OUTPUT \
        --preserve-env=BOOTFS_TEMPLATE \
        --preserve-env=BOOTFS_BASE_DTB \
        --preserve-env=BOOTFS_INSTALLED_DTB \
        --preserve-env=BOOTFS_SIZE_MB \
        --preserve-env=BOOTFS_LABEL \
        --preserve-env=BOOTFS_TIMEOUT \
        --preserve-env=BOOTFS_CMDLINE \
        --preserve-env=BOOTFS_REQUIRE_LOGOS \
        --preserve-env=DTS_OVERLAY_DIR \
        --preserve-env=BUILD_OUTPUT_DIR \
        --preserve-env=EROFS_ROOTFS_IMAGE \
        --preserve-env=BLUETOOTH_ASSET_DIR,PLATFORM_ASSET_DIR \
        --preserve-env=ROOTFS_TARBALL \
        --preserve-env=ROOTFS_PACKAGE_MANIFEST \
        --preserve-env=SOC_MODEL \
        --preserve-env=USERDATA_IMAGE \
        --preserve-env=USERDATA_SIZE_MB \
        --preserve-env=RIME_ICE_URL,RIME_ICE_ARCHIVE,RIME_ICE_RESOLVED_URL \
        --preserve-env=HTTPS_PROXY,HTTP_PROXY,NO_PROXY,https_proxy,http_proxy,no_proxy \
        --preserve-env=GPU_STACK \
        --preserve-env=CHROMIUM_WEBGPU_BACKEND \
        --preserve-env=ENABLE_CONSOLE_FIRSTBOOT,FIRSTBOOT_PROFILE \
        "$0" "$@"
fi

work_dir="${BUILD_OUTPUT_DIR}/work/overlay-root/$(basename "$EROFS_ROOTFS_IMAGE" .img)"
rootfs="${work_dir}/rootfs"
cleanup_work_mounts() {
    local target failed=0
    while IFS= read -r target; do
        umount "$target" 2>/dev/null || failed=1
    done < <(findmnt -rn -o TARGET | awk -v p="$work_dir" \
        '$0 == p || index($0, p "/") == 1' | sort -r)
    (( failed == 0 )) || return 1
    ! findmnt -rn -o TARGET | awk -v p="$work_dir" \
        '$0 == p || index($0, p "/") == 1 { found=1 } END { exit !found }'
}
cleanup() {
    local rc=$?
    trap - EXIT
    cleanup_work_mounts || rc=1
    [[ -z "${image_stage:-}" ]] || rm -f -- "$image_stage"
    [[ -z "${userdata_stage:-}" ]] || rm -f -- "$userdata_stage"
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
[[ "$work_dir" == "${BUILD_OUTPUT_DIR%/}/work/overlay-root/"* ]] ||
    die "refusing to clean work directory outside BUILD_OUTPUT_DIR"
cleanup_work_mounts || die "busy mounts remain below $work_dir"
rm -rf -- "$work_dir"
install -d -m 0755 "$rootfs" "$IMAGES_DIR"
tar --numeric-owner --xattrs --acls -xzf "$ROOTFS_TARBALL" -C "$rootfs"

if [[ -z "${UPDATE_ENGINE_DEB:-}" ]]; then
    UPDATE_ENGINE_DEB="$(find_single_file "$UPDATE_ENGINE_PACKAGE_DIR" \
        'rockchip-update-engine_*_arm64.deb' 'updateEngine ARM64 Debian package')"
fi
[[ "$UPDATE_ENGINE_DEB" == /* && -s "$UPDATE_ENGINE_DEB" &&
   ! -L "$UPDATE_ENGINE_DEB" ]] || die "invalid UPDATE_ENGINE_DEB: $UPDATE_ENGINE_DEB"
[[ "$(dpkg-deb -f "$UPDATE_ENGINE_DEB" Package)" == rockchip-update-engine &&
   "$(dpkg-deb -f "$UPDATE_ENGINE_DEB" Architecture)" == arm64 ]] ||
    die "UPDATE_ENGINE_DEB is not the ARM64 rockchip-update-engine package"
install -D -m 0644 "$UPDATE_ENGINE_DEB" "$rootfs/tmp/rockchip-update-engine.deb"
chroot "$rootfs" dpkg -i /tmp/rockchip-update-engine.deb
rm -f -- "$rootfs/tmp/rockchip-update-engine.deb"
[[ -x "$rootfs/usr/bin/updateEngine" &&
   -s "$rootfs/usr/lib/udev/rules.d/99-rockchip-block-by-name.rules" ]] ||
    die "updateEngine package installation is incomplete"
update_engine_version="$(dpkg-deb -f "$UPDATE_ENGINE_DEB" Version)"
update_engine_sha256="$(sha256sum "$UPDATE_ENGINE_DEB" | awk '{print $1}')"

for path in usr/sbin/update-initramfs usr/sbin/mkinitramfs \
        usr/sbin/blkid usr/sbin/e2fsck usr/sbin/resize2fs; do
    [[ -e "$rootfs/$path" ]] || die "Server rootfs is missing /$path"
done
install -D -m 0644 "${PROJECT_DIR}/config/overlay-root/overlay-root.conf" \
    "$rootfs/etc/overlay-root.conf"
install -D -m 0644 "${PROJECT_DIR}/config/overlay-root/fstab" "$rootfs/etc/fstab"
install -D -m 0644 "${PROJECT_DIR}/config/overlay-root/cloud/90-overlay-root.cfg" \
    "$rootfs/etc/cloud/cloud.cfg.d/90-overlay-root.cfg"
install -D -m 0755 \
    "${PROJECT_DIR}/config/overlay-root/initramfs/hooks/overlay-root" \
    "$rootfs/etc/initramfs-tools/hooks/overlay-root"
install -D -m 0755 \
    "${PROJECT_DIR}/config/overlay-root/initramfs/scripts/init-bottom/overlay-root" \
    "$rootfs/etc/initramfs-tools/scripts/init-bottom/overlay-root"
install -D -m 0644 \
    "${PROJECT_DIR}/config/overlay-root/initramfs/conf.d/overlay-root" \
    "$rootfs/etc/initramfs-tools/conf.d/overlay-root"
install -d -m 0755 "$rootfs/boot" "$rootfs/var/lib/overlay-root"
# The BCB image path must resolve to the same persistent file after recovery
# mounts the userdata partition at /userdata.
[[ ! -e "$rootfs/userdata" && ! -L "$rootfs/userdata" ]] ||
    die "base rootfs already contains /userdata; cannot install recovery data path"
ln -s var/lib/overlay-root "$rootfs/userdata"
# Netplan's generator runs before cloud-init writes its first-boot YAML.
# Enable the selected renderer in the image so wired DHCP also starts on
# that first boot, when no generated networkd dependency exists yet.
network_seed="$rootfs/var/lib/cloud/seed/nocloud/network-config"
if [[ -f "$network_seed" ]] &&
    grep -Eq '^[[:space:]]*renderer:[[:space:]]*networkd[[:space:]]*$' "$network_seed"; then
    chroot "$rootfs" systemctl enable systemd-networkd.service
fi
"${SCRIPT_DIR}/install-adb.sh" "$rootfs"
if [[ "$GPU_STACK" == libmali ]]; then
    "${SCRIPT_DIR}/install-libmali.sh" "$rootfs" "$PLATFORM_ASSET_DIR"
else
    mesa_packages=(libegl-mesa0 libgl1-mesa-dri libgles2)
    # Vulkan/WebGPU belongs to the desktop package set. A headless Server
    # still uses Mesa EGL/DRI without requiring the desktop Vulkan ICD.
    if [[ -x "$rootfs/usr/bin/gnome-shell" || -x "$rootfs/usr/bin/xfce4-session" ]]; then
        mesa_packages+=(mesa-vulkan-drivers)
    fi
    for mesa_package in "${mesa_packages[@]}"; do
        # shellcheck disable=SC2016
        chroot "$rootfs" dpkg-query -W -f='${db:Status-Status}' "$mesa_package" |
            grep -Fxq installed || die "Panfrost Mesa package is missing: $mesa_package"
    done
    install -D -m 0644 "${PROJECT_DIR}/package/libmali/60-dma-heap.rules" \
        "$rootfs/etc/udev/rules.d/60-dma-heap.rules"
fi
"${SCRIPT_DIR}/install-rga.sh" "$rootfs" "$PLATFORM_ASSET_DIR"
"${SCRIPT_DIR}/install-mpp.sh" "$rootfs" "$PLATFORM_ASSET_DIR"
"${SCRIPT_DIR}/install-local-debs.sh" "$rootfs" "$PLATFORM_ASSET_DIR"
python3 "${PROJECT_DIR}/package/bluetooth/import-assets.py" install \
    --inputs "$BLUETOOTH_ASSET_DIR" --rootfs "$rootfs"
if [[ -d "$PLATFORM_ASSET_DIR/iqfiles" ]]; then
    install -d -m 0755 "$rootfs/etc/iqfiles"
    while IFS= read -r -d '' iq_file; do
        install -m 0644 "$iq_file" "$rootfs/etc/iqfiles/"
    done < <(find "$PLATFORM_ASSET_DIR/iqfiles" -maxdepth 1 -type f -name '*.json' -print0)
fi
"${SCRIPT_DIR}/install-gnome.sh" "$rootfs"
"${SCRIPT_DIR}/install-xfce.sh" "$rootfs"
if [[ -x "$rootfs/usr/bin/gnome-shell" && -z "${FIRSTBOOT_PROFILE:-}" ]]; then
    FIRSTBOOT_PROFILE=desktop
fi
if [[ -x "$rootfs/usr/bin/xfce4-session" && -z "${FIRSTBOOT_PROFILE:-}" ]]; then
    FIRSTBOOT_PROFILE=desktop-xfce
fi
if [[ -x "$rootfs/usr/bin/gnome-shell" || -x "$rootfs/usr/bin/xfce4-session" ]]; then
    # Desktop release bootfs must include both vendor boot and handoff logos.
    export BOOTFS_REQUIRE_LOGOS="${BOOTFS_REQUIRE_LOGOS:-1}"
    "${SCRIPT_DIR}/install-audio-customization.sh" "$rootfs"
    "${SCRIPT_DIR}/install-fcitx5-customization.sh" "$rootfs"
fi


module_source="${PLATFORM_ASSET_DIR}/modules/lib/modules/${kernel_release}"
firstboot_args=("$rootfs" --profile "${FIRSTBOOT_PROFILE:-server}")
case "${ENABLE_CONSOLE_FIRSTBOOT:-yes}" in
    yes) firstboot_args+=(--enable-console) ;;
    no) firstboot_args+=(--disable-console) ;;
    *) die "ENABLE_CONSOLE_FIRSTBOOT must be yes or no" ;;
esac
"${SCRIPT_DIR}/install-firstboot.sh" "${firstboot_args[@]}"

module_target="$rootfs/lib/modules/${kernel_release}"
while IFS= read -r -d '' directory; do
    relative="${directory#"$module_source"}"
    install -d -m 0755 "$module_target$relative"
done < <(find "$module_source" -type d -print0 | sort -z)
while IFS= read -r -d '' module_file; do
    relative="${module_file#"$module_source/"}"
    install -D -m 0644 "$module_file" "$module_target/$relative"
done < <(find "$module_source" -type f -print0 | sort -z)
install -m 0644 "${PLATFORM_ASSET_DIR}/boot/kernel.config" \
    "$rootfs/boot/config-${kernel_release}"
depmod -a -b "$rootfs" "$kernel_release"

modules_load="$rootfs/etc/modules-load.d/platform.conf"
install -d -m 0755 "$(dirname "$modules_load")"
: >"$modules_load"
while IFS=$'\t' read -r _module_source _module_target force_load; do
    [[ -n "$force_load" ]] || continue
    printf '%s\n' "$force_load" >>"$modules_load"
done <"${PLATFORM_ASSET_DIR}/module-manifest.tsv"
if [[ ! -s "$modules_load" ]]; then
    rm -f "$modules_load"
fi

mount -t proc proc "$rootfs/proc"
chroot "$rootfs" update-initramfs -c -k "$kernel_release"
umount "$rootfs/proc"
initrd="$rootfs/boot/initrd.img-${kernel_release}"
[[ -s "$initrd" ]] || die "update-initramfs did not create $initrd"
lsinitramfs "$initrd" >"${work_dir}/initrd.listing"
for required in scripts/init-bottom/overlay-root conf/overlay-root.conf; do
    grep -Eq "(^|/)${required}$" "${work_dir}/initrd.listing" ||
        die "generated initrd is missing $required"
done
install -m 0644 "$initrd" "${work_dir}/initrd.img"
find "$rootfs/boot" -mindepth 1 -delete

# The existing base manifest excludes vendor DEBs. Export the final package set.
if [[ -n "${ROOTFS_PACKAGE_MANIFEST:-}" ]]; then
    python3 "${SCRIPT_DIR}/package-manifest.py" finalize --rootfs "$rootfs" \
        --manifest "$ROOTFS_PACKAGE_MANIFEST"
fi
python3 "${SCRIPT_DIR}/package-manifest.py" export --rootfs "$rootfs" \
    --output "${work_dir}/packages.manifest"

image_stage="${EROFS_ROOTFS_IMAGE}.stage.$$"
userdata_stage="${USERDATA_IMAGE}.stage.$$"
rm -f -- "$image_stage" "$userdata_stage"
mkfs.erofs -T 0 "$image_stage" "$rootfs" >/dev/null
fsck.erofs "$image_stage" >/dev/null || die "generated EROFS failed integrity check"
mv -f -- "$image_stage" "$EROFS_ROOTFS_IMAGE"
install -m 0644 "${work_dir}/packages.manifest" "${EROFS_ROOTFS_IMAGE}.manifest"
(cd "$IMAGES_DIR"; sha256sum "$(basename "${EROFS_ROOTFS_IMAGE}.manifest")" \
    >"${EROFS_ROOTFS_IMAGE}.manifest.sha256")

truncate -s "${USERDATA_SIZE_MB}M" "$userdata_stage"
mkfs.ext4 -q -F -L userdata \
    -E lazy_itable_init=0,lazy_journal_init=0 "$userdata_stage"
e2fsck -fn "$userdata_stage" >/dev/null 2>&1 || die "generated userdata failed ext4 check"
mv -f -- "$userdata_stage" "$USERDATA_IMAGE"

BOOTFS_INITRD="${work_dir}/initrd.img" BOOTFS_OUTPUT="$BOOTFS_OUTPUT" \
    "${SCRIPT_DIR}/build-bootfs.sh"

(
    cd "$IMAGES_DIR"
    sha256sum "$(basename "$EROFS_ROOTFS_IMAGE")" \
        >"$(basename "$EROFS_ROOTFS_IMAGE").sha256"
    sha256sum "$(basename "$USERDATA_IMAGE")" \
        >"$(basename "$USERDATA_IMAGE").sha256"
)
bluetooth_assets_sha256=none
if [[ -f "$rootfs/usr/share/platform-bluetooth/assets.json" ]]; then
    bluetooth_assets_sha256="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sha256"])' \
        "$rootfs/usr/share/platform-bluetooth/assets.json")"
fi
cat >"${EROFS_ROOTFS_IMAGE}.build-info" <<EOF
schema=ubuntu-overlay-root-v1
packages.manifest.sha256=$(sha256sum "${EROFS_ROOTFS_IMAGE}.manifest" | awk '{print $1}')
packages.lock_input.sha256=$([[ -z "${ROOTFS_PACKAGE_MANIFEST:-}" ]] && echo none || sha256sum "$ROOTFS_PACKAGE_MANIFEST" | awk '{print $1}')
filesystem=erofs
filesystem.compression=none
partition.label=rootfs
overlay.lower=rootfs:ro
overlay.data.partlabel=userdata
overlay.data.filesystem=ext4
overlay.data.mount=/var/lib/overlay-root
overlay.data.recovery-path=/userdata
gpu.stack=${GPU_STACK}
update-engine.version=${update_engine_version}
update-engine.deb.sha256=${update_engine_sha256}
kernel.release=${kernel_release}
kernel.config.sha256=$(sha256sum "${PLATFORM_ASSET_DIR}/boot/kernel.config" | awk '{print $1}')
bluetooth.assets.sha256=${bluetooth_assets_sha256}
platform.assets.sha256=$(sha256sum "${PLATFORM_ASSET_DIR}/SHA256SUMS" | awk '{print $1}')
initramfs.sha256=$(sha256sum "${work_dir}/initrd.img" | awk '{print $1}')
bootfs.image=$(basename "$BOOTFS_OUTPUT")
userdata.image=$(basename "$USERDATA_IMAGE")
adb.transport=usb-functionfs
adb.network.namespace=host
adb.shell.uid=0
EOF
chmod 0644 "$EROFS_ROOTFS_IMAGE" "$USERDATA_IMAGE" \
    "${EROFS_ROOTFS_IMAGE}.manifest" "${EROFS_ROOTFS_IMAGE}.manifest.sha256" \
    "${EROFS_ROOTFS_IMAGE}.sha256" "${USERDATA_IMAGE}.sha256" \
    "${EROFS_ROOTFS_IMAGE}.build-info"
validate_artifacts
chown "${SUDO_UID:-0}:${SUDO_GID:-0}" \
    "$EROFS_ROOTFS_IMAGE" "$USERDATA_IMAGE" "$BOOTFS_OUTPUT" \
    "${EROFS_ROOTFS_IMAGE}.sha256" "${USERDATA_IMAGE}.sha256" \
    "${EROFS_ROOTFS_IMAGE}.manifest" "${EROFS_ROOTFS_IMAGE}.manifest.sha256" \
    "${EROFS_ROOTFS_IMAGE}.build-info" "${BOOTFS_OUTPUT}.sha256" \
    "${BOOTFS_OUTPUT}.build-info"
trap - EXIT
info "EROFS rootfs built and verified: $EROFS_ROOTFS_IMAGE"
info "userdata seed built and verified: $USERDATA_IMAGE"
info "OverlayFS initramfs installed in: $BOOTFS_OUTPUT"
