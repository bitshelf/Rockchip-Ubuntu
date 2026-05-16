#!/bin/bash
set -euo pipefail

# ==========================================================================
# build.sh — Ubuntu Image Build Orchestrator (multi-board)
#
# Usage:  BOARD=rk3588-board ./build.sh
#         BOARD=rk3576 UBUNTU_SERIES=questing ./build.sh
#
# Prerequisites:
#   - ubuntu-image snap (v3.x) or built from Go source
#   - qemu-user-static + binfmt-support for arm64 cross-build
#   - sgdisk (gdisk package)
#   - SDK_PATH must be set in environment (path to Rockchip SDK root)
# ==========================================================================

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
ARTIFACTS_DIR="${PROJECT_DIR}/artifacts"

# ==========================================================================
# Artifact ownership rules:
#   work/           — NEVER touch (ubuntu-image creates with mixed owners)
#   local-apt/      — /tmp, may be root-owned from sudo
#   everything else — user-owned for safe cleanup
# ==========================================================================
fix_artifact_perms() {
    mkdir -p "${ARTIFACTS_DIR}"

    for item in "${ARTIFACTS_DIR}"/*; do
        [[ -e "${item}" ]] || continue
        case "$(basename "${item}")" in
            work) ;;  # NEVER chown — ubuntu-image creates mixed-owner files
            *)
                if [[ "$(stat -c %U "${item}")" = "root" ]]; then
                    sudo chown -R "$(whoami):$(whoami)" "${item}" 2>/dev/null || true
                fi
                ;;
        esac
    done

    # Ensure artifacts/ itself is user-writable (but work/ inside stays untouched)
    [[ "$(stat -c %U "${ARTIFACTS_DIR}")" = "root" ]] && \
        sudo chown "$(whoami):$(whoami)" "${ARTIFACTS_DIR}" 2>/dev/null || true
}

# ==========================================================================
# Host protection: never rm -rf over active bind mounts
# ==========================================================================
safe_unmount_chroot() {
    # Detach stale loop devices pointing into artifacts/ (from crashed builds)
    # No sudo needed — the script already runs as root via sudo bash
    losetup -a 2>/dev/null | { grep "${ARTIFACTS_DIR}" || true; } | \
        while read -r lo _; do
            lo="${lo%%:*}"
            losetup -d "${lo}" 2>/dev/null || true
        done
    return 0
}

# Auto-detect SDK_PATH from script location if not set in environment
# SCRIPT_DIR = ubuntu/ubuntu-build-service/, PROJECT_DIR = ubuntu/, SDK_PATH = repo root
export SDK_PATH="${SDK_PATH:-$(dirname "${PROJECT_DIR}")}"

# Board selection (default: rk3576)
export BOARD="${BOARD:-rk3576}"
BOARD_CONF="${PROJECT_DIR}/boards/${BOARD}/${BOARD}.conf"

if [[ ! -f "${BOARD_CONF}" ]]; then
    echo "ERROR: Board config not found: ${BOARD_CONF}"
    echo "Available boards:"
    ls -d "${PROJECT_DIR}/boards/"*/ 2>/dev/null | sed 's|.*/||;s|/||' | sed 's/^/  /'
    exit 1
fi
source "${BOARD_CONF}"

# Ubuntu series (default from board config)
UBUNTU_SERIES="${UBUNTU_SERIES:-${UBUNTU_SERIES_DEFAULT}}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# -------------------------------------------------------------------
# Yocto-style source resolution
# Supports: file://path | https://url | git://url
# -------------------------------------------------------------------
SRC_CACHE="${HOME}/.cache/ubuntu-image-sources"

resolve_source() {
    local uri="$1"
    local name="$2"
    local srcrev="${3:-}"

    if [[ "${uri}" =~ ^file:// ]]; then
        # Local path
        local path="${uri#file://}"
        if [[ ! -d "${path}" ]]; then
            error "Local source not found: ${path}"
        fi
        echo "${path}"
        return
    fi

    # Remote: clone to cache
    mkdir -p "${SRC_CACHE}"
    local cached="${SRC_CACHE}/${name}"

    if [[ -d "${cached}/.git" ]]; then
        info "Updating cached source: ${name}"
        (cd "${cached}" && git fetch --depth 1 origin "${srcrev}" 2>/dev/null) || true
    else
        info "Cloning source: ${uri} -> ${cached}"
        git clone --depth 1 ${srcrev:+--branch "${srcrev}"} "${uri}" "${cached}"
    fi
    echo "${cached}"
}

# -------------------------------------------------------------------
# Check prerequisites
# -------------------------------------------------------------------
check_prereqs() {
    info "Checking prerequisites..."

    command -v /snap/bin/ubuntu-image >/dev/null 2>&1 || \
        error "ubuntu-image not found. Install: sudo snap install ubuntu-image --classic"

    command -v debootstrap >/dev/null 2>&1 || \
        error "debootstrap not found. Install: sudo apt-get install debootstrap"

    command -v sgdisk >/dev/null 2>&1 || \
        error "sgdisk not found. Install: sudo apt-get install gdisk"

    command -v mkfs.ext4 >/dev/null 2>&1 || \
        error "mkfs.ext4 not found. Install: sudo apt-get install e2fsprogs"

    # Check qemu-user-static for arm64
    if ! ls /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null; then
        warn "qemu-aarch64 binfmt not registered. Installing..."
        sudo apt-get install -y qemu-user-static binfmt-support
        sudo systemctl restart systemd-binfmt
    fi

    info "All prerequisites satisfied."
}

# -------------------------------------------------------------------
# Copy boot assets from SDK
# -------------------------------------------------------------------
copy_boot_assets() {
    info "Copying boot assets..."

    # Resolve source paths (local or remote via Yocto-style URIs)
    local uboot_src
    uboot_src=$(resolve_source "${UBOOT_URI}" "uboot-${BOARD}" "${UBOOT_SRCREV}")
    local kernel_src
    kernel_src=$(resolve_source "${KERNEL_URI}" "kernel-${BOARD}" "${KERNEL_SRCREV}")
    local boot_assets="${PROJECT_DIR}/artifacts/boot-assets"
    mkdir -p "${boot_assets}/overlays"

    # idbloader (SPL + DDR init)
    if [[ -f "${uboot_src}/${IDBLOADER_SOURCE}" ]]; then
        cp -v "${uboot_src}/${IDBLOADER_SOURCE}" "${boot_assets}/idbloader.img"
    else
        warn "idbloader (${IDBLOADER_SOURCE}) not found in ${uboot_src}"
    fi

    # u-boot.itb
    if [[ -f "${uboot_src}/${UBOOT_SOURCE}" ]]; then
        cp -v "${uboot_src}/${UBOOT_SOURCE}" "${boot_assets}/u-boot.itb"
    else
        warn "u-boot (${UBOOT_SOURCE}) not found in ${uboot_src}"
    fi

    # boot.img (kernel FIT image)
    if [[ -f "${kernel_src}/boot.img" ]]; then
        cp -v "${kernel_src}/boot.img" "${boot_assets}/boot.img"
    elif [[ -f "${kernel_src}/arch/arm64/boot/Image" ]]; then
        cp -v "${kernel_src}/arch/arm64/boot/Image" "${boot_assets}/"
    else
        warn "boot.img not found in ${kernel_src}"
    fi

    # Device tree
    local dtb_path="${kernel_src}/${OVERLAY_SOURCE_DIR}/${DTB_BASE}"
    if [[ -f "${dtb_path}" ]]; then
        cp -v "${dtb_path}" "${boot_assets}/"
    else
        warn "${DTB_BASE} not found at ${dtb_path}"
    fi

    # DTS overlays
    local overlay_dir="${kernel_src}/${OVERLAY_SOURCE_DIR}"
    if ls "${overlay_dir}/"*.dtbo 1>/dev/null 2>&1; then
        cp -v "${overlay_dir}/"*.dtbo "${boot_assets}/overlays/"
    fi

    info "Boot assets copied."
}

# -------------------------------------------------------------------
# Create local apt repo from Rockchip custom .debs
# ubuntu-image picks Rockchip versions over upstream automatically
# -------------------------------------------------------------------
create_local_apt_repo() {
    local debs_src="${SDK_PATH}/debian/packages/arm64"

    if [[ ! -d "${debs_src}" ]]; then
        info "No Rockchip .debs found at ${debs_src}, skipping local repo"
        return 0
    fi

    info "Creating local apt repo from Rockchip .debs..."
    # YAMLs reference file:///tmp/ubuntu-local-apt — use symlink to user-owned temp dir
    local repo_dir
    repo_dir=$(mktemp -d /tmp/ubuntu-local-apt-XXXXXX)
    rm -f /tmp/ubuntu-local-apt 2>/dev/null || true
    ln -sf "${repo_dir}" /tmp/ubuntu-local-apt 2>/dev/null || {
        warn "Cannot create symlink /tmp/ubuntu-local-apt — using temp path"
        warn "  YAML apt source may not resolve. Run: sudo rm -rf /tmp/ubuntu-local-apt"
        repo_dir="/tmp/ubuntu-local-apt"
        mkdir -p "${repo_dir}" 2>/dev/null || true
    }
    mkdir -p "${repo_dir}/pool/main"

    # Copy all .debs into pool
    local count=0
    for deb in "${debs_src}"/*/*.deb; do
        [[ -f "${deb}" ]] || continue
        cp "${deb}" "${repo_dir}/pool/main/" || true
        count=$((count + 1))
    done
    info "  copied ${count} packages"

    # Generate apt repo index
    local suite="${UBUNTU_SERIES}"
    mkdir -p "${repo_dir}/dists/${suite}/main/binary-arm64"
    (cd "${repo_dir}" && dpkg-scanpackages --multiversion pool /dev/null \
        > "dists/${suite}/main/binary-arm64/Packages") || {
        warn "dpkg-scanpackages failed, trying apt-ftparchive..."
        (cd "${repo_dir}" && apt-ftparchive packages pool \
            > "dists/${suite}/main/binary-arm64/Packages")
    }
    gzip -kf "${repo_dir}/dists/${suite}/main/binary-arm64/Packages"

    # Create Release file
    (cd "${repo_dir}/dists/${suite}" && apt-ftparchive release . > Release) 2>/dev/null || true

    info "Local apt repo created: file://${repo_dir}"
}

# -------------------------------------------------------------------
# Run ubuntu-image
# -------------------------------------------------------------------
run_ubuntu_image() {
    info "Running ubuntu-image classic to build rootfs tarball..."

    mkdir -p "${ARTIFACTS_DIR}"

    # image-definition-{variant}-{series}.yaml
    local yaml_file="${SCRIPT_DIR}/image-definition-${UBUNTU_VARIANT:-desktop}-${UBUNTU_SERIES}.yaml"

    # Merge base seeds + local overrides into a single seed source.
    # Select local seeds dir by variant: seeds-local (server) or seeds-local-desktop
    local variant="${UBUNTU_VARIANT:-desktop}"
    local seeds_override="${SCRIPT_DIR}/seeds-local-desktop"
    if [[ "${variant}" == "server" ]]; then
        seeds_override="${SCRIPT_DIR}/seeds-local"
    fi
    local seeds_base="${SCRIPT_DIR}/seeds"
    [[ "${UBUNTU_SERIES}" == "questing" ]] && seeds_base="${SCRIPT_DIR}/seeds-questing"
    # Fixed absolute paths — YAMLs use file:///tmp/ubuntu-{seeds,debs}
    local seeds_git="/tmp/ubuntu-seeds-git"
    local seeds_repo="${seeds_git}/ubuntu"
    rm -rf "${seeds_git}"
    mkdir -p "${seeds_repo}"
    # Copy base seeds into ubuntu/ subdirectory (germinate layout)
    cp "${seeds_base}/"* "${seeds_repo}/"
    # Overlay local seed overrides
    for f in "${seeds_override}/"*; do
        [[ -f "${f}" ]] && cp "${f}" "${seeds_repo}/$(basename "${f}")"
    done
    # Init git repo inside ubuntu/ (germinate clones <seed-url>/ubuntu/)
    (cd "${seeds_repo}" && \
        git init -q && \
        git config user.email "builder@rockchip-ubuntu.local" && \
        git config user.name "Image Builder" && \
        git checkout -b "${UBUNTU_SERIES}" -q && \
        git add . && \
        git commit -q -m "merged seeds for ${UBUNTU_SERIES}")
    info "Seed source: file://${seeds_git}"

    local workdir="${ARTIFACTS_DIR}/work"

    local host_arch
    host_arch=$(dpkg --print-architecture)
    if [[ "${host_arch}" != "arm64" ]]; then
        info "Cross-arch build: host=${host_arch}, target=arm64"
    fi

    local max_retries=3
    for ((retry=1; retry<=max_retries; retry++)); do
        [[ ${retry} -gt 1 ]] && info "Retry ${retry}/${max_retries} (qemu segfaults are transient)..."

        sudo /snap/bin/ubuntu-image classic \
            --workdir "${workdir}" \
            "${yaml_file}" -O "${ARTIFACTS_DIR}" --debug \
            2>&1 | tee "${ARTIFACTS_DIR}/ubuntu-image.log"

        if [[ -f "${ARTIFACTS_DIR}/rootfs.tar.gz" ]]; then
            info "Rootfs tarball created: ${ARTIFACTS_DIR}/rootfs.tar.gz"
            return 0
        fi
    done

    error "ubuntu-image rootfs tarball not found after ${max_retries} attempts! Check ${ARTIFACTS_DIR}/ubuntu-image.log"
}

# -------------------------------------------------------------------
# Verify image
# -------------------------------------------------------------------
verify_image() {
    info "Verifying image..."

    local img="${ARTIFACTS_DIR}/${IMAGE_NAME_PREFIX}-arm64.img"

    # Partition table
    info "Partition layout:"
    sgdisk -p "${img}"

    # Bootloader check
    echo ""
    info "Bootloader at LBA 64:"
    dd if="${img}" bs=512 skip=64 count=4 2>/dev/null | hexdump -C | head -4

    echo ""
    info "Bootloader at LBA 16384:"
    dd if="${img}" bs=512 skip=16384 count=4 2>/dev/null | hexdump -C | head -4

    # Mount and check OS (p2 = rootfs, p3 = overlay)
    echo ""
    info "Verifying rootfs contents..."
    local loopdev="" mnt="" overlay_mnt=""
    verify_cleanup() {
        sudo umount "${overlay_mnt}" 2>/dev/null || true
        sudo umount "${mnt}" 2>/dev/null || true
        [[ -n "${loopdev}" ]] && sudo losetup -d "${loopdev}" 2>/dev/null || true
        rmdir "${mnt}" "${overlay_mnt}" 2>/dev/null || true
    }
    trap verify_cleanup EXIT INT TERM
    loopdev=$(sudo losetup --show -fP "${img}")
    mnt=$(mktemp -d)
    sudo mount "${loopdev}p2" "${mnt}"

    # Check overlay partition
    overlay_mnt=$(mktemp -d)
    sudo mount "${loopdev}p3" "${overlay_mnt}"
    if [[ -d "${overlay_mnt}/upper" && -d "${overlay_mnt}/work" ]]; then
        info "  Overlay partition with upper/ and work/ dirs (OK)"
    fi
    sudo umount "${overlay_mnt}" 2>/dev/null || true
    rmdir "${overlay_mnt}"

    if [[ -f "${mnt}/etc/os-release" ]]; then
        info "OS release:"
        grep PRETTY_NAME "${mnt}/etc/os-release" || true
    fi

    # Package check: load from package-check.conf, use dpkg --root (no chroot needed)
    local pkg_check="${PROJECT_DIR}/boards/package-check.conf"
    if [[ -f "${pkg_check}" ]]; then
        source "${pkg_check}"

        info "Checking for unwanted packages..."
        for pkg in "${UNWANTED_PACKAGES[@]}"; do
            if [[ -d "${mnt}/usr/share/doc/${pkg}" ]] || grep -q "^Package: ${pkg}$" "${mnt}/var/lib/dpkg/status" 2>/dev/null; then
                warn "  Unwanted: ${pkg}"
            fi
        done

        info "Checking for background services..."
        for pkg in "${UNWANTED_SERVICES[@]}"; do
            if [[ -d "${mnt}/usr/share/doc/${pkg}" ]]; then
                warn "  Background service: ${pkg}"
            fi
        done

        info "Checking required packages..."
        for pkg in "${REQUIRED_PACKAGES[@]}"; do
            if ! [[ -d "${mnt}/usr/share/doc/${pkg}" ]]; then
                warn "  Missing: ${pkg}"
            fi
        done
    fi

    # Check boot assets
    info "Boot assets:"
    ls -lh "${mnt}/boot/" 2>/dev/null || warn "  /boot empty"

    # Check DTS overlays
    if ls "${mnt}/boot/overlays/"*.dtbo 2>/dev/null; then
        info "  DTS overlays present (OK)"
    fi

    # Check overlay initramfs hook
    info "Checking overlay initramfs hook..."
    if [[ -x "${mnt}/etc/initramfs-tools/scripts/init-bottom/overlay" ]]; then
        info "  initramfs overlay hook installed (OK)"
    else
        warn "  initramfs overlay hook missing!"
    fi

    sudo umount "${mnt}"
    sudo losetup -d "${loopdev}"
    rmdir "${mnt}"

    # Generate SHA256
    info "Generating SHA256SUMS..."
    (cd "${ARTIFACTS_DIR}" && sha256sum "${img##*/}" > SHA256SUMS)

    # Compress
    info "Compressing image..."
    xz -3 -f -T0 "${img}"
    info "Compressed: ${img}.xz"
}

# -------------------------------------------------------------------
# Main
# -------------------------------------------------------------------
main() {
    # CLI args: build.sh [variant] [mode]
    #   bash ubuntu/build.sh              → read from .env
    #   bash ubuntu/build.sh server local → override
    local cli_variant="${1:-}"
    local cli_mode="${2:-}"

    # Load .env (values use ${VAR:-default} guards, CLI or env var takes priority)
    local env_file="${PROJECT_DIR}/.env"
    [[ -f "${env_file}" ]] && source "${env_file}"

    # CLI arguments override .env
    [[ -n "${cli_variant}" ]] && UBUNTU_VARIANT="${cli_variant}"
    [[ -n "${cli_mode}" ]] && BUILD_MODE="${cli_mode}"

    echo ""
    echo "============================================="
    echo " RK3576 Ubuntu 24.04 Image Builder"
    echo "  Variant: ${UBUNTU_VARIANT:-desktop}"
    echo "  Mode:    ${BUILD_MODE:-local}"
    echo "============================================="
    echo ""

    # Remote build: .env BUILD_MODE=remote delegates to arm64 native target
    if [[ "${BUILD_MODE:-local}" == "remote" && -n "${BUILD_HOST:-}" ]]; then
        info "Build mode: remote (${BUILD_HOST})"
        bash "${SCRIPT_DIR}/build-remote.sh"
        return 0
    fi

    info "Build mode: local (qemu)"

    # Ensure artifacts/ is writable, work/ is root, output files user-owned
    fix_artifact_perms

    # If work/ was corrupted (e.g. by chown -R), delete it so ubuntu-image can start fresh
    local workdir="${ARTIFACTS_DIR}/work"
    if [[ -d "${workdir}" && "$(stat -c %U "${workdir}")" != "root" ]]; then
        warn "work/ corrupted (not root-owned), rebuilding from scratch..."
        sudo rm -rf "${workdir}"
    fi

    # Safety: clean up leftover bind mounts from previous failed builds
    safe_unmount_chroot

    check_prereqs
    copy_boot_assets
    create_local_apt_repo
    run_ubuntu_image

    # rootfs-only mode: stop after ubuntu-image (for remote build step)
    if [[ "${1:-}" == "rootfs-only" ]]; then
        info "Rootfs tarball ready: ${ARTIFACTS_DIR}/rootfs.tar.gz"
        return 0
    fi

    # Build external kernel modules (bcmdhd wifi etc.) from latest source
    info "Building external kernel modules..."
    sudo BOARD="${BOARD}" SDK_PATH="${SDK_PATH}" \
        bash "${SCRIPT_DIR}/build-external-modules.sh"

    # Package based on configured method (from board config)
    if [[ "${PACKAGE_METHOD:-mkupdate}" == "mkupdate" ]]; then
        info "Packaging update.img (Rockchip mkupdate flow)..."
        sudo BOARD="${BOARD}" SDK_PATH="${SDK_PATH}" bash "${SCRIPT_DIR}/pack-updateimg.sh"
        fix_artifact_perms

        echo ""
        info "Build complete!"
        info "Image: ${ARTIFACTS_DIR}/update.img"
    else
        info "Assembling GPT disk image..."
        sudo BOARD="${BOARD}" SDK_PATH="${SDK_PATH}" bash "${SCRIPT_DIR}/assemble-disk.sh"

        verify_image
        fix_artifact_perms

        echo ""
        info "Build complete!"
        info "Image: ${ARTIFACTS_DIR}/ubuntu-server-rk3576-arm64.img"
    fi
}

main "$@"
