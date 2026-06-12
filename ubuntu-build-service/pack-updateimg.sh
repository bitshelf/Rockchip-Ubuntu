#!/bin/bash
set -eu

# ==========================================================================
# pack-updateimg.sh — Package Ubuntu rootfs into Rockchip update.img
#
# Zero sudo. Uses mkfs.ext4 -d to create ext4 images from directories
# without loopback mount, then Rockchip afptool + rkImageMaker to pack.
# ==========================================================================

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
export SDK_PATH="${SDK_PATH:-$(dirname "${PROJECT_DIR}")}"

BOARD="${BOARD:-rk3576}"
BOARD_CONF="${PROJECT_DIR}/boards/${BOARD}/${BOARD}.conf"
[[ -f "${BOARD_CONF}" ]] && source "${BOARD_CONF}"
source "${SCRIPT_DIR}/merge-overlays.sh"

ARTIFACTS_DIR="${PROJECT_DIR}/artifacts"
BOOT_ASSETS="${ARTIFACTS_DIR}/boot-assets"
ROOTFS_TAR="${ARTIFACTS_DIR}/rootfs.tar.gz"

# Rockchip SDK tools (x86, no sudo needed)
RKDEV="${SDK_PATH}/tools/linux/Linux_Pack_Firmware/rockdev"
AFTOOL="${RKDEV}/afptool"
RKIMAGEMAKER="${RKDEV}/rkImageMaker"
PARAMETER_SRC="${PROJECT_DIR}/boards/${BOARD}/parameter.txt"
[[ -f "${PARAMETER_SRC}" ]] || PARAMETER_SRC="${SDK_PATH}/device/rockchip/.chips/${SOC_MODEL}/parameter.txt"

PACK_DIR="${ARTIFACTS_DIR}/pack"
IMAGE_DIR="${PACK_DIR}/Image"
UPDATE_IMG="${ARTIFACTS_DIR}/update.img"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
info()  { echo -e "${GREEN}[PACK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[PACK]${NC} $*"; }
error() { echo -e "${RED}[PACK]${NC} $*"; exit 1; }

# Validate inputs
for f in "${ROOTFS_TAR}" "${BOOT_ASSETS}/idbloader.img" "${BOOT_ASSETS}/u-boot.itb" "${BOOT_ASSETS}/boot.img"; do
    [[ -f "${f}" ]] || error "Required file not found: ${f}"
done
for tool in "${AFTOOL}" "${RKIMAGEMAKER}"; do
    [[ -x "${tool}" ]] || error "Tool not found: ${tool}"
done

# -------------------------------------------------------------------
# Step 1: Prepare directories
# -------------------------------------------------------------------
info "Preparing Image directory..."
rm -rf "${PACK_DIR}"
mkdir -p "${IMAGE_DIR}"

# Temp dir for extracted rootfs (replaces loopback mount)
ROOTFS_TMP=$(mktemp -d)
trap "rm -rf ${ROOTFS_TMP}" EXIT

# -------------------------------------------------------------------
# Step 2: Extract rootfs and purge unwanted packages (no mount, no chroot)
# -------------------------------------------------------------------
info "Extracting rootfs tarball..."
tar -xzf "${ROOTFS_TAR}" -C "${ROOTFS_TMP}"

# Apply overlay (board-specific files)
merge_overlays "${ROOTFS_TMP}"

# Purge excluded packages — delete files directly, no chroot
info "Purging excluded packages..."
for pkg in unattended-upgrades update-notifier update-notifier-common \
           update-manager-core update-manager python3-update-manager \
           ubuntu-release-upgrader-core ubuntu-advantage-tools snapd \
           gnome-games gnome-sudoku gnome-mines gnome-mahjongg aisleriot \
           thunderbird rhythmbox transmission-gtk transmission-common \
           libreoffice-core libreoffice-common libreoffice-writer \
           libreoffice-calc libreoffice-impress libreoffice-draw \
           libreoffice-math libreoffice-base libreoffice-\*; do
    rm -f "${ROOTFS_TMP}/var/lib/dpkg/info/${pkg}."* 2>/dev/null || true
    # Handle wildcard: remove any libreoffice-* from dpkg status
    sed -i "/^Package: ${pkg}$/,/^$/d" "${ROOTFS_TMP}/var/lib/dpkg/status" 2>/dev/null || true
