#!/bin/bash
# ==========================================================================
# ci-setup.sh — Install build dependencies for GitHub Actions runner
#
# Installs: ubuntu-image (snap), debootstrap, qemu-user-static, gdisk,
#           e2fsprogs, and other tools needed for Ubuntu rootfs cross-build.
#
# Apt caching: set APT_CACHE_DIR to a persistent directory to cache
# downloaded .deb files across runs. Works with actions/cache or manually:
#   APT_CACHE_DIR=/path/to/cache bash ci-setup.sh cross
#
# Usage:  bash .github/scripts/ci-setup.sh [cross|native|remote]
#   cross  — QEMU cross-build on x86 runner (default)
#   native — native build on ARM64 runner
#   remote — minimal deps for remote-deploy workflow (just ssh/rsync)
# ==========================================================================
set -euo pipefail

MODE="${1:-cross}"
APT_CACHE_DIR="${APT_CACHE_DIR:-/tmp/apt-cache}"
APT_ARCHIVES="/var/cache/apt/archives"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
info()  { echo -e "${GREEN}[CI-SETUP]${NC} $*"; }
warn()  { echo -e "${YELLOW}[CI-SETUP]${NC} $*"; }

TIMER_START=$(date +%s)

info "Setting up CI build environment (mode: ${MODE})"
info "OS: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"')"
info "Arch: $(uname -m)"

