#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
usage: ./build.sh server [--check]

  server          build the Ubuntu 26 Server ARM64 rootfs
  server --check  validate configuration and host prerequisites only
EOF
}

case "${1:-}" in
    server)
        shift
        exec "${PROJECT_DIR}/scripts/build-server.sh" "$@"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
