#!/bin/bash
set -euo pipefail

# ==========================================================================
# build-remote.sh — Remote Native Ubuntu Rootfs Build
#
# Architecture:
#   TARGET (arm64)          → ubuntu-image native → rootfs.tar.gz
#   DEV HOST (x86)          → Rockchip tools       → update.img
#
# The heavy compilation (ubuntu-image) runs natively on the arm64 target
# — no QEMU, ~20-30 min. The final packaging uses Rockchip x86 tools
# (afptool + rkImageMaker) on the dev host.
#
# Config (from .env or environment):
#   BUILD_HOST     — remote target IP (REQUIRED)
#   BUILD_USER     — ssh user (default: root)
#   BUILD_PASS     — ssh password (REQUIRED for sshpass)
#   BUILD_DIR      — working dir on remote (default: /tmp/ubuntu-build)
#   UBUNTU_VARIANT — server | desktop (default: desktop)
#   UBUNTU_SERIES  — noble | questing (default: noble)
#
# Usage:
#   bash ubuntu/remote-build.sh 192.168.1.231 mypassword
#   bash ubuntu/build.sh          # BUILD_MODE=remote triggers this script
# ==========================================================================

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
SDK_PATH="${SDK_PATH:-$(dirname "${PROJECT_DIR}")}"

# -------------------------------------------------------------------
# Resolve build config from .env + env vars + args
# -------------------------------------------------------------------
if [[ -f "${PROJECT_DIR}/.env" ]]; then
    source "${PROJECT_DIR}/.env"
fi

HOST="${BUILD_HOST:-}"
USER="${BUILD_USER:-root}"
PASS="${BUILD_PASS:-}"
REMOTE_DIR="${BUILD_DIR:-/tmp/ubuntu-build}"
BOARD="${BOARD:-rk3576}"
VARIANT="${UBUNTU_VARIANT:-desktop}"
SERIES="${UBUNTU_SERIES:-noble}"

