#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

for entry in \
        'v4l/libv4l-0t64_*_arm64.deb|arm64|v4l-runtime' \
        'v4l/libv4lconvert0t64_*_arm64.deb|arm64|v4l-convert-runtime' \
        'v4l/libv4l2rds0t64_*_arm64.deb|arm64|v4l-rds-runtime' \
        'v4l/v4l-utils_*_arm64.deb|arm64|v4l-tools' \
        'v4l/libv4l-rkmpp1_*_arm64.deb|arm64|v4l-rkmpp-runtime'; do
    grep -Fq "\"$entry\"" "$PROJECT_DIR/config/local-debs/packages.conf" ||
        fail "missing V4L2 local package: $entry"
done
grep -Fq 'v4l-utils|ubuntu-source|' "$PROJECT_DIR/config/local-debs/build.conf" ||
    fail "patched v4l-utils build is missing"
grep -Fq 'libv4l-rkmpp|debian-recipe|' "$PROJECT_DIR/config/local-debs/build.conf" ||
    fail "libv4l-rkmpp build is missing"
[[ "$(find "$PROJECT_DIR/package/v4l-utils/patches" -type f -name '*.patch' | wc -l)" -eq 5 ]] ||
    fail "unexpected Resolute v4l-utils patch count"
grep -Fq 'V4L2_RKMPP_OK' "$PROJECT_DIR/tests/target/test-v4l2.sh" ||
    fail "V4L2 MPP acceptance marker is missing"
grep -Fq 'V4L2_CAPTURE_OK' "$PROJECT_DIR/tests/target/test-v4l2.sh" ||
    fail "independent V4L2 capture marker is missing"
grep -Fq 'printf "dec\n" > /dev/video-dec0' \
    "$PROJECT_DIR/package/libv4l-rkmpp/runtime/rkmpp-video-nodes.service" ||
    fail "virtual decoder endpoint service is missing"

echo "V4L2 package, plugin and target QA contracts passed"