done
# Also purge all libreoffice packages by pattern
grep -l 'libreoffice' "${ROOTFS_TMP}/var/lib/dpkg/info/"*.list 2>/dev/null | while read f; do
    pkg=$(basename "$f" .list)
    rm -f "${ROOTFS_TMP}/var/lib/dpkg/info/${pkg}."* 2>/dev/null || true
    sed -i "/^Package: ${pkg}$/,/^$/d" "${ROOTFS_TMP}/var/lib/dpkg/status" 2>/dev/null || true
done

# Clean apt caches
rm -rf "${ROOTFS_TMP}/var/cache/apt/archives/"*.deb 2>/dev/null || true

# Fix permissions on dirs that prevent mkfs.ext4 -d from reading them
# (snapd void dir etc. owned by root with restrictive perms)
find "${ROOTFS_TMP}" -type d -not -perm -a+r 2>/dev/null | while read -r d; do
    chmod -R a+rX "$d" 2>/dev/null || true
done

# Mask systemd timers
info "Masking systemd timers..."
for timer in apt-daily.timer apt-daily-upgrade.timer motd-news.timer \
             snapd.refresh.timer snapd.snap-refresh.timer; do
    ln -sf /dev/null "${ROOTFS_TMP}/etc/systemd/system/${timer}" 2>/dev/null || true
done

# Serial console
if [[ -n "${SERIAL_CONSOLE_DEV:-}" ]]; then
    mkdir -p "${ROOTFS_TMP}/etc/systemd/system/getty.target.wants"
    ln -sf /lib/systemd/system/serial-getty@.service \
        "${ROOTFS_TMP}/etc/systemd/system/getty.target.wants/serial-getty@${SERIAL_CONSOLE_DEV}.service" 2>/dev/null || true
fi

# fw_env.config
if [[ -n "${UBOOT_ENV_DEV:-}" ]]; then
    env_offset="${UBOOT_ENV_OFFSET:-0x3f8000}"
    env_size="${UBOOT_ENV_SIZE:-0x8000}"
    mkdir -p "${ROOTFS_TMP}/etc"
    echo "# Device  Offset       Size" > "${ROOTFS_TMP}/etc/fw_env.config"
    echo "${UBOOT_ENV_DEV}  ${env_offset}  ${env_size}" >> "${ROOTFS_TMP}/etc/fw_env.config"
fi

# Extract initramfs for boot partition
INITRD_DEST="${BOOT_ASSETS}/initrd.img"
for initrd in "${ROOTFS_TMP}/boot"/initrd.img-*; do
    if [[ -f "${initrd}" ]]; then
        cp "${initrd}" "${INITRD_DEST}"
        info "  initrd: $(basename "${initrd}") -> initrd.img"
        break
    fi
done

# -------------------------------------------------------------------
# Step 3: Create rootfs.img with mkfs.ext4 -d (no mount, no sudo!)
# -------------------------------------------------------------------
info "Creating rootfs.img..."

ROOTFS_SECTORS=$(grep -oP '0x[0-9a-fA-F]+(?=@0x[0-9a-fA-F]+\(rootfs)' "${PARAMETER_SRC}" 2>/dev/null || echo "0x800000")
ROOTFS_SIZE_MB=$(( ROOTFS_SECTORS / 2048 ))  # sectors to MB

DU_SIZE=$(du -sm "${ROOTFS_TMP}" 2>/dev/null | cut -f1)
# ext4 overhead ~7% (inode tables + journal + reserved), round up 10%
ALLOC_SIZE=$(( DU_SIZE * 110 / 100 ))
# Ensure minimum partition size from parameter.txt
ROOTFS_SIZE_MB=$(( ROOTFS_SECTORS / 2048 ))
[[ ${ALLOC_SIZE} -lt ${ROOTFS_SIZE_MB} ]] && ALLOC_SIZE=${ROOTFS_SIZE_MB}

