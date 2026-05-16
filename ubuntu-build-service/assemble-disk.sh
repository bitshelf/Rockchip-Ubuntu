#!/bin/bash
set -euo pipefail

# ==========================================================================
# assemble-disk.sh — Assemble final disk image for any board
#
# Uses board config from boards/<BOARD>/board.conf
# All board-specific values come from the config file.
# ==========================================================================

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"

# Auto-detect SDK_PATH from script location if not set
export SDK_PATH="${SDK_PATH:-$(dirname "${PROJECT_DIR}")}"

# Default board - override with BOARD=rk3588-board ./assemble-disk.sh
BOARD="${BOARD:-rk3576}"
BOARD_CONF="${PROJECT_DIR}/boards/${BOARD}/${BOARD}.conf"

if [[ ! -f "${BOARD_CONF}" ]]; then
    echo "ERROR: Board config not found: ${BOARD_CONF}"
    echo "Available boards:"
    ls -d "${PROJECT_DIR}/boards/"*/ 2>/dev/null | sed 's/.*\///;s/\.conf//' | sed 's/^/  /'
    exit 1
fi
source "${BOARD_CONF}"

ARTIFACTS_DIR="${PROJECT_DIR}/artifacts"
BOOT_ASSETS="${PROJECT_DIR}/artifacts/boot-assets"

source "${SCRIPT_DIR}/merge-overlays.sh"

DISK_IMG="${ARTIFACTS_DIR}/${IMAGE_NAME_PREFIX}-arm64.img"
ROOTFS_TAR="${ARTIFACTS_DIR}/rootfs.tar.gz"

IDBLOADER="${BOOT_ASSETS}/idbloader.img"
UBOOT="${BOOT_ASSETS}/u-boot.itb"
BOOT_IMG="${BOOT_ASSETS}/boot.img"

# -------------------------------------------------------------------
# Step 1: Create sparse disk image
# -------------------------------------------------------------------
echo "==> Creating sparse disk image (${DISK_SIZE_MB}MB)..."
truncate -s "${DISK_SIZE_MB}M" "${DISK_IMG}"

# -------------------------------------------------------------------
# Step 2: Create GPT partition table
# -------------------------------------------------------------------
echo "==> Creating GPT partition table..."
sgdisk --clear "${DISK_IMG}"

# Partition 1: boot
sgdisk --new=1:${PART_BOOT_START}:+${PART_BOOT_SIZE_MB}M \
  --typecode=1:EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 \
  --change-name=1:${BOOT_LABEL} "${DISK_IMG}"

# Partition 2: rootfs (read-only base system)
sgdisk --new=2:0:+${PART_ROOTFS_SIZE_MB}M \
  --typecode=2:0FC63DAF-8483-4772-8E79-3D69D8477DE4 \
  --change-name=2:${ROOTFS_LABEL} "${DISK_IMG}"

# Partition 3: overlay (only if ROOTFS_OVERLAY_ENABLE=yes)
if [[ "${ROOTFS_OVERLAY_ENABLE:-yes}" == "yes" ]]; then
    sgdisk --new=3:0:+${PART_OVERLAY_SIZE_MB}M \
      --typecode=3:0FC63DAF-8483-4772-8E79-3D69D8477DE4 \
      --change-name=3:${OVERLAY_LABEL} "${DISK_IMG}"
fi

# -------------------------------------------------------------------
# Step 3: Write bootloader binaries at raw offsets
# -------------------------------------------------------------------
echo "==> Writing bootloader binaries..."

if [[ ! -f "${IDBLOADER}" ]]; then
    echo "  WARNING: idbloader.img not found at ${IDBLOADER}, skipping"
else
    echo "  idbloader at LBA ${LBA_IDBLOADER}..."
    dd if="${IDBLOADER}" of="${DISK_IMG}" bs=512 seek=${LBA_IDBLOADER} conv=notrunc,fsync status=none
    echo "  OK"
fi

if [[ ! -f "${UBOOT}" ]]; then
    echo "  WARNING: u-boot.itb not found at ${UBOOT}, skipping"