# ─── Apt cache: restore previously downloaded .deb files ─────────────────────
restore_apt_cache() {
    if [[ -d "${APT_CACHE_DIR}" ]] && ls "${APT_CACHE_DIR}"/*.deb &>/dev/null 2>&1; then
        local count
        count=$(ls "${APT_CACHE_DIR}"/*.deb 2>/dev/null | wc -l)
        info "Restoring ${count} cached .deb(s) from ${APT_CACHE_DIR}"
        sudo mkdir -p "${APT_ARCHIVES}"
        sudo cp -n "${APT_CACHE_DIR}"/*.deb "${APT_ARCHIVES}/" 2>/dev/null || true
    else
        info "No apt cache found at ${APT_CACHE_DIR} (first run?)"
    fi
}

# ─── Apt cache: save newly downloaded .deb files ─────────────────────────────
save_apt_cache() {
    if [[ -n "${APT_CACHE_DIR:-}" ]]; then
        mkdir -p "${APT_CACHE_DIR}"
        local count
        count=$(ls "${APT_ARCHIVES}"/*.deb 2>/dev/null | wc -l || true)
        cp -n "${APT_ARCHIVES}"/*.deb "${APT_CACHE_DIR}/" 2>/dev/null || true
        local cached
        cached=$(ls "${APT_CACHE_DIR}"/*.deb 2>/dev/null | wc -l)
        info "Apt cache saved: ${cached} .deb(s) in ${APT_CACHE_DIR}"
    fi
}

# ─── Apt wrapper: keep downloaded packages, don't auto-delete them ───────────
apt_install() {
    sudo apt-get install -y -qq \
        -o APT::Keep-Downloaded-Packages="true" \
        -o APT::Get::Download-Only="false" \
        "$@"
}

# ─── Restore cache before doing anything ─────────────────────────────────────
restore_apt_cache

# Ensure apt lists are up to date
info "Updating apt package lists..."
sudo apt-get update -qq -y

# ══════════════════════════════════════════════════════════════════════════════
# Common dependencies (all modes)
# ══════════════════════════════════════════════════════════════════════════════
info "Installing common dependencies..."
apt_install \
    git rsync curl wget ca-certificates gnupg \
    gdisk e2fsprogs xz-utils dosfstools \
    u-boot-tools device-tree-compiler

# ══════════════════════════════════════════════════════════════════════════════
# Mode-specific dependencies
# ══════════════════════════════════════════════════════════════════════════════
case "${MODE}" in
    cross)
        info "=== Cross-build mode: QEMU user static + ubuntu-image ==="

        info "Installing QEMU user static..."
        apt_install qemu-user-static binfmt-support

        # Verify binfmt registration
        if ! ls /proc/sys/fs/binfmt_misc/qemu-aarch64 &>/dev/null; then
            info "Registering QEMU binfmt..."
            sudo update-binfmts --enable qemu-aarch64 2>/dev/null || \
                sudo systemctl restart systemd-binfmt 2>/dev/null || true
        fi
        info "QEMU binfmt: $(ls /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null && echo OK || echo MISSING)"

        info "Installing ubuntu-image build dependencies..."
        apt_install debootstrap distro-info germinate \
            python3 python3-apt fakeroot build-essential

        # Install snapd (for ubuntu-image classic snap)
        info "Installing snapd..."
        apt_install snapd

        sudo systemctl enable snapd.socket 2>/dev/null || true
        sudo systemctl start snapd.socket 2>/dev/null || true

        # Wait for snapd
        info "Waiting for snapd..."
        for i in $(seq 1 15); do
            if snap version &>/dev/null 2>&1; then
                info "snapd ready: $(snap version 2>/dev/null | head -1)"
                break
            fi
            sleep 2
        done

        # Install ubuntu-image snap (~200MB, not cached via apt)
        info "Installing ubuntu-image (snap)..."
        if /snap/bin/ubuntu-image version &>/dev/null 2>&1; then
            info "ubuntu-image already installed from cache."
        else
            info "Downloading ubuntu-image snap (this takes a few minutes)..."
            sudo snap install ubuntu-image --classic
            info "ubuntu-image: $(/snap/bin/ubuntu-image version 2>/dev/null || echo OK)"
        fi
        ;;

    native)
        info "=== Native ARM64 build mode ==="

        apt_install snapd debootstrap distro-info germinate

        sudo systemctl enable snapd.socket 2>/dev/null || true
        sudo systemctl start snapd.socket 2>/dev/null || true
        sleep 2

        if ! /snap/bin/ubuntu-image version &>/dev/null 2>&1; then
            sudo snap install ubuntu-image --classic
        fi
        info "ubuntu-image: $(/snap/bin/ubuntu-image version 2>/dev/null || echo OK)"
        ;;

    remote)
        info "=== Remote deploy mode ==="
        info "Installing host-side tools (sshpass, rsync)..."
        apt_install sshpass rsync
        info "Remote deploy tools installed."
        ;;
esac

# ══════════════════════════════════════════════════════════════════════════════
# Verify critical tools
# ══════════════════════════════════════════════════════════════════════════════
info "Verifying tools..."

check_tool() {
    local name="$1"
    local cmd="${2:-${name}}"
    if command -v "${cmd}" &>/dev/null; then
        info "  [OK] ${name}"
    else
        warn "  [MISSING] ${name}"
    fi
}

check_tool "git"
check_tool "rsync"
check_tool "sgdisk" "sgdisk"
check_tool "mkfs.ext4"
check_tool "mkfs.vfat"
check_tool "dtc" "dtc"

if [[ "${MODE}" == "cross" || "${MODE}" == "native" ]]; then
    check_tool "debootstrap"
    check_tool "ubuntu-image" "/snap/bin/ubuntu-image"
    check_tool "snap"

    if /snap/bin/ubuntu-image version &>/dev/null 2>&1; then
        info "ubuntu-image self-test: PASS"
    else
        warn "ubuntu-image self-test: FAIL — build may fail"
    fi
fi

if [[ "${MODE}" == "cross" ]]; then
    if /usr/bin/qemu-aarch64-static --version &>/dev/null 2>&1; then
        info "qemu-aarch64-static: OK"
    else
        warn "qemu-aarch64-static not working"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# Save apt cache for next run
# ══════════════════════════════════════════════════════════════════════════════
save_apt_cache

TIMER_END=$(date +%s)
DURATION=$(( TIMER_END - TIMER_START ))

echo ""
info "CI setup complete (${DURATION}s)"