ROOTFS_IMG="${IMAGE_DIR}/rootfs.img"
info "  Creating ext4 from directory (${ALLOC_SIZE} MB)..."
# U-Boot compat: disable 64bit and metadata_csum (U-Boot ext4 driver doesn't support them)
mkfs.ext4 -O ^64bit,^metadata_csum -d "${ROOTFS_TMP}" -L "${ROOTFS_LABEL:-rootfs}" -F "${ROOTFS_IMG}" "${ALLOC_SIZE}M" 2>/dev/null
info "  rootfs.img: $(du -h "${ROOTFS_IMG}" 2>/dev/null | cut -f1)"

rm -rf "${ROOTFS_TMP}"  # Free space before creating more images

# -------------------------------------------------------------------
# Step 4: Create boot.img with mkfs.ext4 -d (no mount, no sudo!)
# -------------------------------------------------------------------
info "Creating boot.img..."

BOOT_TMP=$(mktemp -d)
trap "rm -rf ${BOOT_TMP}" EXIT

# Copy boot files (kernel Image + DTB + extlinux, no FIT to save space for 64MB partition)
[[ -f "${BOOT_ASSETS}/Image" ]] && cp "${BOOT_ASSETS}/Image" "${BOOT_TMP}/Image"
[[ -f "${INITRD_DEST}" ]] && cp "${INITRD_DEST}" "${BOOT_TMP}/initrd.img"
mkdir -p "${BOOT_TMP}/dtbs" "${BOOT_TMP}/overlays" "${BOOT_TMP}/extlinux"
[[ -f "${BOOT_ASSETS}/myd-lr3576j-gk.dtb" ]] && cp "${BOOT_ASSETS}/myd-lr3576j-gk.dtb" "${BOOT_TMP}/dtbs/"
cp "${BOOT_ASSETS}/overlays/"*.dtbo "${BOOT_TMP}/overlays/" 2>/dev/null || true
cp "${BOOT_ASSETS}/extlinux/extlinux.conf" "${BOOT_TMP}/extlinux/" 2>/dev/null || true

BOOT_SECTORS=$(grep -oP '0x[0-9a-fA-F]+(?=@0x[0-9a-fA-F]+\(boot)' "${PARAMETER_SRC}" 2>/dev/null || echo "0x20000")
BOOT_SIZE_MB=$(( BOOT_SECTORS / 2048 ))

BOOT_IMG="${IMAGE_DIR}/boot.img"
# U-Boot compat: disable 64bit and metadata_csum (U-Boot ext4 driver doesn't support them)
mkfs.ext4 -O ^64bit,^metadata_csum -d "${BOOT_TMP}" -L "${BOOT_LABEL:-boot}" -F "${BOOT_IMG}" "${BOOT_SIZE_MB}M" 2>/dev/null
info "  boot.img: $(du -h "${BOOT_IMG}" | cut -f1)"

rm -rf "${BOOT_TMP}"

# -------------------------------------------------------------------
# Step 5: Other partition images
# -------------------------------------------------------------------
info "Creating other partitions..."

# MiniLoaderAll.bin = idbloader
cp "${BOOT_ASSETS}/idbloader.img" "${IMAGE_DIR}/MiniLoaderAll.bin"
# uboot.img
cp "${BOOT_ASSETS}/u-boot.itb" "${IMAGE_DIR}/uboot.img"

# Recovery = SDK FIT boot.img (small, ~49MB, fits in 64MB recovery partition)
# NOT our ext4 boot (256MB, too big for recovery partition)
if [[ -f "${SDK_PATH}/output/firmware/boot.img" ]]; then
    cp "${SDK_PATH}/output/firmware/boot.img" "${IMAGE_DIR}/recovery.img"
elif [[ -f "${SDK_PATH}/kernel-6.1/boot.img" ]]; then
    cp "${SDK_PATH}/kernel-6.1/boot.img" "${IMAGE_DIR}/recovery.img"
else
    cp "${BOOT_IMG}" "${IMAGE_DIR}/recovery.img" 2>/dev/null || true
fi

# misc (4MB empty)
MISC_IMG="${IMAGE_DIR}/misc.img"
MISC_TMP=$(mktemp -d)
mkfs.ext4 -d "${MISC_TMP}" -L "misc" -F "${MISC_IMG}" 4M 2>/dev/null
rmdir "${MISC_TMP}"

