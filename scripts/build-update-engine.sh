#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MODE="${1:-build}"

usage() { echo "usage: scripts/build-update-engine.sh [--check]"; }
die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

case "$MODE" in
    build) (( $# == 0 )) || { usage >&2; exit 2; } ;;
    --check) (( $# == 1 )) || { usage >&2; exit 2; } ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

declare -A CALLER_ENV=()
for name in BUILD_OUTPUT_DIR UPDATE_ENGINE_SOURCE_ARCHIVE \
    UPDATE_ENGINE_PACKAGE_DIR CROSS_BASE_TAG; do
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
    export "${name?}"
done

case "$(uname -m)" in
    aarch64|arm64)
        host_arch=arm64
        BUILD_OUTPUT_DIR="${BUILD_OUTPUT_DIR:-/var/lib/ubuntu-ci/build}"
        ;;
    x86_64|amd64)
        host_arch=amd64
        BUILD_OUTPUT_DIR="${BUILD_OUTPUT_DIR:-${PROJECT_DIR}/build}"
        ;;
    *) die "unsupported build host: $(uname -m)" ;;
esac
UPDATE_ENGINE_SOURCE_ARCHIVE="${UPDATE_ENGINE_SOURCE_ARCHIVE:-${BUILD_OUTPUT_DIR}/sources/update-engine.tar}"
UPDATE_ENGINE_PACKAGE_DIR="${UPDATE_ENGINE_PACKAGE_DIR:-${BUILD_OUTPUT_DIR}/packages/update-engine}"
SOURCE_INFO="${UPDATE_ENGINE_SOURCE_ARCHIVE}.source-info"

for path in "$BUILD_OUTPUT_DIR" "$UPDATE_ENGINE_SOURCE_ARCHIVE" \
        "$UPDATE_ENGINE_PACKAGE_DIR"; do
    [[ "$path" == /* && "$path" != *[[:space:]]* ]] ||
        die "paths must be absolute and contain no whitespace: $path"
done
for input in "$UPDATE_ENGINE_SOURCE_ARCHIVE" "$SOURCE_INFO"; do
    [[ -s "$input" && ! -L "$input" ]] || die "missing staged source input: $input"
done
grep -Fxq 'schema=ubuntu-update-engine-source-v1' "$SOURCE_INFO" ||
    die "unsupported staged source metadata"
expected="$(awk -F= '$1 == "archive.sha256" {print $2}' "$SOURCE_INFO")"
actual="$(sha256sum "$UPDATE_ENGINE_SOURCE_ARCHIVE" | awk '{print $1}')"
[[ "$expected" =~ ^[0-9a-f]{64}$ && "$actual" == "$expected" ]] ||
    die "updateEngine source archive checksum mismatch"
tar -tf "$UPDATE_ENGINE_SOURCE_ARCHIVE" |
    awk '$0 == "update_engine/main.c" {found=1} END {exit !found}' ||
    die "updateEngine source archive is incomplete"

if [[ "$MODE" == --check ]]; then
    info "updateEngine source and build configuration are valid"
    echo "host.arch=$host_arch"
    echo "source=$UPDATE_ENGINE_SOURCE_ARCHIVE"
    echo "output=$UPDATE_ENGINE_PACKAGE_DIR"
    exit 0
fi

if [[ "$host_arch" == amd64 ]]; then
    [[ "$UPDATE_ENGINE_SOURCE_ARCHIVE" == "${BUILD_OUTPUT_DIR%/}/"* &&
       "$UPDATE_ENGINE_PACKAGE_DIR" == "${BUILD_OUTPUT_DIR%/}/"* ]] ||
        die "x86 cross-build inputs and output must be below BUILD_OUTPUT_DIR"
    archive_in_container="/out/${UPDATE_ENGINE_SOURCE_ARCHIVE#"${BUILD_OUTPUT_DIR%/}/"}"
    info_in_container="${archive_in_container}.source-info"
    package_in_container="/out/${UPDATE_ENGINE_PACKAGE_DIR#"${BUILD_OUTPUT_DIR%/}/"}"
    CROSS_OUTPUT_DIR="$BUILD_OUTPUT_DIR" \
        "${SCRIPT_DIR}/cross-build-env.sh" -- \
        /workspace/scripts/build-update-engine-package.sh \
        "$archive_in_container" "$info_in_container" "$package_in_container"
else
    "${SCRIPT_DIR}/build-update-engine-package.sh" \
        "$UPDATE_ENGINE_SOURCE_ARCHIVE" "$SOURCE_INFO" \
        "$UPDATE_ENGINE_PACKAGE_DIR"
fi
info "updateEngine package built: $UPDATE_ENGINE_PACKAGE_DIR"
