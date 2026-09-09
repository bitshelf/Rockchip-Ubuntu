#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() { echo "usage: scripts/pack-platform-assets.sh [output.tar.zst]"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[[ $# -le 1 ]] || { usage >&2; exit 2; }
declare -A CALLER_ENV=()
for name in BUILD_OUTPUT_DIR SOC_MODEL PLATFORM_ASSET_DIR; do
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
    *) die "unsupported host architecture: $(uname -m)" ;;
esac
SOC_MODEL="${SOC_MODEL:-}"
PLATFORM_ASSET_DIR="${PLATFORM_ASSET_DIR:-${BUILD_OUTPUT_DIR}/platform-assets/${SOC_MODEL}}"
output="${1:-${PROJECT_DIR}/artifacts/platform-assets-${SOC_MODEL}.tar.zst}"

[[ "$SOC_MODEL" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "invalid SOC_MODEL: $SOC_MODEL"
[[ "$PLATFORM_ASSET_DIR" == /* && "$(basename "$PLATFORM_ASSET_DIR")" == "$SOC_MODEL" ]] ||
    die "PLATFORM_ASSET_DIR must be absolute and end with SOC_MODEL"
[[ "$output" == /* && "$output" == *.tar.zst && "$output" != *[[:space:]]* ]] ||
    die "output must be an absolute .tar.zst path without whitespace"
for tool in sha256sum tar zstd; do
    command -v "$tool" >/dev/null || die "missing asset pack dependency: $tool"
done

BUILD_OUTPUT_DIR="$BUILD_OUTPUT_DIR" SOC_MODEL="$SOC_MODEL" \
    PLATFORM_ASSET_DIR="$PLATFORM_ASSET_DIR" \
    "${SCRIPT_DIR}/stage-sdk-assets.sh" --check

install -d -m 0755 "$(dirname "$output")"
stage="${output}.stage.$$"
trap 'rm -f -- "$stage"' EXIT
tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
    -C "$(dirname "$PLATFORM_ASSET_DIR")" -cf - "$SOC_MODEL" |
    zstd -q -T0 -10 -o "$stage"
chmod 0644 "$stage"
mv -f -- "$stage" "$output"
(
    cd "$(dirname "$output")"
    sha256sum "$(basename "$output")" >"$(basename "$output").sha256"
)
chmod 0644 "$output" "${output}.sha256"
trap - EXIT
printf 'bundle=%s\nsha256=%s\n' "$output" "$(sha256sum "$output" | awk '{print $1}')"
