#!/bin/bash
set -euo pipefail

# ==========================================================================
# build-external-modules.sh — Build Rockchip external kernel modules
#
# Compiles out-of-tree kernel modules (bcmdhd wifi, etc.) from
# external/rkwifibt against the SDK kernel tree, then copies them
# into the overlay-firmware directory for inclusion in rootfs.
#
# The overlay merge mechanism in assemble-disk.sh / pack-updateimg.sh
# will pick them up automatically.
# ==========================================================================

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
export SDK_PATH="${SDK_PATH:-$(dirname "${PROJECT_DIR}")}"

BOARD="${BOARD:-rk3576}"
BOARD_CONF="${PROJECT_DIR}/boards/${BOARD}/${BOARD}.conf"
if [[ -f "${BOARD_CONF}" ]]; then
    source "${BOARD_CONF}"
fi

# Paths
RKWIFIBT_DIR="${SDK_PATH}/external/rkwifibt"
KERNEL_DIR="${SDK_PATH}/${KERNEL_SOURCE_DIR:-kernel-6.1}"
OVERLAY_FW="${PROJECT_DIR}/overlay/overlay-firmware"
MODULES_DEST="${OVERLAY_FW}/usr/lib/modules"

# Determine which WiFi modules to build
# Default: bcmdhd for both SDIO and PCIe (AP6275P on MYD-LR3576)
WIFIBT_MODULES="${WIFIBT_MODULES:-bcmdhd_pcie}"

# ==========================================================================
# Main
# ==========================================================================
echo "==> Building external kernel modules..."
echo "  Kernel:  ${KERNEL_DIR}"
echo "  Source:  ${RKWIFIBT_DIR}"
echo "  Modules: ${WIFIBT_MODULES}"
echo "  Dest:    ${MODULES_DEST}"

# Check prerequisites
if [[ ! -d "${KERNEL_DIR}" ]]; then
    echo "ERROR: Kernel source not found: ${KERNEL_DIR}"
    exit 1
fi
if [[ ! -f "${KERNEL_DIR}/include/generated/asm-offsets.h" ]]; then
    echo "ERROR: Kernel not configured/built. Run './build.sh kernel' first."
    exit 1
fi

# Kernel make command
KMAKE="make -C ${KERNEL_DIR} ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-"

# Ensure target dir exists
mkdir -p "${MODULES_DEST}"

