#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CROSS_SCRIPT="${PROJECT_DIR}/scripts/cross-build-env.sh"
ACTION=build

usage() {
    cat <<'EOF'
usage: scripts/build-cross-example.sh [--print-plan] <libdrm>

Build patched libdrm ARM64 Debian packages.
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

if [[ "${1:-}" == --print-plan ]]; then
    ACTION=print
    shift
fi
example="${1:-}"
(( $# == 1 )) || { usage >&2; exit 2; }
case "$example" in
    libdrm) source_package=libdrm; package_format=deb ;;
    *) usage >&2; exit 2 ;;
esac

declare -A CALLER_ENV=()
for env_name in CROSS_BUILD_JOBS; do
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

config="$($CROSS_SCRIPT --print-config)"
base_image="$(sed -n 's/^image=//p' <<<"$config")"
output_root="$(sed -n 's/^output=//p' <<<"$config")"
base_tag="$(sed -n 's/^base.tag=//p' <<<"$config")"
jobs="${CROSS_BUILD_JOBS:-$(nproc)}"
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || die "CROSS_BUILD_JOBS must be positive"

if [[ "$ACTION" == print ]]; then
    printf 'example=%s\n' "$example"
    printf 'source.package=%s\n' "$source_package"
    printf 'package.format=%s\n' "$package_format"
    printf 'base.image=%s\n' "$base_image"
    printf 'output=%s\n' "$output_root"
    exit 0
fi

docker_cmd=()
if docker version --format '{{.Server.Arch}}' >/dev/null 2>&1; then
    docker_cmd=(docker)
elif sudo -n docker version --format '{{.Server.Arch}}' >/dev/null 2>&1; then
    docker_cmd=(sudo -n docker)
else
    die "Docker is unavailable"
fi
[[ "$("${docker_cmd[@]}" version --format '{{.Server.Arch}}')" == amd64 ]] ||
    die "cross-build examples require an amd64 Docker server"

if ! "${docker_cmd[@]}" image inspect "$base_image" >/dev/null 2>&1; then
    "$CROSS_SCRIPT" --prepare
fi
install -d -m 2775 "$output_root"

    example_image="ubuntu-cross-${example}:${base_tag//[^A-Za-z0-9_.-]/-}"
    info "Prepare ${example} Debian package image"
    "${docker_cmd[@]}" build --network host \
        --build-arg "CROSS_ENV_IMAGE=${base_image}" \
        --build-arg "SOURCE_PACKAGE=${source_package}" \
        --tag "$example_image" "${PROJECT_DIR}/containers/deb-cross-example"
    "${docker_cmd[@]}" run --rm --init --network host \
        --user "$(id -u):$(id -g)" --env HOME=/tmp \
        --env "EXAMPLE_NAME=${example}" \
        --env "SOURCE_PACKAGE=${source_package}" \
        --env "BUILD_JOBS=${jobs}" \
        --volume "${PROJECT_DIR}:/workspace:ro" \
        --volume "${output_root}:/out" \
        "$example_image"
    exit 0
