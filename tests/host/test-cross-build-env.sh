#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${PROJECT_DIR}/scripts/cross-build-env.sh"
ENTRYPOINT="${PROJECT_DIR}/containers/cross-build/entrypoint.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

output="$(CROSS_BASE_TAG=future-release CROSS_OUTPUT_DIR="${tmp_dir}/out" \
    "$SCRIPT" --print-config)"
grep -Fxq 'base.tag=future-release' <<<"$output" ||
    fail "base-image tag is not configurable"
grep -Fxq 'target.arch=arm64' <<<"$output" ||
    fail "ARM64 target is not selected"
grep -Fxq 'output='"${tmp_dir}/out" <<<"$output" ||
    fail "cross output override was not honored"

output="$(NATIVE_ARCH_OVERRIDE=amd64 TARGET_DEB_ARCH=arm64 \
    TARGET_GNU_TRIPLET=aarch64-linux-gnu "$ENTRYPOINT" --print-env)"
grep -Fxq 'compiler=aarch64-linux-gnu-gcc' <<<"$output" ||
    fail "x86 host did not select the cross compiler"
grep -Fxq 'cross_compile=aarch64-linux-gnu-' <<<"$output" ||
    fail "x86 host did not export the cross prefix"
if NATIVE_ARCH_OVERRIDE=arm64 TARGET_DEB_ARCH=arm64 \
    TARGET_GNU_TRIPLET=aarch64-linux-gnu "$ENTRYPOINT" --print-env \
    >"${tmp_dir}/native.log" 2>&1; then
    fail "ARM64 native mode was accepted"
fi

if rg -n '26\.04|resolute|rk3576' "$SCRIPT" \
    "${PROJECT_DIR}/containers/cross-build"; then
    fail "cross-build implementation is tied to a release or SoC"
fi
if CROSS_BASE_TAG=bad/tag "$SCRIPT" --print-config \
    >"${tmp_dir}/bad-tag.log" 2>&1; then
    fail "invalid base-image tag was accepted"
fi

echo "Cross-build environment checks passed"
