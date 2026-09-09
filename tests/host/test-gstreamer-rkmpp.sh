#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

grep -Fq 'gstreamer/gstreamer1.0-rockchip1_*_arm64.deb|arm64|gstreamer-rkmpp-runtime' \
    "$PROJECT_DIR/config/local-debs/packages.conf" ||
    fail "gst-rkmpp local package entry is missing"
grep -Fq 'gstreamer1.0-rockchip1|gstreamer' \
    "$PROJECT_DIR/config/local-debs/prepare.conf" ||
    fail "gst-rkmpp generic preparation entry is missing"
for package in gstreamer1.0-tools gstreamer1.0-plugins-base \
        gstreamer1.0-plugins-good gstreamer1.0-plugins-bad; do
    grep -Eq "^[[:space:]]*[*][[:space:]]+${package}$" \
        "$PROJECT_DIR/config/ubuntu-image/seeds/rockchip-server" ||
        fail "missing Ubuntu GStreamer package: $package"
done
grep -Fq '! mpph264enc' "$PROJECT_DIR/tests/target/test-gstreamer-rkmpp.sh" ||
    fail "hardware encoder stage is missing"
grep -Fq '! mppvideodec' "$PROJECT_DIR/tests/target/test-gstreamer-rkmpp.sh" ||
    fail "hardware decoder stage is missing"
grep -Fq 'GSTREAMER_RKMPP_OK' "$PROJECT_DIR/tests/target/test-gstreamer-rkmpp.sh" ||
    fail "hardware pipeline acceptance marker is missing"

echo "GStreamer and gst-rkmpp contracts passed"