# -------------------------------------------------------------------
# Step 0: Copy in-tree kernel modules from KERNEL_MODULES_LIST
#         and kernel assets (vdso.so, etc.)
# -------------------------------------------------------------------
copy_in_tree_assets() {
    echo "==> Copying in-tree kernel assets..."

    # --- .ko modules from KERNEL_MODULES_LIST ---
    if [[ -n "${KERNEL_MODULES_LIST+x}" ]] && [[ ${#KERNEL_MODULES_LIST[@]} -gt 0 ]]; then
        echo "  KERNEL_MODULES_LIST has ${#KERNEL_MODULES_LIST[@]} entries"
        for ko_rel in "${KERNEL_MODULES_LIST[@]}"; do
            # Skip empty or comment-only entries
            [[ -z "${ko_rel}" || "${ko_rel}" =~ ^# ]] && continue

            local ko_src="${KERNEL_DIR}/${ko_rel}"
            if [[ -f "${ko_src}" ]]; then
                echo "  copy: ${ko_rel}"
                cp -v "${ko_src}" "${MODULES_DEST}/" 2>/dev/null
            else
                echo "  WARNING: ${ko_src} not found, skipping"
            fi
        done
    else
        echo "  KERNEL_MODULES_LIST is empty, skipping .ko copy"
    fi

    # --- vdso.so (debug symbols for perf/gdb — kernel auto-maps vDSO at boot) ---
    # Note: syscall acceleration is handled by the kernel's built-in vDSO page,
    #       which is embedded in the kernel Image and mapped per-process automatically.
    #       This file is a debug symbol companion for profiling/analysis tools.
    local vdso_src="${KERNEL_DIR}/arch/arm64/kernel/vdso/vdso.so"
    if [[ -f "${vdso_src}" ]]; then
        local vdso_dest="${OVERLAY_FW}/usr/lib/modules/${KERNEL_VERSION:-6.1.118}/vdso"
        mkdir -p "${vdso_dest}"
        cp -v "${vdso_src}" "${vdso_dest}/"
        echo "  vdso.so installed to ${vdso_dest} (debug symbols for perf/gdb)"
    else
        echo "  WARNING: vdso.so not found, skipping"
    fi

    echo "  In-tree assets copy done."
}
copy_in_tree_assets

# -------------------------------------------------------------------
# Step 1: Build bcmdhd (Broadcom WiFi SDIO + PCIe)
# -------------------------------------------------------------------
if [[ "${WIFIBT_MODULES}" =~ bcmdhd ]]; then
    # PCIe version (AP6275P / AP6xxx PCIe cards)
    if [[ "${WIFIBT_MODULES}" =~ pcie ]] || [[ "${WIFIBT_MODULES}" =~ PCIE ]]; then
        echo "==> Building bcmdhd (PCIe)..."
        ${KMAKE} M="${RKWIFIBT_DIR}/drivers/bcmdhd" \
            CONFIG_BCMDHD=m CONFIG_BCMDHD_PCIE=y CONFIG_BCMDHD_SDIO=
    fi

    # SDIO version (AP6xxx SDIO cards)
    if [[ "${WIFIBT_MODULES}" =~ sdio ]] || [[ "${WIFIBT_MODULES}" =~ SDIO ]]; then
        echo "==> Building bcmdhd (SDIO)..."
        ${KMAKE} M="${RKWIFIBT_DIR}/drivers/bcmdhd" \
            CONFIG_BCMDHD=m CONFIG_BCMDHD_SDIO=y CONFIG_BCMDHD_PCIE=
    fi

    # Copy .ko files
    if ls "${RKWIFIBT_DIR}/drivers/bcmdhd/"*.ko 1>/dev/null 2>&1; then
        echo "==> Installing bcmdhd modules..."
        cp -v "${RKWIFIBT_DIR}/drivers/bcmdhd/"*.ko "${MODULES_DEST}/"
    else
        echo "  WARNING: No bcmdhd .ko files found (check kernel config)"
    fi
fi

# -------------------------------------------------------------------
# Build Realtek WiFi drivers
# -------------------------------------------------------------------
if [[ "${WIFIBT_MODULES}" =~ realtek ]] || [[ "${WIFIBT_MODULES}" =~ all ]]; then
    for drv in rtl8189fs rtl8723ds rtl8821cs rtl8822cs rtl8852bs; do
        if [[ -d "${RKWIFIBT_DIR}/drivers/${drv}" ]]; then
            echo "==> Building ${drv}..."
            ${KMAKE} M="${RKWIFIBT_DIR}/drivers/${drv}" modules || true
        fi
    done
    echo "==> Installing Realtek modules..."
    cp -v "${RKWIFIBT_DIR}/drivers/rtl"*/*.ko "${MODULES_DEST}/" 2>/dev/null || true
fi

# -------------------------------------------------------------------
# Build Infineon/Cypress WiFi drivers
# -------------------------------------------------------------------
if [[ "${WIFIBT_MODULES}" =~ cyw ]] || [[ "${WIFIBT_MODULES}" =~ all ]]; then
    for chip in CYW4354 CYW4373 CYW43438 CYW43455 CYW5557X CYW54591; do
        echo "==> Building ${chip}..."
        ln -sf "chips/${chip}_Makefile" "${RKWIFIBT_DIR}/drivers/infineon/Makefile"
        ${KMAKE} M="${RKWIFIBT_DIR}/drivers/infineon" || true
    done
    echo "==> Installing Infineon modules..."
    cp -v "${RKWIFIBT_DIR}/drivers/infineon/"*.ko "${MODULES_DEST}/" 2>/dev/null || true
fi

# -------------------------------------------------------------------
# Step 2: Compile DTS overlays → .dtbo for /boot/overlays/
# -------------------------------------------------------------------
DTS_OVERLAY_DIR="${PROJECT_DIR}/artifacts/boot-assets/overlays"
if ls "${DTS_OVERLAY_DIR}/"*.dts 1>/dev/null 2>&1; then
    echo "==> Compiling DTS overlays..."
    DTC="${KERNEL_DIR}/scripts/dtc/dtc"
    [[ -x "${DTC}" ]] || DTC="$(which dtc 2>/dev/null)" || DTC=""
    if [[ -z "${DTC}" ]]; then
        echo "  WARNING: dtc not found, skipping overlay compile"
    else
        for dts in "${DTS_OVERLAY_DIR}/"*.dts; do
            local name=$(basename "${dts}" .dts)
            echo "  compiling: ${name}.dts → ${name}.dtbo"
            ${DTC} -@ -I dts -O dtb -o "${DTS_OVERLAY_DIR}/${name}.dtbo" "${dts}" 2>/dev/null || \
                echo "  WARNING: ${name} compile failed"
        done
    fi
else
    echo "==> DTS overlays: none found (add .dts files to boot-assets/overlays/)"
fi

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------
echo ""
echo "============================================="
echo "  Kernel assets build complete"
echo "  Modules destination: ${MODULES_DEST}"
echo "============================================="
if ls "${MODULES_DEST}/"*.ko 1>/dev/null 2>&1; then
    echo "  .ko modules:"
    ls -la "${MODULES_DEST}/"*.ko 2>/dev/null
fi
if [[ -d "${MODULES_DEST}/vdso" ]]; then
    echo "  vdso:"
    ls -la "${MODULES_DEST}/vdso/" 2>/dev/null
fi
if ls "${DTS_OVERLAY_DIR}/"*.dtbo 1>/dev/null 2>&1; then
    echo "  DTS overlays:"
    ls -la "${DTS_OVERLAY_DIR}/"*.dtbo 2>/dev/null
fi