# Allow CLI positional args: remote-build.sh <IP> [password] [variant]
if [[ $# -ge 1 ]]; then
    HOST="$1"
fi
if [[ $# -ge 2 ]]; then
    PASS="$2"
fi
if [[ $# -ge 3 ]]; then
    VARIANT="$3"
fi

if [[ -z "${HOST}" ]]; then
    echo "ERROR: BUILD_HOST not set."
    echo "Usage: $0 <IP> [password] [variant]"
    echo "  Or set BUILD_HOST + BUILD_PASS in ubuntu/.env"
    exit 1
fi

REMOTE="${USER}@${HOST}"
ARTIFACTS_DIR="${PROJECT_DIR}/artifacts"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
info()  { echo -e "${GREEN}[REMOTE]${NC} $*"; }
warn()  { echo -e "${YELLOW}[REMOTE]${NC} $*"; }
error() { echo -e "${RED}[REMOTE]${NC} $*"; exit 1; }
step()  { echo ""; echo -e "${CYAN}━━━ $* ━━━${NC}"; }

# -------------------------------------------------------------------
# SSH helpers (with optional sshpass)
# -------------------------------------------------------------------
SSHPASS_BIN=""
if [[ -n "${PASS}" ]] && command -v sshpass &>/dev/null; then
    SSHPASS_BIN="sshpass -p ${PASS}"
elif [[ -n "${PASS}" ]]; then
    warn "sshpass not installed — cannot use password auth."
    warn "  Install: sudo apt-get install sshpass"
    warn "  Falling back to key-based SSH..."
fi

ssh_ok() {
    ${SSHPASS_BIN} ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
        -o BatchMode=yes "${REMOTE}" "echo SSH_OK" 2>/dev/null || return 1
}
ssh_cmd() {
    ${SSHPASS_BIN} ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "${REMOTE}" "$@"
}
scp_to() {
    ${SSHPASS_BIN} scp -o StrictHostKeyChecking=no -r "$1" "${REMOTE}:$2"
}
scp_from() {
    ${SSHPASS_BIN} scp -o StrictHostKeyChecking=no -r "${REMOTE}:$1" "$2"
}

# ==========================================================================
# Main
# ==========================================================================

echo ""
echo "============================================="
echo " Ubuntu Remote Native Build"
echo "  Target:   ${REMOTE}"
echo "  Variant:  ${VARIANT} (${SERIES})"
echo "  Board:    ${BOARD}"
echo "============================================="
echo ""

# =====================================================================
# Phase 1: Local — copy boot assets from SDK
# =====================================================================
step "Phase 1/5: Local — copying boot assets from SDK"

BOARD_CONF="${PROJECT_DIR}/boards/${BOARD}/${BOARD}.conf"
if [[ ! -f "${BOARD_CONF}" ]]; then
    error "Board config not found: ${BOARD_CONF}"
fi
source "${BOARD_CONF}"

export BOARD SDK_PATH PROJECT_DIR UBUNTU_VARIANT UBUNTU_SERIES

# Copy boot assets directly from SDK (these are pre-built)
BOOT_ASSETS="${ARTIFACTS_DIR}/boot-assets"
mkdir -p "${BOOT_ASSETS}/overlays" "${BOOT_ASSETS}/extlinux"

[[ ! -f "${BOOT_ASSETS}/idbloader.img" ]] && [[ -f "${SDK_PATH}/output/firmware/MiniLoaderAll.bin" ]] && { cp "${SDK_PATH}/output/firmware/MiniLoaderAll.bin" "${BOOT_ASSETS}/idbloader.img"; info "  idbloader copied"; }
[[ ! -f "${BOOT_ASSETS}/idbloader.img" ]] && [[ -f "${SDK_PATH}/u-boot/${IDBLOADER_SOURCE}" ]] && { cp "${SDK_PATH}/u-boot/${IDBLOADER_SOURCE}" "${BOOT_ASSETS}/idbloader.img"; info "  idbloader copied (u-boot)"; }

[[ ! -f "${BOOT_ASSETS}/u-boot.itb" ]] && [[ -f "${SDK_PATH}/output/firmware/uboot.img" ]] && { cp "${SDK_PATH}/output/firmware/uboot.img" "${BOOT_ASSETS}/u-boot.itb"; info "  u-boot copied"; }
[[ ! -f "${BOOT_ASSETS}/u-boot.itb" ]] && [[ -f "${SDK_PATH}/u-boot/uboot.img" ]] && { cp "${SDK_PATH}/u-boot/uboot.img" "${BOOT_ASSETS}/u-boot.itb"; info "  u-boot copied (source)"; }

[[ ! -f "${BOOT_ASSETS}/boot.img" ]] && [[ -f "${SDK_PATH}/output/firmware/boot.img" ]] && { cp "${SDK_PATH}/output/firmware/boot.img" "${BOOT_ASSETS}/boot.img"; info "  boot.img copied"; }
[[ ! -f "${BOOT_ASSETS}/boot.img" ]] && [[ -f "${SDK_PATH}/kernel-6.1/boot.img" ]] && { cp "${SDK_PATH}/kernel-6.1/boot.img" "${BOOT_ASSETS}/boot.img"; info "  boot.img copied (kernel)"; }

[[ ! -f "${BOOT_ASSETS}/Image" ]] && [[ -f "${SDK_PATH}/kernel-6.1/arch/arm64/boot/Image" ]] && { cp "${SDK_PATH}/kernel-6.1/arch/arm64/boot/Image" "${BOOT_ASSETS}/Image"; info "  Image copied"; }

dtb="${DTB_BASE:-myd-lr3576j-gk.dtb}"
[[ ! -f "${BOOT_ASSETS}/${dtb}" ]] && { cp "${SDK_PATH}/kernel-6.1/arch/arm64/boot/dts/rockchip/${dtb}" "${BOOT_ASSETS}/${dtb}" 2>/dev/null; info "  ${dtb} copied"; }

info "Boot assets prepared."

# =====================================================================
# Phase 2: Remote — verify connectivity
# =====================================================================
step "Phase 2/5: Remote — verifying connectivity"

# Test connection
if ! ssh_ok; then
    echo ""
    warn "Cannot connect to ${REMOTE}."
    warn "Check:"
    warn "  1. IP address: ${HOST}"
    warn "  2. SSH is running on target"
    warn "  3. Password is correct (BUILD_PASS in .env)"
    warn "  4. Or set up SSH key: ssh-copy-id ${REMOTE}"
    echo ""
    error "SSH connection failed"
fi

REMOTE_ARCH=$(ssh_cmd "uname -m")
REMOTE_OS=$(ssh_cmd "cat /etc/os-release 2>/dev/null | grep '^ID=' | cut -d= -f2 | tr -d '\"' || echo 'unknown'")
info "Connected: ${REMOTE_OS} / ${REMOTE_ARCH}"

if [[ "${REMOTE_ARCH}" != "aarch64" && "${REMOTE_ARCH}" != "arm64" ]]; then
    warn "Remote arch is ${REMOTE_ARCH}, not arm64. Native build may fail."
fi

# =====================================================================
# Phase 3: Remote — setup build environment
# =====================================================================
step "Phase 3/5: Remote — setting up build environment"

# Copy setup script to remote
SETUP_SCRIPT="${PROJECT_DIR}/scripts/setup-target.sh"
if [[ -f "${SETUP_SCRIPT}" ]]; then
    info "Uploading setup script..."
    scp_to "${SETUP_SCRIPT}" "${REMOTE_DIR}/setup-target.sh"
fi

# Check if ubuntu-image is available on remote
HAS_UBUNTU_IMAGE=$(ssh_cmd "/snap/ubuntu-image/current/bin/ubuntu-image classic --help 2>/dev/null && echo YES || echo NO" 2>/dev/null || echo "NO")

if [[ "${HAS_UBUNTU_IMAGE}" == "YES" ]]; then
    info "ubuntu-image already available on remote."
else
    info "Installing build dependencies on remote (this may take a few minutes)..."
    ssh_cmd "sudo bash ${REMOTE_DIR}/setup-target.sh" || {
        warn "Auto-setup failed. Trying manual install..."
        # Fallback: try to install minimal deps
        ssh_cmd "sudo apt-get update -qq && sudo apt-get install -y -qq debootstrap gdisk e2fsprogs git" || true
        ssh_cmd "sudo snap install ubuntu-image --classic 2>&1 || echo 'snap failed'" || true
    }
fi

# Verify remote tools
info "Verifying remote tools..."
ssh_cmd "
echo '  debootstrap:' \$(debootstrap --version 2>/dev/null || echo 'MISSING')
echo '  ubuntu-image:' \$(/snap/ubuntu-image/current/bin/ubuntu-image classic --help 2>/dev/null || echo 'MISSING')
echo '  mkfs.ext4:' \$(which mkfs.ext4 2>/dev/null || echo 'MISSING')
echo '  sgdisk:' \$(which sgdisk 2>/dev/null || echo 'MISSING')
echo '  git:' \$(git --version 2>/dev/null || echo 'MISSING')
" || warn "Tool verification failed — build may fail"

# Ensure /tmp is exec (LP:#2075546)
ssh_cmd "grep -q noexec /proc/mounts 2>/dev/null | grep /tmp && sudo mount -o remount,exec /tmp 2>/dev/null; true" || true

# =====================================================================
# Phase 4: Remote — sync build files and run native build
# =====================================================================
step "Phase 4/5: Remote — syncing and building rootfs (native arm64)"

info "Syncing build files to remote..."
ssh_cmd "mkdir -p ${REMOTE_DIR}"

# Rsync: exclude artifacts, .git, and kernel source (not needed for rootfs build)
RSYNC_OPTS=(
    -av
    --delete
    --exclude='artifacts/'
    --exclude='.git/'
    --exclude='*.img'
    --exclude='*.tar.gz'
    --exclude='*.log'
    --exclude='work/'
    --exclude='__pycache__/'
    --exclude='*.pyc'
)

info "  Syncing ubuntu/ → ${REMOTE}:${REMOTE_DIR}/"
${SSHPASS_BIN} rsync "${RSYNC_OPTS[@]}" \
    -e "ssh -o StrictHostKeyChecking=no" \
    "${PROJECT_DIR}/" "${REMOTE}:${REMOTE_DIR}/" 2>&1 | tail -5

info "  Syncing Rockchip debs (if available)..."
DEBS_SRC="${SDK_PATH}/debian/packages/arm64"
if [[ -d "${DEBS_SRC}" ]]; then
    ${SSHPASS_BIN} rsync -av \
        -e "ssh -o StrictHostKeyChecking=no" \
        "${DEBS_SRC}/" "${REMOTE}:${REMOTE_DIR}/debian/packages/arm64/" 2>&1 | tail -3 || true
    info "  Rockchip debs synced."
else
    warn "  No Rockchip debs found at ${DEBS_SRC} — skipping"
fi

# Sync kernel modules source if needed for external module build (we'll do it locally later)
info "Files synced."

# Run the native build on remote
info ""
info "Starting native rootfs build on remote (this will take 20-60 minutes)..."
info "  NOTE: snapd/ubuntu-image runs natively on arm64 — no QEMU overhead!"
info ""

BUILD_START=$(date +%s)

# Build command — run ubuntu-image on remote
# SKIP_SDK_CHECKS=1 — no kernel source on remote, just build rootfs
# rootfs-only — stop after rootfs tarball, don't try to package
ssh_cmd bash -s "${REMOTE_DIR}" "${VARIANT}" "${SERIES}" "${BOARD}" << 'REMOTE_BUILD'
set -euo pipefail

REMOTE_DIR="$1"
VARIANT="$2"
SERIES="$3"
BOARD="$4"

cd "${REMOTE_DIR}/ubuntu-build-service"

export BOARD="${BOARD}"
export SDK_PATH="${REMOTE_DIR}"
export PROJECT_DIR="${REMOTE_DIR}"
export UBUNTU_VARIANT="${VARIANT}"
export UBUNTU_SERIES="${SERIES}"
export SKIP_SDK_CHECKS=1
export BUILD_MODE=local

echo "Remote build starting..."
echo "  Variant: ${VARIANT}"
echo "  Series:  ${SERIES}"
echo "  Board:   ${BOARD}"
echo "  Arch:    $(uname -m) (native)"
echo ""

bash build.sh rootfs-only
REMOTE_BUILD

BUILD_END=$(date +%s)
BUILD_DURATION=$(( BUILD_END - BUILD_START ))
BUILD_MIN=$(( BUILD_DURATION / 60 ))

info "Remote build completed in ${BUILD_MIN} minutes."

# Verify rootfs was created
ROOTFS_TAR="${REMOTE_DIR}/artifacts/rootfs.tar.gz"
if ! ssh_cmd "test -f ${ROOTFS_TAR}"; then
    error "rootfs.tar.gz not found on remote! Build failed. Check remote logs at ${REMOTE_DIR}/artifacts/ubuntu-image.log"
fi

REMOTE_SIZE=$(ssh_cmd "du -h ${ROOTFS_TAR} | cut -f1")
info "Remote rootfs.tar.gz: ${REMOTE_SIZE}"

# =====================================================================

# =====================================================================
# Phase 5: Pull rootfs tarball from remote target
# =====================================================================
step "Phase 5/6: Pulling rootfs.tar.gz from remote"

# Verify rootfs was created
ROOTFS_TAR="${REMOTE_DIR}/artifacts/rootfs.tar.gz"
if ! ssh_cmd "test -f ${ROOTFS_TAR}"; then
    error "rootfs.tar.gz not found on remote! Build failed."
fi

REMOTE_SIZE=$(ssh_cmd "du -h ${ROOTFS_TAR} | cut -f1")
info "Remote rootfs.tar.gz: ${REMOTE_SIZE}"

info "Pulling rootfs.tar.gz from ${REMOTE}..."
mkdir -p "${ARTIFACTS_DIR}"
scp_from "${ROOTFS_TAR}" "${ARTIFACTS_DIR}/rootfs.tar.gz"

# Also pull the build log
scp_from "${REMOTE_DIR}/artifacts/ubuntu-image.log" "${ARTIFACTS_DIR}/ubuntu-image.log" 2>/dev/null || true

LOCAL_SIZE=$(du -h "${ARTIFACTS_DIR}/rootfs.tar.gz" | cut -f1)
info "Local rootfs.tar.gz: ${LOCAL_SIZE}"

# =====================================================================
# Phase 6: Local — package update.img with Rockchip tools
#
# This runs on the x86 dev host because afptool + rkImageMaker
# are Rockchip proprietary x86 binaries.
# =====================================================================
step "Phase 6/6: Local — packaging update.img (Rockchip tools)"

# Source board config for packaging
BOARD_CONF="${PROJECT_DIR}/boards/${BOARD}/${BOARD}.conf"
[[ -f "${BOARD_CONF}" ]] && source "${BOARD_CONF}"

export BOARD SDK_PATH PROJECT_DIR

# Copy boot assets from SDK
info "Preparing boot assets..."
BOOT_ASSETS="${ARTIFACTS_DIR}/boot-assets"
mkdir -p "${BOOT_ASSETS}/overlays" "${BOOT_ASSETS}/extlinux"

for asset_pair in \
    "output/firmware/MiniLoaderAll.bin:idbloader.img" \
    "output/firmware/uboot.img:u-boot.itb" \
    "output/firmware/boot.img:boot.img" \
    "kernel-6.1/arch/arm64/boot/Image:Image" \
    "kernel-6.1/arch/arm64/boot/dts/rockchip/${DTB_BASE:-myd-lr3576j-gk.dtb}:${DTB_BASE:-myd-lr3576j-gk.dtb}"; do
    src="${SDK_PATH}/${asset_pair%%:*}"
    dst="${asset_pair##*:}"
    if [[ -f "${src}" && ! -f "${BOOT_ASSETS}/${dst}" ]]; then
        cp -v "${src}" "${BOOT_ASSETS}/${dst}"
    fi
done

# Generate extlinux.conf
SERIAL_PARAMS="${SERIAL_CONSOLE_PARAMS:-earlycon=uart8250,mmio32,0x2ad40000 console=ttyFIQ0,1500000n8}"
DTB="${DTB_BASE:-myd-lr3576j-gk.dtb}"
ROOTFS_LABEL="${ROOTFS_LABEL:-rootfs}"

cat > "${BOOT_ASSETS}/extlinux/extlinux.conf" <<EXTLINUX_EOF
timeout 30
default ubuntu-overlay

label ubuntu-overlay
    menu label Ubuntu 24.04 (${VARIANT}) — OverlayFS
    kernel /Image
    fdt /dtbs/${DTB}
    initrd /initrd.img
    fdtoverlays /overlays/
    append ${SERIAL_PARAMS} ro rootwait root=PARTLABEL=${ROOTFS_LABEL} rootfstype=ext4

label ubuntu-fit
    menu label Ubuntu 24.04 (${VARIANT}) — FIT fallback
    kernel /boot.img
    fdt /dtbs/${DTB}
    fdtoverlays /overlays/
    append ${SERIAL_PARAMS} rw rootwait root=PARTLABEL=${ROOTFS_LABEL} rootfstype=ext4
EXTLINUX_EOF
info "extlinux.conf generated"

# Build external kernel modules (optional)
if [[ -f "${SCRIPT_DIR}/build-external-modules.sh" ]]; then
    info "Building external kernel modules..."
    BOARD="${BOARD}" SDK_PATH="${SDK_PATH}" \
        bash "${SCRIPT_DIR}/build-external-modules.sh" 2>&1 | tail -5 || \
        warn "External modules build failed (non-fatal)"
fi

# Package with Rockchip tools
if [[ "${PACKAGE_METHOD:-mkupdate}" == "mkupdate" ]]; then
    info "Packaging update.img with Rockchip afptool + rkImageMaker..."
    BOARD="${BOARD}" SDK_PATH="${SDK_PATH}" bash "${SCRIPT_DIR}/pack-updateimg.sh"
else
    info "Assembling GPT disk image with sgdisk..."
    BOARD="${BOARD}" SDK_PATH="${SDK_PATH}" bash "${SCRIPT_DIR}/assemble-disk.sh"
fi

# Fix permissions on artifacts
for item in "${ARTIFACTS_DIR}"/*; do
    [[ -e "${item}" ]] || continue
    case "$(basename "${item}")" in
        work) ;;
        *)
            [[ "$(stat -c %U "${item}" 2>/dev/null)" = "root" ]] && \
                chown -R "$(whoami):$(whoami)" "${item}" 2>/dev/null || true
            ;;
    esac
done

BUILD_END=$(date +%s)
BUILD_TOTAL=$(( (BUILD_END - BUILD_START) / 60 ))

echo ""
echo "============================================="
info "Remote native build complete!"
info "  Variant:      ${VARIANT} (${SERIES})"
info "  rootfs.tar.gz: ${ARTIFACTS_DIR}/rootfs.tar.gz (${LOCAL_SIZE})"
if [[ -f "${ARTIFACTS_DIR}/update.img" ]]; then
    info "  update.img:   ${ARTIFACTS_DIR}/update.img ($(du -h "${ARTIFACTS_DIR}/update.img" | cut -f1))"
fi
if ls "${ARTIFACTS_DIR}/ubuntu-"*"-arm64.img" 2>/dev/null | head -1 >/dev/null; then
    IMG=$(ls "${ARTIFACTS_DIR}/ubuntu-"*"-arm64.img" 2>/dev/null | head -1)
    info "  disk image:   ${IMG} ($(du -h "${IMG}" | cut -f1))"
fi
info "  Build time:   ${BUILD_TOTAL} min (native arm64 rootfs + local packaging)"
info "  Build log:    ${ARTIFACTS_DIR}/ubuntu-image.log"
echo "============================================="
