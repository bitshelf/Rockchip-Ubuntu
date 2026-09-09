#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONTAINER_DIR="${PROJECT_DIR}/containers/cross-build"
MODE="${1:-}"

usage() {
    cat <<'EOF'
usage: scripts/cross-build-env.sh <--prepare|--check|--print-config|--shell|-- COMMAND...>

Build and use the ARM64 cross-compilation environment on an x86_64 host.
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

declare -A CALLER_ENV=()
for env_name in CROSS_BASE_IMAGE CROSS_BASE_TAG CROSS_TARGET_ARCH \
    CROSS_TARGET_TRIPLET CROSS_ENV_IMAGE CROSS_OUTPUT_DIR \
    NATIVE_APT_MIRROR TARGET_APT_MIRROR; do
    if [[ -v "$env_name" ]]; then
        CALLER_ENV["$env_name"]="${!env_name}"
    fi
done

if [[ -f "${PROJECT_DIR}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${PROJECT_DIR}/.env"
    set +a
fi
for env_name in "${!CALLER_ENV[@]}"; do
    printf -v "$env_name" '%s' "${CALLER_ENV[$env_name]}"
    export "${env_name?}"
done

CROSS_BASE_IMAGE="${CROSS_BASE_IMAGE:-ubuntu}"
CROSS_BASE_TAG="${CROSS_BASE_TAG:-}"
CROSS_TARGET_ARCH="${CROSS_TARGET_ARCH:-arm64}"
CROSS_TARGET_TRIPLET="${CROSS_TARGET_TRIPLET:-aarch64-linux-gnu}"
NATIVE_APT_MIRROR="${NATIVE_APT_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/ubuntu/}"
TARGET_APT_MIRROR="${TARGET_APT_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/}"

[[ -n "$CROSS_BASE_TAG" && "$CROSS_BASE_TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
    die "set CROSS_BASE_TAG to the target Ubuntu base-image tag"
[[ "$CROSS_TARGET_ARCH" == arm64 ]] ||
    die "unsupported CROSS_TARGET_ARCH: $CROSS_TARGET_ARCH"
[[ "$CROSS_TARGET_TRIPLET" == aarch64-linux-gnu ]] ||
    die "unsupported CROSS_TARGET_TRIPLET: $CROSS_TARGET_TRIPLET"
[[ "$CROSS_BASE_IMAGE" =~ ^[A-Za-z0-9./:_-]+$ ]] ||
    die "invalid CROSS_BASE_IMAGE: $CROSS_BASE_IMAGE"
for mirror in "$NATIVE_APT_MIRROR" "$TARGET_APT_MIRROR"; do
    [[ "$mirror" =~ ^https?://[A-Za-z0-9./:_-]+$ ]] ||
        die "invalid APT mirror: $mirror"
done

safe_tag="${CROSS_BASE_TAG//[^A-Za-z0-9_.-]/-}"
CROSS_ENV_IMAGE="${CROSS_ENV_IMAGE:-ubuntu-cross-${CROSS_TARGET_ARCH}:${safe_tag}}"
CROSS_OUTPUT_DIR="${CROSS_OUTPUT_DIR:-${PROJECT_DIR}/build/cross}"
[[ "$CROSS_OUTPUT_DIR" == /* && "$CROSS_OUTPUT_DIR" != *[[:space:]]* ]] ||
    die "CROSS_OUTPUT_DIR must be absolute and contain no whitespace"

print_config() {
    echo "base.image=${CROSS_BASE_IMAGE}"
    echo "base.tag=${CROSS_BASE_TAG}"
    echo "target.arch=${CROSS_TARGET_ARCH}"
    echo "target.triplet=${CROSS_TARGET_TRIPLET}"
    echo "image=${CROSS_ENV_IMAGE}"
    echo "output=${CROSS_OUTPUT_DIR}"
    echo "native.mirror=${NATIVE_APT_MIRROR}"
    echo "target.mirror=${TARGET_APT_MIRROR}"
}

[[ "$MODE" == --print-config ]] && { print_config; exit 0; }
case "$MODE" in
    --prepare|--check|--shell|--) ;;
    -h|--help|help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

docker_cmd=()
if docker version --format '{{.Server.Arch}}' >/dev/null 2>&1; then
    docker_cmd=(docker)
elif sudo -n docker version --format '{{.Server.Arch}}' >/dev/null 2>&1; then
    docker_cmd=(sudo -n docker)
else
    die "Docker is unavailable"
fi

prepare_image() {
    info "Build cross environment: $CROSS_ENV_IMAGE"
    "${docker_cmd[@]}" build --network host \
        --build-arg "BASE_IMAGE=${CROSS_BASE_IMAGE}" \
        --build-arg "BASE_TAG=${CROSS_BASE_TAG}" \
        --build-arg "TARGET_DEB_ARCH=${CROSS_TARGET_ARCH}" \
        --build-arg "TARGET_GNU_TRIPLET=${CROSS_TARGET_TRIPLET}" \
        --build-arg "NATIVE_APT_MIRROR=${NATIVE_APT_MIRROR}" \
        --build-arg "TARGET_APT_MIRROR=${TARGET_APT_MIRROR}" \
        --tag "$CROSS_ENV_IMAGE" "$CONTAINER_DIR"
}

if [[ "$MODE" == --prepare ]]; then
    prepare_image
    exit 0
fi
if ! "${docker_cmd[@]}" image inspect "$CROSS_ENV_IMAGE" >/dev/null 2>&1; then
    prepare_image
fi

install -d -m 2775 "$CROSS_OUTPUT_DIR"
run_args=(run --rm --init --network host
    --user "$(id -u):$(id -g)"
    --env HOME=/tmp
    --volume "${PROJECT_DIR}:/workspace:ro"
    --volume "${CROSS_OUTPUT_DIR}:/out"
    --workdir /workspace)

case "$MODE" in
    --check)
        "${docker_cmd[@]}" "${run_args[@]}" "$CROSS_ENV_IMAGE" --check
        ;;
    --shell)
        "${docker_cmd[@]}" "${run_args[@]}" --interactive --tty \
            "$CROSS_ENV_IMAGE" --shell
        ;;
    --)
        shift
        (( $# > 0 )) || die "missing command after --"
        "${docker_cmd[@]}" "${run_args[@]}" "$CROSS_ENV_IMAGE" -- "$@"
        ;;
esac
