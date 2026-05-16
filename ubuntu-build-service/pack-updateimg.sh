#!/bin/bash
set -euo pipefail

# ==========================================================================
# pack-updateimg.sh — Package Ubuntu rootfs into Rockchip update.img
#
# Uses Rockchip SDK tools (afptool + rkImageMaker) to create a flashable
# update.img containing the Ubuntu rootfs alongside SDK boot firmware.
#
# Requirements:
#   - rootfs.tar.gz in artifacts/
#   - boot assets in boot-assets/ (idbloader.img, u-boot.itb, boot.img)
#   - SDK_PATH pointing to Rockchip SDK root
# ==========================================================================

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
export SDK_PATH="${SDK_PATH:-$(dirname "${PROJECT_DIR}")}"

BOARD="${BOARD:-rk3576}"
BOARD_CONF="${PROJECT_DIR}/boards/${BOARD}/${BOARD}.conf"
if [[ ! -f "${BOARD_CONF}" ]]; then
    echo "ERROR: Board config not found: ${BOARD_CONF}"
    exit 1
fi
source "${BOARD_CONF}"
source "${SCRIPT_DIR}/merge-overlays.sh"

# Ubuntus own parameter.txt (prefer over SDK version)
PARAMETER_SRC="${PROJECT_DIR}/boards/${BOARD}/parameter.txt"
[[ -f "${PARAMETER_SRC}" ]] || PARAMETER_SRC="${SDK_PATH}/device/rockchip/.chips/${SOC_MODEL}/parameter.txt"

ARTIFACTS_DIR="${PROJECT_DIR}/artifacts"
BOOT_ASSETS="${PROJECT_DIR}/artifacts/boot-assets"
ROOTFS_TAR="${ARTIFACTS_DIR}/rootfs.tar.gz"

# Rockchip SDK tools
RKDEV="${SDK_PATH}/tools/linux/Linux_Pack_Firmware/rockdev"
AFTOOL="${RKDEV}/afptool"
RKIMAGEMAKER="${RKDEV}/rkImageMaker"

# Output
PACK_DIR="${ARTIFACTS_DIR}/pack"
IMAGE_DIR="${PACK_DIR}/Image"
UPDATE_IMG="${ARTIFACTS_DIR}/update.img"

# Required input files
IDBLOADER="${BOOT_ASSETS}/idbloader.img"
UBOOT_ITB="${BOOT_ASSETS}/u-boot.itb"
BOOT_IMG="${BOOT_ASSETS}/boot.img"

# Validate inputs
for f in "${ROOTFS_TAR}" "${IDBLOADER}" "${UBOOT_ITB}" "${BOOT_IMG}"; do
    if [[ ! -f "${f}" ]]; then
        echo "ERROR: Required file not found: ${f}"
        exit 1
    fi
done

for tool in "${AFTOOL}" "${RKIMAGEMAKER}"; do
    if [[ ! -x "${tool}" ]]; then
        echo "ERROR: Tool not found or not executable: ${tool}"
        exit 1
    fi
done

# -------------------------------------------------------------------
# Step 1: Prepare Image directory
# -------------------------------------------------------------------
echo "==> Preparing Image directory..."
sudo rm -rf "${PACK_DIR}"
mkdir -p "${IMAGE_DIR}"

# -------------------------------------------------------------------
# Step 2: Create rootfs.img (ext4) from Ubuntu rootfs tarball
# -------------------------------------------------------------------
echo "==> Creating rootfs.img from Ubuntu rootfs tarball..."

# Calculate partition size from parameter.txt (sectors → bytes)
# Parse rootfs partition size from parameter.txt; fallback to 4GB for grow partitions
ROOTFS_SECTORS=$(grep -oP '0x[0-9a-fA-F]+(?=@0x[0-9a-fA-F]+\(rootfs)' "${PARAMETER_SRC}" 2>/dev/null || echo "0x800000")
ROOTFS_SECTORS_DEC=$(( ROOTFS_SECTORS ))
ROOTFS_SIZE=$(( ROOTFS_SECTORS_DEC * 512 ))
ROOTFS_SIZE_MB=$(( ROOTFS_SIZE / 1024 / 1024 ))

echo "  rootfs partition: ${ROOTFS_SECTORS_DEC} sectors (${ROOTFS_SIZE_MB} MB)"

# Get extracted size from tarball
TARBALL_SIZE=$(tar -tzf "${ROOTFS_TAR}" 2>/dev/null | while read -r f; do echo "$f"; done | wc -l)
echo "  tarball entries: ${TARBALL_SIZE} files"

# Create a sparse image large enough for the tarball contents
# Use actual tarball expanded size + 30% margin, capped at partition size
TAR_UNCOMPRESSED=$(gzip -l "${ROOTFS_TAR}" 2>/dev/null | tail -1 | awk '{print $2}' || echo "0")
if [[ "${TAR_UNCOMPRESSED}" -gt 0 ]]; then
    NEEDED_MB=$(( TAR_UNCOMPRESSED / 1024 / 1024 * 130 / 100 ))  # +30%
else
    NEEDED_MB=4096  # fallback: 4GB
fi

if [[ "${NEEDED_MB}" -gt "${ROOTFS_SIZE_MB}" ]]; then
    echo "  WARNING: rootfs needs ${NEEDED_MB}MB but partition is ${ROOTFS_SIZE_MB}MB"
    NEEDED_MB="${ROOTFS_SIZE_MB}"
fi

ROOTFS_IMG="${IMAGE_DIR}/rootfs.img"
echo "  creating ext4 image: ${NEEDED_MB} MB..."

