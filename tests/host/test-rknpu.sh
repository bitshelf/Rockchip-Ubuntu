#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../target/test-rknpu.sh
source "$PROJECT_DIR/tests/target/test-rknpu.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

fixture_output() {
    local count="$1" latency="$2" confidence="$3" class="$4" index
    for ((index = 0; index < count; index++)); do
        printf '%4d: Elapse Time = %sms, FPS = 400.00\n' "$index" "$latency"
    done
    printf '%s\n' '---- Top5 ----' "$confidence - $class" '0.010000 - 1'
}

output="$(fixture_output 200 2.50 0.935059 156)"
marker="$(rknpu_validate_output "$output" 200)" || fail "valid RKNPU fixture failed"
grep -Fq 'RKNPU_SOAK_OK completed=200 expected=200' <<<"$marker" ||
    fail "200/200 marker is missing"
grep -Fq 'top1_class=156 top1=0.935059' <<<"$marker" ||
    fail "top-1 evidence is missing"
grep -Fq 'min_ms=2.50 avg_ms=2.50 max_ms=2.50 limit_ms=15' <<<"$marker" ||
    fail "latency evidence is missing"

for bad in \
    "$(fixture_output 199 2.50 0.935059 156)" \
    "$(fixture_output 200 15.00 0.935059 156)" \
    "$(fixture_output 200 2.50 0.499000 156)" \
    "$(fixture_output 200 2.50 0.935059 155)"; do
    if rknpu_validate_output "$bad" 200 >/dev/null 2>&1; then
        fail "invalid RKNPU fixture was accepted"
    fi
done

for purpose in rknpu-runtime rknpu-tools rknpu-models; do
    grep -Fq "|$purpose\"" "$PROJECT_DIR/config/local-debs/packages.conf" ||
        fail "missing local package purpose: $purpose"
done
grep -Fq 'CONFIG_ROCKCHIP_RKNPU=y' "$PROJECT_DIR/config/kernel/overlay-root.conf" ||
    fail "RKNPU kernel requirement is missing"
grep -Fq 'DRIVERS=="rknpu"' \
    "$PROJECT_DIR/package/rknpu2/debian/60-rockchip-rknpu.rules" ||
    fail "generic RKNPU DRM permission rule is missing"
grep -Fq 'GROUP="render", MODE="0660"' \
    "$PROJECT_DIR/package/rknpu2/debian/60-rockchip-rknpu.rules" ||
    fail "RKNPU render-group access is missing"
bash -n "$PROJECT_DIR/tests/target/test-rknpu.sh" \
    "$PROJECT_DIR/package/rknpu2/debian/install-blobs.sh"

echo "RKNPU package, parser and non-root QA checks passed"
