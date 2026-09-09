#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="${PROJECT_DIR}/scripts/check-kernel-config.sh"
REQUIREMENTS="${PROJECT_DIR}/config/kernel/overlay-root.conf"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

cp "$REQUIREMENTS" "${tmp_dir}/good.config"
printf '%s\n' 'CONFIG_UNRELATED_OPTION=y' >>"${tmp_dir}/good.config"
"$CHECKER" "${tmp_dir}/good.config"

grep -Fvx 'CONFIG_EROFS_FS=y' "${tmp_dir}/good.config" \
    >"${tmp_dir}/bad.config"
printf '%s\n' '# CONFIG_EROFS_FS is not set' >>"${tmp_dir}/bad.config"
if "$CHECKER" "${tmp_dir}/bad.config" >"${tmp_dir}/bad.log" 2>&1; then
    fail "modular or disabled EROFS passed the built-in kernel contract"
fi
grep -Fq 'kernel config does not satisfy: CONFIG_EROFS_FS=y' \
    "${tmp_dir}/bad.log" || fail "missing EROFS failure evidence"

echo "Kernel overlay-root configuration checks passed"
