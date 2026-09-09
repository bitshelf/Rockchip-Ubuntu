#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

for purpose in rkaiq-runtime rkisp-legacy-runtime; do
    grep -Fq "|$purpose\"" "$PROJECT_DIR/config/local-debs/packages.conf" ||
        fail "missing local package purpose: $purpose"
done
grep -Fq 'camera-engine-rkaiq|isp' \
    "$PROJECT_DIR/config/local-debs/prepare.conf" ||
    fail "rkaiq generic preparation entry is missing"
grep -Fq 'LOCAL_DATA_DEB_ENTRIES=()' \
    "$PROJECT_DIR/config/local-debs/prepare.conf" ||
    fail "baseline unexpectedly carries a board-specific data package"
grep -Fq 'Restart=always' \
    "$PROJECT_DIR/package/isp/rkaiq_3A.service.d/ubuntu.conf" ||
    fail "rkaiq service restart policy is missing"
grep -Fq 'ExecCondition=/usr/libexec/rockchip-rkaiq-ready' \
    "$PROJECT_DIR/package/isp/rkaiq_3A.service.d/ubuntu.conf" ||
    fail "rkaiq readiness condition is missing"
[[ -f "$PROJECT_DIR/config/dts/examples/rk3576-ov13855-camera.dtso" ]] ||
    fail "replaceable camera overlay example is missing"
[[ ! -f "$PROJECT_DIR/config/dts/rk3576-ov13855-camera.dtso" ]] ||
    fail "camera example must not be enabled by default overlay discovery"
install -d "$tmp/sys/v4l-subdev7" "$tmp/iq"
printf '%s\n' 'm00_b_ov13855 8-0036' >"$tmp/sys/v4l-subdev7/name"
if RKAIQ_VIDEO4LINUX_SYSFS="$tmp/sys" RKAIQ_IQ_DIR="$tmp/iq" \
        "$PROJECT_DIR/package/isp/rockchip-rkaiq-ready" >/dev/null 2>&1; then
    fail "rkaiq readiness accepted a sensor without matching IQ"
fi
printf '{}\n' >"$tmp/iq/ov13855_module.json"
RKAIQ_VIDEO4LINUX_SYSFS="$tmp/sys" RKAIQ_IQ_DIR="$tmp/iq" \
    "$PROJECT_DIR/package/isp/rockchip-rkaiq-ready" ||
    fail "rkaiq readiness rejected matching sensor IQ"
grep -Fq 'ISP_CAMERA_OK' "$PROJECT_DIR/tests/target/test-isp-camera.sh" ||
    fail "target camera acceptance marker is missing"
echo "ISP package and QA contract checks passed"