else
    UBOOT_SIZE=$(stat -Lc "%s" "${UBOOT}")
    UBOOT_SECTORS=$(( (UBOOT_SIZE + 511) / 512 ))
    echo "  u-boot.itb at LBA ${LBA_UBOOT} (${UBOOT_SECTORS} sectors)..."
    dd if="${UBOOT}" of="${DISK_IMG}" bs=512 seek=${LBA_UBOOT} conv=notrunc,fsync status=none
    echo "  OK"
    # Verify no overlap with boot partition
    if [ $((LBA_UBOOT + UBOOT_SECTORS)) -gt ${PART_BOOT_START} ]; then
        echo "  ERROR: u-boot.itb overlaps with boot partition!"
        exit 1
    fi
fi

# -------------------------------------------------------------------
# Step 4: Set up loop device and format partitions
# -------------------------------------------------------------------
echo "==> Setting up loop device..."
LOSETUP_DEV=$(sudo losetup --show -fP "${DISK_IMG}")
echo "  Loop device: ${LOSETUP_DEV}"

ROOTFS_MNT=""
BOOT_MNT=""
OVERLAY_MNT=""

cleanup() {
    echo "==> Cleaning up mounts and loop device..."
    sudo umount "${BOOT_MNT}" 2>/dev/null || true
    sudo umount "${OVERLAY_MNT}" 2>/dev/null || true
    sudo umount "${ROOTFS_MNT}" 2>/dev/null || true
    sudo losetup -d "${LOSETUP_DEV}" 2>/dev/null || true
    for d in "${ROOTFS_MNT}" "${BOOT_MNT}" "${OVERLAY_MNT}"; do
        rmdir "$d" 2>/dev/null || true
    done
}
trap cleanup EXIT INT TERM

echo "==> Formatting partitions..."
sudo mkfs.ext4 -L ${BOOT_LABEL} -F -q "${LOSETUP_DEV}p1"
sudo mkfs.ext4 -L ${ROOTFS_LABEL} -F -q "${LOSETUP_DEV}p2"
if [[ "${ROOTFS_OVERLAY_ENABLE:-yes}" == "yes" ]]; then
    sudo mkfs.ext4 -L ${OVERLAY_LABEL} -F -q "${LOSETUP_DEV}p3"
fi

# -------------------------------------------------------------------
# Step 5: Mount and populate
# -------------------------------------------------------------------
ROOTFS_MNT=$(mktemp -d)
BOOT_MNT=$(mktemp -d)
OVERLAY_MNT=$(mktemp -d)

echo "==> Mounting partitions..."
sudo mount "${LOSETUP_DEV}p2" "${ROOTFS_MNT}"
sudo mount "${LOSETUP_DEV}p1" "${BOOT_MNT}"
if [[ "${ROOTFS_OVERLAY_ENABLE:-yes}" == "yes" ]]; then
    sudo mount "${LOSETUP_DEV}p3" "${OVERLAY_MNT}"
    sudo mkdir -p "${OVERLAY_MNT}/upper"
    sudo mkdir -p "${OVERLAY_MNT}/work"
    sudo chmod 0755 "${OVERLAY_MNT}/upper" "${OVERLAY_MNT}/work"
fi

# Extract rootfs tarball
if [[ ! -f "${ROOTFS_TAR}" ]]; then
    echo "ERROR: rootfs tarball not found at ${ROOTFS_TAR}"
    exit 1
fi
echo "==> Extracting rootfs tarball..."
sudo tar -xzf "${ROOTFS_TAR}" -C "${ROOTFS_MNT}"

# -------------------------------------------------------------------
# Step 6: Copy boot assets to boot partition
# -------------------------------------------------------------------
echo "==> Copying boot assets to boot partition..."

if [[ -f "${BOOT_IMG}" ]]; then
    sudo cp "${BOOT_IMG}" "${BOOT_MNT}/boot.img"
    echo "  boot.img OK"
else
    echo "  WARNING: boot.img not found"
fi

if ls "${BOOT_ASSETS}/"*.dtb 1>/dev/null 2>&1; then
    sudo mkdir -p "${BOOT_MNT}/dtbs/"
    sudo cp "${BOOT_ASSETS}/"*.dtb "${BOOT_MNT}/dtbs/" 2>/dev/null || true
    echo "  DTBs OK"
fi

