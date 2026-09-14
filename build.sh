#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
usage: ./build.sh server [--check]

  server          build the Ubuntu 26 Server ARM64 rootfs
  server --check  validate configuration and host prerequisites only
  desktop         build the Ubuntu 26 GNOME ARM64 rootfs
  desktop --check validate GNOME configuration and host prerequisites only
  bootfs          build an independent ext4 boot filesystem
  bootfs --check  validate an existing bootfs image without mounting it
  overlay-root          build EROFS lower, userdata and OverlayFS initramfs
  overlay-root --check  validate the three existing filesystem artifacts
  update-engine-source  stage updateEngine source from the SDK Git checkout
  update-engine         build the ARM64 rockchip-update-engine Debian package
  update-engine --check validate staged updateEngine source and build paths
  rockchip-test         build the Rockchip test payload as a Debian package
  rockchip-test --check validate the external test payload and package paths
  edit-package-file     edit the Rockchip SDK factory package-file
  edit-ota-package-file edit the Rockchip SDK OTA package-file
  updateimg             run the Rockchip SDK factory image packer
  ota-updateimg         run the Rockchip SDK OTA image packer
EOF
}

run_rockchip_command() {
    local command="$1"
    if [[ -f "${PROJECT_DIR}/.env" ]]; then
        set -a
        # shellcheck disable=SC1091
        source "${PROJECT_DIR}/.env"
        set +a
    fi
    SDK_DIR="${SDK_DIR:-$(cd "${PROJECT_DIR}/.." && pwd)}"
    [[ -x "${SDK_DIR}/build.sh" ]] || {
        echo "ERROR: SDK build script is unavailable: ${SDK_DIR}/build.sh" >&2
        exit 1
    }
    exec "${SDK_DIR}/build.sh" "$command"
}

case "${1:-}" in
    server)
        shift
        exec "${PROJECT_DIR}/scripts/build-server.sh" "$@"
        ;;
    desktop)
        shift
        exec "${PROJECT_DIR}/scripts/build-server.sh" --variant desktop "$@"
        ;;
    bootfs)
        shift
        exec "${PROJECT_DIR}/scripts/build-bootfs.sh" "$@"
        ;;
    overlay-root)
        shift
        exec "${PROJECT_DIR}/scripts/build-overlay-root.sh" "$@"
        ;;
    update-engine-source)
        shift
        exec "${PROJECT_DIR}/scripts/stage-update-engine-source.sh" "$@"
        ;;
    update-engine)
        shift
        exec "${PROJECT_DIR}/scripts/build-update-engine.sh" "$@"
        ;;
    rockchip-test)
        shift
        exec "${PROJECT_DIR}/scripts/build-rockchip-test-package.sh" "$@"
        ;;
    edit-package-file|edit-ota-package-file|updateimg|ota-updateimg)
        command="$1"
        shift
        (( $# == 0 )) || { usage >&2; exit 2; }
        run_rockchip_command "$command"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
