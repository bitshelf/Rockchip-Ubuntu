#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MODE=required

usage() { echo "usage: scripts/fetch-platform-assets.sh [--if-configured] [bundle-url-or-path]"; }
die() { echo "ERROR: $*" >&2; exit 1; }

case "${1:-}" in
    --if-configured) MODE=optional; shift ;;
    -h|--help) usage; exit 0 ;;
esac
[[ $# -le 1 ]] || { usage >&2; exit 2; }

declare -A CALLER_ENV=()
for name in BUILD_OUTPUT_DIR SOC_MODEL PLATFORM_ASSET_DIR \
        PLATFORM_ASSET_BUNDLE_URL PLATFORM_ASSET_BUNDLE_SHA256 \
        PLATFORM_ASSET_AUTH_HEADER; do
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
source="${1:-${PLATFORM_ASSET_BUNDLE_URL:-}}"

[[ "$SOC_MODEL" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "invalid SOC_MODEL: $SOC_MODEL"
[[ "$PLATFORM_ASSET_DIR" == /* && "$(basename "$PLATFORM_ASSET_DIR")" == "$SOC_MODEL" ]] ||
    die "PLATFORM_ASSET_DIR must be absolute and end with SOC_MODEL"
if [[ -z "$source" ]]; then
    [[ "$MODE" == optional ]] || die "PLATFORM_ASSET_BUNDLE_URL is not configured"
    BUILD_OUTPUT_DIR="$BUILD_OUTPUT_DIR" SOC_MODEL="$SOC_MODEL" \
        PLATFORM_ASSET_DIR="$PLATFORM_ASSET_DIR" \
        "${SCRIPT_DIR}/stage-sdk-assets.sh" --check
    echo "Using existing platform assets: $PLATFORM_ASSET_DIR"
    exit 0
fi
for tool in curl sha256sum tar zstd; do
    command -v "$tool" >/dev/null || die "missing asset fetch dependency: $tool"
done

parent="$(dirname "$PLATFORM_ASSET_DIR")"
install -d -m 2775 "$parent"
work="$(mktemp -d "${parent}/.asset-fetch.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT
bundle="$work/platform-assets.tar.zst"
checksum="${PLATFORM_ASSET_BUNDLE_SHA256:-}"

if [[ "$source" == http://* || "$source" == https://* ]]; then
    curl_args=(--fail --silent --show-error --location)
    [[ -z "${PLATFORM_ASSET_AUTH_HEADER:-}" ]] ||
        curl_args+=(--header "$PLATFORM_ASSET_AUTH_HEADER")
    curl "${curl_args[@]}" --output "$bundle" "$source"
    if [[ -z "$checksum" ]]; then
        curl "${curl_args[@]}" --output "$work/checksum" "${source}.sha256"
        checksum="$(awk 'NR == 1 {print $1}' "$work/checksum")"
    fi
else
    [[ "$source" == /* && -s "$source" && ! -L "$source" ]] ||
        die "local asset bundle must be an absolute regular file: $source"
    install -m 0644 "$source" "$bundle"
    if [[ -z "$checksum" ]]; then
        [[ -s "${source}.sha256" ]] || die "missing bundle checksum: ${source}.sha256"
        checksum="$(awk 'NR == 1 {print $1}' "${source}.sha256")"
    fi
fi
[[ "$checksum" =~ ^[0-9a-fA-F]{64}$ ]] || die "invalid platform asset SHA256"
[[ "$(sha256sum "$bundle" | awk '{print $1}')" == "${checksum,,}" ]] ||
    die "platform asset bundle checksum mismatch"

zstd -q -dc "$bundle" >"$work/bundle.tar"
while IFS= read -r member; do
    [[ "$member" == "$SOC_MODEL" || "$member" == "$SOC_MODEL/"* ]] ||
        die "bundle member is outside SOC_MODEL: $member"
    [[ "$member" != /* && "$member" != *'/../'* && "$member" != '../'* ]] ||
        die "unsafe bundle member: $member"
done < <(tar -tf "$work/bundle.tar")
install -d -m 0755 "$work/extracted"
tar --no-same-owner -xf "$work/bundle.tar" -C "$work/extracted"
candidate="$work/extracted/$SOC_MODEL"
BUILD_OUTPUT_DIR="$BUILD_OUTPUT_DIR" SOC_MODEL="$SOC_MODEL" \
    PLATFORM_ASSET_DIR="$candidate" "${SCRIPT_DIR}/stage-sdk-assets.sh" --check

previous="${PLATFORM_ASSET_DIR}.previous.$$"
[[ ! -e "$previous" ]] || die "stale asset backup exists: $previous"
if [[ -e "$PLATFORM_ASSET_DIR" ]]; then
    mv "$PLATFORM_ASSET_DIR" "$previous"
fi
if mv "$candidate" "$PLATFORM_ASSET_DIR"; then
    rm -rf -- "$previous"
else
    [[ ! -e "$previous" ]] || mv "$previous" "$PLATFORM_ASSET_DIR"
    die "cannot install downloaded platform assets"
fi
chmod 2750 "$PLATFORM_ASSET_DIR"
trap - EXIT
rm -rf -- "$work"
echo "Installed platform assets: $PLATFORM_ASSET_DIR"
