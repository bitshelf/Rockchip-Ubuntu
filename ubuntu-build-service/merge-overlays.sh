#!/bin/bash
# ==========================================================================
# merge-overlays.sh — Source this to get merge_overlays() function
#
# Usage: merge_overlays <target_root>
#
# Reads OVERLAYS[] from board config (sourced before calling).
# Each entry:  BASE_DIR|LOCAL_DIR
# - BASE: SDK overlay (debian/overlay, debian/overlay-debug, ...)
# - LOCAL: ubuntu/overlay/overlay, ubuntu/overlay/overlay-debug, ...
# Merge: copy BASE first, then LOCAL on top (local overrides base)
# ==========================================================================

merge_overlays() {
    local target="$1"

    if [[ ! -d "${target}" ]]; then
        echo "  ERROR: target directory not found: ${target}"
        return 1
    fi

    if [[ -z "${OVERLAYS+x}" ]] || [[ ${#OVERLAYS[@]} -eq 0 ]]; then
        echo "  No overlays configured, skipping."
        return 0
    fi

    echo "==> Merging overlays (base → local override)..."

    for entry in "${OVERLAYS[@]}"; do
        local base="${entry%%|*}"
        local local_dir="${entry##*|}"

        # Step 1: Copy base overlay
        if [[ -d "${base}" ]]; then
            echo "  base: ${base}"
            # Copy each top-level dir in base (etc/, usr/, home/, ...)
            for item in "${base}"/*; do
                if [[ -e "${item}" ]]; then
                    sudo cp -r "${item}" "${target}/"
                fi
            done
        else
            echo "  base: ${base} (not found, skipping)"
        fi

        # Step 2: Copy local overlay on top (overrides base)
        if [[ -d "${local_dir}" ]]; then
            echo "  local: ${local_dir} (override)"
            for item in "${local_dir}"/*; do
                if [[ -e "${item}" ]]; then
                    sudo cp -r "${item}" "${target}/"
                fi
            done
        else
            echo "  local: ${local_dir} (not found, skipping)"
        fi
    done

    echo "  Overlays merged."
}