if ls "${BOOT_ASSETS}/overlays/"*.dtbo 1>/dev/null 2>&1; then
    sudo mkdir -p "${BOOT_MNT}/overlays/"
    sudo cp "${BOOT_ASSETS}/overlays/"*.dtbo "${BOOT_MNT}/overlays/" 2>/dev/null || true
    echo "  DTS overlays OK"
fi

if [[ -f "${BOOT_ASSETS}/extlinux/extlinux.conf" ]]; then
    sudo mkdir -p "${BOOT_MNT}/extlinux/"
    sudo cp "${BOOT_ASSETS}/extlinux/extlinux.conf" "${BOOT_MNT}/extlinux/"
    echo "  extlinux.conf OK"
fi

if [[ -f "${BOOT_ASSETS}/boot.scr" ]]; then
    sudo cp "${BOOT_ASSETS}/boot.scr" "${BOOT_MNT}/"
    echo "  boot.scr OK"
fi

# -------------------------------------------------------------------
# Step 7: Apply ubuntu-overlay
# -------------------------------------------------------------------
merge_overlays "${ROOTFS_MNT}"

# -------------------------------------------------------------------
# Step 8: Rootfs finalization
# Hostname + password handled by cloud-init at first boot
# -------------------------------------------------------------------
echo "==> Finalizing rootfs..."

# fix_fwconfig: write /etc/fw_env.config for U-Boot env access
# Used by fw_printenv/fw_setenv and A/B upgrade scripts at runtime
if [[ -n "${UBOOT_ENV_DEV:-}" ]]; then
    local env_offset="${UBOOT_ENV_OFFSET:-0x3f8000}"
    local env_size="${UBOOT_ENV_SIZE:-0x8000}"
    # Try to read actual values from U-Boot .config
    local ubt_config="${SDK_PATH}/u-boot/.config"
    if [[ -f "${ubt_config}" ]]; then
        local cfg_offset
        cfg_offset=$(awk -F= '$1=="CONFIG_ENV_OFFSET" {print $2}' "${ubt_config}" | tail -1)
        local cfg_size
        cfg_size=$(awk -F= '$1=="CONFIG_ENV_SIZE" {print $2}' "${ubt_config}" | tail -1)
        [[ -n "${cfg_offset}" ]] && env_offset="${cfg_offset}"
        [[ -n "${cfg_size}" ]] && env_size="${cfg_size}"
    fi
    sudo mkdir -p "${ROOTFS_MNT}/etc"
    echo "# Device  Offset       Size" | sudo tee "${ROOTFS_MNT}/etc/fw_env.config" > /dev/null
    echo "${UBOOT_ENV_DEV}  ${env_offset}  ${env_size}" | sudo tee -a "${ROOTFS_MNT}/etc/fw_env.config" > /dev/null
    echo "  fw_env.config: ${UBOOT_ENV_DEV} ${env_offset} ${env_size}"
fi

# Serial console
if [[ -f "${ROOTFS_MNT}/lib/systemd/system/serial-getty@.service" ]]; then
    sudo mkdir -p "${ROOTFS_MNT}/etc/systemd/system/getty.target.wants"
    sudo ln -sf /lib/systemd/system/serial-getty@.service \
        "${ROOTFS_MNT}/etc/systemd/system/getty.target.wants/serial-getty@${SERIAL_CONSOLE_DEV}.service" 2>/dev/null || true
fi

# Mask unnecessary timers
for timer in apt-daily.timer apt-daily-upgrade.timer snapd.refresh.timer; do
    sudo ln -sf /dev/null "${ROOTFS_MNT}/etc/systemd/system/${timer}" 2>/dev/null || true
done

# -------------------------------------------------------------------
# Step 9: Sync and finalize
echo "==> Syncing..."
sync

echo ""
echo "============================================="
echo "  Disk image created: ${DISK_IMG}"
echo "  Size: $(du -h "${DISK_IMG}" | cut -f1)"
echo "  Board: ${BOARD_VENDOR} ${BOARD_MODEL} (${SOC_MODEL})"
echo "  Partitions: ${BOOT_LABEL}(${PART_BOOT_SIZE_MB}M) | ${ROOTFS_LABEL}(${PART_ROOTFS_SIZE_MB}M,ro) | ${OVERLAY_LABEL}(${PART_OVERLAY_SIZE_MB}M,rw)"
echo "============================================="
