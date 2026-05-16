#!/bin/bash
set -euo pipefail

# ==========================================================================
# build-remote.sh — Remote arm64 native build orchestrator
#
# Syncs source to target board, builds rootfs natively (no qemu),
# pulls rootfs back, then packages update.img locally.
#
# Config: boards/remote.env or env vars:
#   BUILD_HOST  — target board IP for native build
#   BUILD_USER  — ssh user (default: root)
#   BUILD_DIR   — working dir on remote (default: /tmp/ubuntu-build)
# ==========================================================================

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
SDK_PATH="${SDK_PATH:-$(dirname "${PROJECT_DIR}")}"

# Load config from .env
if [[ -f "${PROJECT_DIR}/.env" ]]; then
    source "${PROJECT_DIR}/.env"
else
    warn ".env not found — using defaults (copy .env.example to .env)"
fi

HOST="${BUILD_HOST:?Set BUILD_HOST in boards/remote.env or env}"
USER="${BUILD_USER:-root}"
REMOTE_DIR="${BUILD_DIR:-/tmp/ubuntu-build}"
ARTIFACTS_DIR="${PROJECT_DIR}/artifacts"
BOARD="${BOARD:-rk3576}"
VARIANT="${UBUNTU_VARIANT:-desktop}"
SERIES="${UBUNTU_SERIES:-noble}"

REMOTE="${USER}@${HOST}"
PASS="${BUILD_PASS:-}"

# SSH wrapper: use sshpass if password is set, else plain ssh
ssh_cmd() {
    if [[ -n "${PASS}" ]] && command -v sshpass &>/dev/null; then
        sshpass -p "${PASS}" ssh -o StrictHostKeyChecking=no "$@"
    else
        ssh -o StrictHostKeyChecking=no "$@"
    fi
}
scp_cmd() {
    if [[ -n "${PASS}" ]] && command -v sshpass &>/dev/null; then
        sshpass -p "${PASS}" scp -o StrictHostKeyChecking=no "$@"
    else
        scp -o StrictHostKeyChecking=no "$@"
    fi
}

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
info()  { echo -e "${GREEN}[REMOTE]${NC} $*"; }
warn()  { echo -e "${YELLOW}[REMOTE]${NC} $*"; }
error() { echo -e "${RED}[REMOTE]${NC} $*"; exit 1; }

# -------------------------------------------------------------------
# Step 1: Check remote connectivity
# -------------------------------------------------------------------
echo ""
echo "============================================="
echo " Remote arm64 Native Build"
echo " Target: ${REMOTE}"
echo " Variant: ${VARIANT} (${SERIES})"
echo "============================================="
echo ""

info "Step 1/5: Checking remote connectivity..."
if ! ssh_cmd -o ConnectTimeout=5 "${REMOTE}" "uname -m" 2>/dev/null; then
    error "Cannot reach ${REMOTE}. Check BUILD_HOST and ssh access."
fi

# Verify remote is actually arm64
REMOTE_ARCH=$(ssh_cmd "${REMOTE}" "uname -m")
if [[ "${REMOTE_ARCH}" != "aarch64" ]]; then
    warn "Remote is ${REMOTE_ARCH}, not aarch64. Qemu issues may occur."
fi

# -------------------------------------------------------------------
# Step 2: Install deps on remote if needed
# -------------------------------------------------------------------
info "Step 2/5: Checking remote dependencies..."
ssh_cmd "${REMOTE}" bash -s << 'CHECK_DEPS'
set -e
for cmd in ubuntu-image debootstrap; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "  Installing $cmd..."
        case "$cmd" in
            ubuntu-image) snap install ubuntu-image --classic ;;
            debootstrap)  apt-get update -qq && apt-get install -y -qq debootstrap ;;
        esac
    fi
done
echo "  Dependencies OK"
CHECK_DEPS

# -------------------------------------------------------------------
# Step 3: Sync source to remote
# -------------------------------------------------------------------
info "Step 3/5: Syncing source to ${REMOTE}:${REMOTE_DIR}..."
ssh_cmd "${REMOTE}" "mkdir -p ${REMOTE_DIR}/ubuntu"
rsync -av --delete \
    --exclude 'artifacts/' \
    --exclude '.git/' \
    --exclude '*.img' \
    --exclude '*.tar.gz' \
    --exclude '*.log' \
    "${PROJECT_DIR}/" "${REMOTE}:${REMOTE_DIR}/ubuntu/" 2>&1 | tail -3

# -------------------------------------------------------------------
# Step 4: Build rootfs on remote (native arm64)
# -------------------------------------------------------------------
info "Step 4/5: Building rootfs on remote (arm64 native, expect ~30-60 min)..."
ssh_cmd "${REMOTE}" bash -s << BUILD_ROOTFS
set -euo pipefail
cd ${REMOTE_DIR}/ubuntu
export SDK_PATH=${REMOTE_DIR}
export BOARD=${BOARD}
export UBUNTU_VARIANT=${VARIANT}
export UBUNTU_SERIES=${SERIES}
echo "Building \${UBUNTU_VARIANT} \${UBUNTU_SERIES} on \$(uname -m)..."
# Build only rootfs, skip packaging (packaging uses x86 tools)
bash ubuntu-build-service/build.sh rootfs-only 2>&1 | tail -20
echo "=== Build complete ==="
ls -lh artifacts/rootfs.tar.gz
BUILD_ROOTFS

# -------------------------------------------------------------------
# Step 5: Pull rootfs back and package locally
# -------------------------------------------------------------------
info "Step 5/5: Pulling rootfs.tar.gz and packaging update.img..."
scp_cmd "${REMOTE}:${REMOTE_DIR}/ubuntu/artifacts/rootfs.tar.gz" "${ARTIFACTS_DIR}/"

info "Packaging update.img locally..."
sudo BOARD="${BOARD}" SDK_PATH="${SDK_PATH}" \
    bash "${SCRIPT_DIR}/pack-updateimg.sh"

echo ""
echo "============================================="
info "Remote build complete!"
info "  update.img: ${ARTIFACTS_DIR}/update.img"
echo "============================================="
