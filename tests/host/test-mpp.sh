#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# shellcheck source=../target/test-mpp.sh
source "$PROJECT_DIR/tests/target/test-mpp.sh"

encode_fixture="$({
    for ((frame = 0; frame < MPP_FRAMES; frame++)); do
        printf 'I mpi_enc_test: chn 0 encoded frame %-4d size 1024 qp 20\n' "$frame"
    done
    printf '%s\n' 'I mpi_enc_test: chn 0 encoded frame 42 pkt 1 size 512'
})"
[[ "$(mpp_encoded_frame_summary <<<"$encode_fixture")" == '100 0 99' ]] ||
    fail "complete MPP encoder counter range was rejected"
incomplete="${encode_fixture/encoded frame 99/encoded frame 98}"
[[ "$(mpp_encoded_frame_summary <<<"$incomplete")" != '100 0 99' ]] ||
    fail "incomplete MPP encoder counter range was accepted"
[[ "$(mpp_decoded_frame_count <<<'I mpi_dec_test: decode 100 frames time 1 ms')" == 100 ]] ||
    fail "MPP decoder frame count was not parsed"

asset_dir="$tmp_dir/platform-assets/test"
install -d -m 0755 "$asset_dir/debs"
for spec in \
        'librockchip-mpp1|mpp-runtime' \
        'librockchip-vpu0|mpp-vpu-runtime' \
        'rockchip-mpp-demos|mpp-qa-tools'; do
    IFS='|' read -r package purpose <<<"$spec"
    package_root="$tmp_dir/$package"
    install -d -m 0755 "$package_root/DEBIAN"
    printf '%s\n' \
        "Package: $package" \
        'Version: 1.5.0-1' \
        'Architecture: arm64' \
        'Maintainer: Ubuntu image CI <root@localhost>' \
        'Description: MPP local DEB fixture' >"$package_root/DEBIAN/control"
    name="${package}_1.5.0-1_arm64.deb"
    dpkg-deb --build "$package_root" "$asset_dir/debs/$name" >/dev/null
    printf 'mpp/%s\t%s\t%s\t1.5.0-1\tarm64\t%s\n' \
        "$name" "$name" "$package" "$purpose" >>"$asset_dir/local-deb-manifest.tsv"
done

for purpose in mpp-runtime mpp-vpu-runtime mpp-qa-tools; do
    [[ -s "$("$PROJECT_DIR/scripts/find-local-deb.sh" "$asset_dir" "$purpose")" ]] ||
        fail "$purpose did not resolve"
done
for entry in \
        'mpp/librockchip-mpp1_*_arm64.deb|arm64|mpp-runtime' \
        'mpp/librockchip-vpu0_*_arm64.deb|arm64|mpp-vpu-runtime' \
        'mpp/rockchip-mpp-demos_*_arm64.deb|arm64|mpp-qa-tools'; do
    grep -Fq "\"$entry\"" "$PROJECT_DIR/config/local-debs/packages.conf" ||
        fail "MPP package input is missing: $entry"
done
grep -Fxq 'MPP_FRAMES=100' "$PROJECT_DIR/tests/target/test-mpp.sh" ||
    fail "MPP target QA is not fixed at 100 frames"
grep -Fq 'KERNEL=="mpp_service", MODE="0666"' \
    "$PROJECT_DIR/package/mpp/99-rockchip-mpp.rules" ||
    fail "MPP device access policy is missing"

echo "MPP local-DEB and 100-frame parser checks passed"