# Create ext4 image and populate it
truncate -s "${NEEDED_MB}M" "${ROOTFS_IMG}"
mkfs.ext4 -L "${ROOTFS_LABEL}" -F -q "${ROOTFS_IMG}" 2>/dev/null

ROOTFS_MNT=$(mktemp -d)
# Safety trap: ensure umount on Ctrl+C / crash
cleanup_rootfs_mount() {
    mountpoint -q "${ROOTFS_MNT}" 2>/dev/null && sudo umount "${ROOTFS_MNT}" 2>/dev/null
    [[ -d "${ROOTFS_MNT}" ]] && rmdir "${ROOTFS_MNT}" 2>/dev/null
}
trap cleanup_rootfs_mount EXIT INT TERM
sudo mount "${ROOTFS_IMG}" "${ROOTFS_MNT}"
sudo tar -xzf "${ROOTFS_TAR}" -C "${ROOTFS_MNT}" --strip-components=0

merge_overlays "${ROOTFS_MNT}"

sudo umount "${ROOTFS_MNT}"
rmdir "${ROOTFS_MNT}"

ROOTFS_IMG_SIZE=$(stat -c%s "${ROOTFS_IMG}")
echo "  rootfs.img created: $(( ROOTFS_IMG_SIZE / 1024 / 1024 )) MB"

# -------------------------------------------------------------------
# Step 3: Copy firmware files into Image/
# -------------------------------------------------------------------
echo "==> Copying firmware files..."

# MiniLoaderAll.bin = idbloader (SPL + DDR init)
cp -v "${IDBLOADER}" "${IMAGE_DIR}/MiniLoaderAll.bin"

# uboot.img = U-Boot FIT (U-Boot proper + ATF + OP-TEE)
cp -v "${UBOOT_ITB}" "${IMAGE_DIR}/uboot.img"

# boot.img = kernel FIT (kernel + DTB + initramfs)
cp -v "${BOOT_IMG}" "${IMAGE_DIR}/boot.img"

# -------------------------------------------------------------------
# Step 4: Create partition images (based on UPDATE_PARTITIONS in board config)
# -------------------------------------------------------------------
echo "==> Creating partition images (UPDATE_PARTITIONS='${UPDATE_PARTITIONS:-}')..."

# Helper: check if partition is in UPDATE_PARTITIONS list
has_part() { [[ " ${UPDATE_PARTITIONS} " =~ " $1 " ]]; }

if has_part misc; then
    MISC_IMG="${IMAGE_DIR}/misc.img"
    truncate -s 4M "${MISC_IMG}"
    mkfs.ext4 -L "misc" -F -q "${MISC_IMG}" 2>/dev/null
    echo "  misc.img (4MB)"
fi

if has_part recovery; then
    cp -v "${BOOT_IMG}" "${IMAGE_DIR}/recovery.img"
fi

if has_part oem; then
    OEM_IMG="${IMAGE_DIR}/oem.img"
    truncate -s 128M "${OEM_IMG}"
    mkfs.ext4 -L "oem" -F -q "${OEM_IMG}" 2>/dev/null
    echo "  oem.img (128MB)"
fi

if has_part userdata; then
    USERDATA_IMG="${IMAGE_DIR}/userdata.img"
    truncate -s 128M "${USERDATA_IMG}"
    mkfs.ext4 -L "userdata" -F -q "${USERDATA_IMG}" 2>/dev/null
    echo "  userdata.img (128MB)"
fi

# -------------------------------------------------------------------
# Step 5: Copy parameter.txt and package-file
# -------------------------------------------------------------------
echo "==> Copying configuration files..."

# Use the SDK's parameter.txt for the chip
# Use Ubuntu's own parameter.txt (not SDK's — we control partition layout)
if [[ -f "${PARAMETER_SRC}" ]]; then
    cp -v "${PARAMETER_SRC}" "${IMAGE_DIR}/parameter.txt"
else
    echo "ERROR: parameter.txt not found at ${PARAMETER_SRC}"
    exit 1
fi

# Ubuntu's own package-file (prefer over SDK version)
PACKAGE_FILE_SRC="${PROJECT_DIR}/boards/${BOARD}/package-file"
[[ -f "${PACKAGE_FILE_SRC}" ]] || PACKAGE_FILE_SRC="${RKDEV}/${BOARD}-package-file"
if [[ -f "${PACKAGE_FILE_SRC}" ]]; then
    cp -v "${PACKAGE_FILE_SRC}" "${PACK_DIR}/package-file"
else
    echo "ERROR: package-file not found at ${PACKAGE_FILE_SRC}"
    exit 1
fi

# -------------------------------------------------------------------
# Step 6: Run afptool to create firmware.img inside update.img
# -------------------------------------------------------------------
echo "==> Running afptool to pack firmware image..."
(
    cd "${PACK_DIR}"
    "${AFTOOL}" -pack ./ Image/update.img
)

# -------------------------------------------------------------------
# Step 7: Run rkImageMaker to create final update.img
# -------------------------------------------------------------------
echo "==> Running rkImageMaker to create final update.img..."
(
    cd "${PACK_DIR}"
    "${RKIMAGEMAKER}" -RK3576 Image/MiniLoaderAll.bin Image/update.img "${UPDATE_IMG}" -os_type:androidos
)

# Clean up pack directory (keep only update.img)
sudo rm -rf "${PACK_DIR}"

echo ""
echo "============================================="
echo "  update.img created: ${UPDATE_IMG}"
echo "  Size: $(du -h "${UPDATE_IMG}" | cut -f1)"
echo "  Board: ${BOARD_VENDOR} ${BOARD_MODEL} (${SOC_MODEL})"
echo "============================================="
