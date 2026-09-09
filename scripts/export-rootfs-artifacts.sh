#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }

declare -A CALLER_ENV=()
for name in BUILD_OUTPUT_DIR; do
    [[ -v "$name" ]] && CALLER_ENV["$name"]="${!name}"
done
if [[ -f "${PROJECT_DIR}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${PROJECT_DIR}/.env"
    set +a
fi
for name in "${!CALLER_ENV[@]}"; do
    printf -v "$name" '%s' "${CALLER_ENV[$name]}"
done

case "$(uname -m)" in
    aarch64|arm64) BUILD_OUTPUT_DIR="${BUILD_OUTPUT_DIR:-/var/lib/ubuntu-ci/build}" ;;
    x86_64|amd64) BUILD_OUTPUT_DIR="${BUILD_OUTPUT_DIR:-${PROJECT_DIR}/build}" ;;
    *) die "unsupported build-host architecture: $(uname -m)" ;;
esac
images_dir="${1:-${BUILD_OUTPUT_DIR}/images}"
[[ "$images_dir" == /* && -d "$images_dir" && ! -L "$images_dir" ]] ||
    die "images directory must be an existing absolute directory: $images_dir"

mapfile -d '' -t rootfs_files < <(
    find "$images_dir" -maxdepth 1 -type f -name '*-server-arm64.rootfs.tar.gz' \
        -print0 | sort -z
)
(( ${#rootfs_files[@]} == 1 )) ||
    die "expected one Server ARM64 rootfs in $images_dir, found ${#rootfs_files[@]}"

rootfs="${rootfs_files[0]}"
prefix="${rootfs%.rootfs.tar.gz}"
artifacts=(
    "$rootfs"
    "${rootfs}.sha256"
    "${prefix}.manifest"
    "${prefix}.filelist"
    "${prefix}.build-info"
    "${prefix}.qa.json"
)
for artifact in "${artifacts[@]}"; do
    [[ -s "$artifact" && ! -L "$artifact" ]] ||
        die "missing Server rootfs artifact: $artifact"
done
(
    cd "$images_dir"
    sha256sum --quiet -c "$(basename "${rootfs}.sha256")"
) || die "Server rootfs checksum verification failed"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    [[ "$GITHUB_OUTPUT" == /* ]] || die "GITHUB_OUTPUT must be an absolute path"
    {
        printf 'name=%s\n' "$(basename "$prefix")"
        echo 'paths<<ROOTFS_ARTIFACTS'
        printf '%s\n' "${artifacts[@]}"
        echo 'ROOTFS_ARTIFACTS'
    } >>"$GITHUB_OUTPUT"
else
    printf '%s\n' "${artifacts[@]}"
fi
