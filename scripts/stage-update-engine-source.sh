#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

declare -A CALLER_ENV=()
for name in BUILD_OUTPUT_DIR SDK_DIR UPDATE_ENGINE_SOURCE_DIR \
    UPDATE_ENGINE_SOURCE_ARCHIVE; do
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

SDK_DIR="${SDK_DIR:-$(cd "${PROJECT_DIR}/.." && pwd)}"
case "$(uname -m)" in
    aarch64|arm64) BUILD_OUTPUT_DIR="${BUILD_OUTPUT_DIR:-/var/lib/ubuntu-ci/build}" ;;
    x86_64|amd64) BUILD_OUTPUT_DIR="${BUILD_OUTPUT_DIR:-${PROJECT_DIR}/build}" ;;
    *) die "unsupported build host: $(uname -m)" ;;
esac
UPDATE_ENGINE_SOURCE_DIR="${UPDATE_ENGINE_SOURCE_DIR:-${SDK_DIR}/external/recovery}"
UPDATE_ENGINE_SOURCE_ARCHIVE="${UPDATE_ENGINE_SOURCE_ARCHIVE:-${BUILD_OUTPUT_DIR}/sources/update-engine.tar}"
SOURCE_INFO="${UPDATE_ENGINE_SOURCE_ARCHIVE}.source-info"

for path in "$BUILD_OUTPUT_DIR" "$UPDATE_ENGINE_SOURCE_DIR" \
        "$UPDATE_ENGINE_SOURCE_ARCHIVE"; do
    [[ "$path" == /* && "$path" != *[[:space:]]* ]] ||
        die "paths must be absolute and contain no whitespace: $path"
done
for tool in awk git install sha256sum tar; do
    command -v "$tool" >/dev/null || die "missing source staging tool: $tool"
done
[[ -s "$UPDATE_ENGINE_SOURCE_DIR/Makefile" &&
   -s "$UPDATE_ENGINE_SOURCE_DIR/update_engine/main.c" ]] ||
    die "not a Rockchip recovery source tree: $UPDATE_ENGINE_SOURCE_DIR"
git -C "$UPDATE_ENGINE_SOURCE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    die "updateEngine source must be a Git checkout"
[[ -z "$(git -C "$UPDATE_ENGINE_SOURCE_DIR" status --porcelain --untracked-files=no)" ]] ||
    die "updateEngine source has tracked modifications"

commit="$(git -C "$UPDATE_ENGINE_SOURCE_DIR" rev-parse HEAD)"
short="$(git -C "$UPDATE_ENGINE_SOURCE_DIR" rev-parse --short=12 HEAD)"
date="$(git -C "$UPDATE_ENGINE_SOURCE_DIR" show -s --format=%cs HEAD)"
output_dir="$(dirname "$UPDATE_ENGINE_SOURCE_ARCHIVE")"
install -d -m 2775 "$output_dir"
archive_stage="$(mktemp "${output_dir}/.update-engine.tar.XXXXXX")"
info_stage="$(mktemp "${output_dir}/.update-engine.info.XXXXXX")"
cleanup() { rm -f -- "$archive_stage" "$info_stage"; }
trap cleanup EXIT
git -C "$UPDATE_ENGINE_SOURCE_DIR" archive --format=tar HEAD >"$archive_stage"
tar -tf "$archive_stage" |
    awk '$0 == "update_engine/main.c" {found=1} END {exit !found}' ||
    die "staged source archive is incomplete"
cat >"$info_stage" <<EOF
schema=ubuntu-update-engine-source-v1
source.commit=${commit}
source.commit.short=${short}
source.date=${date}
archive.sha256=$(sha256sum "$archive_stage" | awk '{print $1}')
EOF
chmod 0644 "$archive_stage" "$info_stage"
mv -f "$archive_stage" "$UPDATE_ENGINE_SOURCE_ARCHIVE"
mv -f "$info_stage" "$SOURCE_INFO"
trap - EXIT
info "updateEngine source staged: $UPDATE_ENGINE_SOURCE_ARCHIVE"
info "Source commit: $commit"
