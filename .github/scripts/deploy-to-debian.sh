#!/bin/bash
# ==========================================================================
# deploy-to-debian.sh — Deploy Ubuntu build to Debian target and build
#
# Pushes ubuntu/ code → builds rootfs natively on arm64 Debian board
# → pulls rootfs back → packages update.img with Rockchip x86 tools.
#
# Usage:
#   bash .github/scripts/deploy-to-debian.sh                      # use .env defaults
#   bash .github/scripts/deploy-to-debian.sh 192.168.1.231         # specify target IP
#   bash .github/scripts/deploy-to-debian.sh 192.168.1.231 server  # build server variant
# ==========================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
SCRIPT_DIR="${REPO_ROOT}/ubuntu"
SDK_PATH="${SDK_PATH:-${REPO_ROOT}}"

# ─── Load config ───────────────────────────────────────────────────────────
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    source "${SCRIPT_DIR}/.env"
fi

# ─── CLI args override ─────────────────────────────────────────────────────
HOST="${1:-${BUILD_HOST:-192.168.1.231}}"
USER="${BUILD_USER:-linaro}"
PASS="${BUILD_PASS:-}"
BOARD="${BOARD:-rk3576}"
VARIANT="${2:-${UBUNTU_VARIANT:-desktop}}"
SERIES="${UBUNTU_SERIES:-noble}"
REMOTE_DIR="${BUILD_DIR:-/tmp/ubuntu-build}"
REMOTE="${USER}@${HOST}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
info()  { echo -e "${GREEN}[DEPLOY]${NC}   $*"; }
warn()  { echo -e "${YELLOW}[DEPLOY]${NC}   $*"; }
error() { echo -e "${RED}[DEPLOY]${NC}   $*"; exit 1; }
step()  { echo ""; echo -e "${CYAN}━━━ $* ━━━${NC}"; }

echo ""
echo "============================================================"
echo " Ubuntu Image Deploy to Debian Board"
echo "  Target:      ${REMOTE}"
echo "  Variant:     ${VARIANT}"
echo "  Series:      ${SERIES}"
echo "  Board:       ${BOARD}"
echo "  SDK Path:    ${SDK_PATH}"
echo "============================================================"
echo ""

# ─── SSH setup ─────────────────────────────────────────────────────────────
SSHPASS_BIN=""
if [[ -n "${PASS}" ]] && command -v sshpass &>/dev/null; then
    SSHPASS_BIN="sshpass -p ${PASS}"
elif [[ -n "${PASS}" ]]; then
    warn "sshpass not installed. Install: sudo apt-get install sshpass"
    warn "Falling back to key-based SSH..."
fi

ssh_cmd() {
    ${SSHPASS_BIN} ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "${REMOTE}" "$@"
}
scp_to() {
    ${SSHPASS_BIN} scp -o StrictHostKeyChecking=no -r "$1" "${REMOTE}:$2"
}
scp_from() {
    ${SSHPASS_BIN} scp -o StrictHostKeyChecking=no -r "${REMOTE}:$1" "$2"
}
rsync_to() {
    ${SSHPASS_BIN} rsync -avz --delete \
        -e "ssh -o StrictHostKeyChecking=no" "$@"
}

# ═══════════════════════════════════════════════════════════════════════════
# Phase 1: Preflight checks
# ═══════════════════════════════════════════════════════════════════════════
step "Phase 1/6: Preflight checks"

# Source board config
BOARD_CONF="${SCRIPT_DIR}/boards/${BOARD}/${BOARD}.conf"
if [[ ! -f "${BOARD_CONF}" ]]; then
    error "Board config not found: ${BOARD_CONF}"
fi
source "${BOARD_CONF}"

# Verify SSH connectivity
if ! ${SSHPASS_BIN} ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
    -o BatchMode=yes "${REMOTE}" "echo SSH_OK" 2>/dev/null; then
    echo ""
    error "Cannot connect to ${REMOTE}. Check:
  1. IP: ${HOST}
  2. SSH running on target
  3. Password/key correct
  4. Try: ssh-copy-id ${REMOTE}"
fi

