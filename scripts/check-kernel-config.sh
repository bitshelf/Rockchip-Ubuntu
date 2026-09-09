#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
actual_config="${1:-}"
requirements="${2:-${PROJECT_DIR}/config/kernel/overlay-root.conf}"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -s "$actual_config" ]] ||
    die "usage: scripts/check-kernel-config.sh <kernel.config> [requirements]"
[[ -s "$requirements" ]] || die "missing kernel requirements: $requirements"

checked=0
while IFS= read -r requirement || [[ -n "$requirement" ]]; do
    [[ -z "$requirement" ]] && continue
    if [[ "$requirement" =~ ^CONFIG_[A-Z0-9_]+=.+$ ||
          "$requirement" =~ ^#[[:space:]]CONFIG_[A-Z0-9_]+[[:space:]]is[[:space:]]not[[:space:]]set$ ]]; then
        :
    elif [[ "$requirement" == \#* ]]; then
        continue
    else
        die "invalid kernel requirement: $requirement"
    fi
    grep -Fxq "$requirement" "$actual_config" ||
        die "kernel config does not satisfy: $requirement"
    (( checked += 1 ))
done <"$requirements"

(( checked > 0 )) || die "kernel requirement set is empty: $requirements"
echo "Kernel overlay-root config passed (${checked} requirements): $actual_config"
