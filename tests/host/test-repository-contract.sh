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

workflow_count=0
while IFS= read -r -d '' workflow; do
    (( workflow_count += 1 ))
    [[ -s "$workflow" ]] || fail "empty Forgejo workflow: $workflow"
    grep -Eq '^name:[[:space:]]+[^[:space:]]' "$workflow" ||
        fail "Forgejo workflow has no name: $workflow"
    grep -Eq '^on:' "$workflow" ||
        fail "Forgejo workflow has no trigger: $workflow"
    grep -Eq '^jobs:' "$workflow" ||
        fail "Forgejo workflow has no jobs: $workflow"
    grep -Eq '^[[:space:]]+runs-on:[[:space:]]+[^[:space:]]' "$workflow" ||
        fail "Forgejo workflow has no runner label: $workflow"
done < <(
    find "${PROJECT_DIR}/.forgejo/workflows" -maxdepth 1 -type f \
        \( -name '*.yaml' -o -name '*.yml' \) -print0 2>/dev/null | sort -z
)
(( workflow_count > 0 )) || fail "missing Forgejo workflow"
[[ ! -d "${PROJECT_DIR}/.github/workflows" ]] ||
    fail "GitHub Actions workflows are not used by this repository"

echo "Repository contract checks passed"