REMOTE_ARCH=$(ssh_cmd "uname -m")
REMOTE_OS=$(ssh_cmd "cat /etc/os-release 2>/dev/null | grep '^PRETTY_NAME' | cut -d= -f2 | tr -d '\"' || echo 'unknown'")
info "Connected: ${REMOTE_OS} / ${REMOTE_ARCH}"

if [[ "${REMOTE_ARCH}" != "aarch64" && "${REMOTE_ARCH}" != "arm64" ]]; then
    warn "Remote is ${REMOTE_ARCH}, not arm64. Native build may fail."
fi

# Verify local boot assets exist
BOOT_ASSETS="${SCRIPT_DIR}/artifacts/boot-assets"
mkdir -p "${BOOT_ASSETS}/overlays" "${BOOT_ASSETS}/extlinux"

info "Checking local boot assets..."
MISSING_BOOT=()
for asset in \
    "output/firmware/MiniLoaderAll.bin:idbloader.img" \
    "output/firmware/uboot.img:u-boot.itb" \
    "output/firmware/boot.img:boot.img" \
    "kernel-6.1/arch/arm64/boot/Image:Image" \
    "kernel-6.1/arch/arm64/boot/dts/rockchip/${DTB_BASE:-myd-lr3576j-gk.dtb}:${DTB_BASE:-myd-lr3576j-gk.dtb}"; do

    src="${SDK_PATH}/${asset%%:*}"
    dst="${asset##*:}"
    if [[ -f "${src}" ]]; then
        if [[ ! -f "${BOOT_ASSETS}/${dst}" ]]; then
            cp -v "${src}" "${BOOT_ASSETS}/${dst}"
        else
            info "  ${dst} (exists)"
        fi
    else
        MISSING_BOOT+=("${asset%%:*}")
    fi
done

