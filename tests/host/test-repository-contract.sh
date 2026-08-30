#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

tracked_binaries="$(
    git -C "$PROJECT_DIR" ls-files -- '*.deb' '*.dtb' '*.dtbo' '*.img' '*.ko' '*.snap'
)"
[[ -z "$tracked_binaries" ]] || fail "generated binary input is tracked: $tracked_binaries"


for directory in config docs scripts tests/host; do
    [[ -d "${PROJECT_DIR}/${directory}" ]] || fail "missing directory: $directory"
done

echo "Repository contract checks passed"