if [[ ${#MISSING_BOOT[@]} -gt 0 ]]; then
    warn "Missing boot assets: ${MISSING_BOOT[*]}"
    warn "Run './build.sh uboot && ./build.sh kernel' first to build them."
    warn "Continuing anyway — build may fail at packaging stage."
fi

# Generate extlinux.conf
ubuntu_ver="24.04"
[[ "${SERIES}" == "noble" ]] && ubuntu_ver="24.04"
[[ "${SERIES}" == "questing" ]] && ubuntu_ver="26.04"

cat > "${BOOT_ASSETS}/extlinux/extlinux.conf" <<EXTLINUX_EOF
timeout 30
default ubuntu-overlay

label ubuntu-overlay
    menu label Ubuntu ${ubuntu_ver} (${SERIES}) — OverlayFS
    kernel /Image
    fdt /dtbs/${DTB_BASE:-myd-lr3576j-gk.dtb}
    initrd /initrd.img
    fdtoverlays /overlays/
    append ${SERIAL_CONSOLE_PARAMS} ro rootwait root=PARTLABEL=${ROOTFS_LABEL:-rootfs} rootfstype=ext4

label ubuntu-fit
    menu label Ubuntu ${ubuntu_ver} (${SERIES}) — FIT fallback
    kernel /boot.img
    fdt /dtbs/${DTB_BASE:-myd-lr3576j-gk.dtb}
    fdtoverlays /overlays/
    append ${SERIAL_CONSOLE_PARAMS} rw rootwait root=PARTLABEL=${ROOTFS_LABEL:-rootfs} rootfstype=ext4

label ubuntu-rescue
    menu label Ubuntu ${ubuntu_ver} (${SERIES}) — Rescue
    kernel /Image
    initrd /initrd.img
    append ${SERIAL_CONSOLE_PARAMS} rw rootwait root=PARTLABEL=${ROOTFS_LABEL:-rootfs} rootfstype=ext4
EXTLINUX_EOF
info "extlinux.conf generated"

# ═══════════════════════════════════════════════════════════════════════════
# Phase 2: Sync ubuntu/ to Debian target
# ═══════════════════════════════════════════════════════════════════════════
step "Phase 2/6: Syncing ubuntu/ to ${REMOTE}"

ssh_cmd "mkdir -p ${REMOTE_DIR}"

info "Syncing ubuntu/ directory..."
rsync_to \
    --exclude='artifacts/work/' \
    --exclude='artifacts/*.img' \
    --exclude='artifacts/*.tar.gz' \
    --exclude='artifacts/*.log' \
    "${SCRIPT_DIR}/" "${REMOTE}:${REMOTE_DIR}/"

# Sync Rockchip debs
DEBS_SRC="${SDK_PATH}/debian/packages/arm64"
if [[ -d "${DEBS_SRC}" ]]; then
    info "Syncing Rockchip debs..."
    rsync_to "${DEBS_SRC}/" "${REMOTE}:${REMOTE_DIR}/debian/packages/arm64/" || \
        warn "Deb sync failed (non-fatal)"
fi

# Sync kernel modules source for external module build
WIFIBT_SRC="${SDK_PATH}/external/rkwifibt"
if [[ -d "${WIFIBT_SRC}" ]]; then
    info "Syncing wifi/bt external module source..."
    ${SSHPASS_BIN} rsync -avz \
        -e "ssh -o StrictHostKeyChecking=no" \
        "${WIFIBT_SRC}/" "${REMOTE}:${REMOTE_DIR}/external/rkwifibt/" 2>&1 | tail -3 || \
        warn "WiFi module sync failed (non-fatal)"
fi

info "Sync complete."

# ═══════════════════════════════════════════════════════════════════════════
# Phase 3: Setup Debian target build environment
# ═══════════════════════════════════════════════════════════════════════════
step "Phase 3/6: Setting up build environment on target"

ssh_cmd bash -s "${REMOTE_DIR}" << 'SETUP_REMOTE'
set -euo pipefail
BUILD_DIR="$1"
cd "${BUILD_DIR}"

echo "=== Target Environment ==="
echo "Hostname: $(hostname)"
echo "Arch:     $(uname -m)"
echo "Kernel:   $(uname -r)"
echo "Disk:     $(df -h / | tail -1 | awk '{print $4" free of "$2}')"

# Check ubuntu-image
if /snap/bin/ubuntu-image version &>/dev/null 2>&1; then
    echo "ubuntu-image: $(/snap/bin/ubuntu-image version 2>/dev/null || echo OK)"
else
    echo "Installing build dependencies..."
    sudo bash scripts/setup-target.sh
fi

# Fix /tmp noexec (LP:#2075546)
if findmnt /tmp 2>/dev/null | grep -q noexec; then
    echo "Fixing /tmp noexec..."
    sudo mount -o remount,exec /tmp || true
fi

# Ensure git identity for germinate seed merge
git config --global user.email "builder@ubuntu.local" 2>/dev/null || true
git config --global user.name "Ubuntu Image Builder" 2>/dev/null || true

echo "Target setup complete."
SETUP_REMOTE

# ═══════════════════════════════════════════════════════════════════════════
# Phase 4: Native build on Debian target
# ═══════════════════════════════════════════════════════════════════════════
step "Phase 4/6: Building Ubuntu rootfs on target (native arm64)"

BUILD_START=$(date +%s)

ssh_cmd bash -s "${REMOTE_DIR}" "${VARIANT}" "${SERIES}" "${BOARD}" << 'BUILD_REMOTE'
set -euo pipefail
BUILD_DIR="$1"
VARIANT="$2"
SERIES="$3"
BOARD="$4"

cd "${BUILD_DIR}"

# Fix /tmp exec (may have been remounted by systemd)
findmnt /tmp 2>/dev/null | grep -q noexec && sudo mount -o remount,exec /tmp || true

echo ""
echo "============================================"
echo " Native arm64 Ubuntu Rootfs Build"
echo "  Variant: ${VARIANT}"
echo "  Series:  ${SERIES}"
echo "  Board:   ${BOARD}"
echo "  Started: $(date)"
echo "============================================"
echo ""

# Run build.sh with rootfs-only target
export BOARD="${BOARD}"
export SDK_PATH="${BUILD_DIR}"
export PROJECT_DIR="${BUILD_DIR}"
export UBUNTU_VARIANT="${VARIANT}"
export UBUNTU_SERIES="${SERIES}"
export SKIP_SDK_CHECKS=1
export BUILD_MODE=local
export PACKAGE_METHOD=mkupdate

bash build.sh rootfs-only

echo ""
echo "=== Build Complete ==="
ls -lh "${BUILD_DIR}/artifacts/rootfs.tar.gz" || {
    echo "ERROR: rootfs.tar.gz not found!"
    echo "Last 50 lines of build log:"
    tail -50 "${BUILD_DIR}/artifacts/ubuntu-image.log" 2>/dev/null || true
    exit 1
}
echo "=== Done at $(date) ==="
BUILD_REMOTE

BUILD_END=$(date +%s)
BUILD_DURATION=$(( (BUILD_END - BUILD_START) / 60 ))
info "Native rootfs build completed in ${BUILD_DURATION} min."

# ═══════════════════════════════════════════════════════════════════════════
# Phase 5: Pull rootfs from target
# ═══════════════════════════════════════════════════════════════════════════
step "Phase 5/6: Pulling rootfs.tar.gz from target"

ARTIFACTS_DIR="${SCRIPT_DIR}/artifacts"
mkdir -p "${ARTIFACTS_DIR}"

info "Pulling rootfs.tar.gz..."
scp_from "${REMOTE_DIR}/artifacts/rootfs.tar.gz" "${ARTIFACTS_DIR}/rootfs.tar.gz"
scp_from "${REMOTE_DIR}/artifacts/ubuntu-image.log" "${ARTIFACTS_DIR}/ubuntu-image.log" 2>/dev/null || true

info "Rootfs size: $(du -h "${ARTIFACTS_DIR}/rootfs.tar.gz" | cut -f1)"

# ═══════════════════════════════════════════════════════════════════════════
# Phase 6: Package update.img locally (Rockchip x86 tools)
# ═══════════════════════════════════════════════════════════════════════════
step "Phase 6/6: Packaging update.img (Rockchip x86 tools)"

PROJECT_DIR="${SCRIPT_DIR}"  # ubuntu/
export BOARD SDK_PATH PROJECT_DIR
export UBUNTU_VARIANT="${VARIANT}"
export UBUNTU_SERIES="${SERIES}"

# Build external kernel modules if source available
if [[ -f "${SCRIPT_DIR}/ubuntu-build-service/build-external-modules.sh" ]]; then
    info "Building external kernel modules..."
    BOARD="${BOARD}" SDK_PATH="${SDK_PATH}" \
        bash "${SCRIPT_DIR}/ubuntu-build-service/build-external-modules.sh" 2>&1 | tail -5 || \
        warn "External module build failed (non-fatal)"
fi

# Package with Rockchip tools
info "Running pack-updateimg.sh..."
BOARD="${BOARD}" SDK_PATH="${SDK_PATH}" \
    bash "${SCRIPT_DIR}/ubuntu-build-service/pack-updateimg.sh"

# Fix permissions
for item in "${ARTIFACTS_DIR}"/*; do
    [[ -e "${item}" ]] || continue
    case "$(basename "${item}")" in
        work|pack) ;;
        *)
            [[ "$(stat -c %U "${item}" 2>/dev/null)" = "root" ]] && \
                sudo chown -R "$(whoami):$(whoami)" "${item}" 2>/dev/null || true
            ;;
    esac
done

TOTAL_DURATION=$(( (BUILD_END - BUILD_START + 1) / 60 ))

echo ""
echo "============================================================"
info "Deploy complete! (total: ~${TOTAL_DURATION} min)"
info ""
info "  rootfs.tar.gz: ${ARTIFACTS_DIR}/rootfs.tar.gz"
if [[ -f "${ARTIFACTS_DIR}/update.img" ]]; then
    UPDATE_SIZE=$(du -h "${ARTIFACTS_DIR}/update.img" | cut -f1)
    info "  update.img:    ${ARTIFACTS_DIR}/update.img (${UPDATE_SIZE})"
fi
info "  build log:     ${ARTIFACTS_DIR}/ubuntu-image.log"
echo ""
info "Flash to target:"
info "  sudo upgrade_tool uf ${ARTIFACTS_DIR}/update.img"
echo "============================================================"
