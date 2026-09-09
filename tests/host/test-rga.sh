#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

asset_dir="$tmp_dir/platform-assets/test"
install -d -m 0755 "$asset_dir/debs"
for spec in 'librga2|rga-runtime' 'librga-dev|rga-development'; do
    IFS='|' read -r package purpose <<<"$spec"
    root="$tmp_dir/$package"
    install -d -m 0755 "$root/DEBIAN"
    cat >"$root/DEBIAN/control" <<EOF
Package: $package
Version: 2.2.0-1
Architecture: arm64
Maintainer: Ubuntu image CI <root@localhost>
Description: RGA local DEB fixture
EOF
    name="${package}_2.2.0-1_arm64.deb"
    dpkg-deb --build "$root" "$asset_dir/debs/$name" >/dev/null
    printf 'rga/%s\t%s\t%s\t2.2.0-1\tarm64\t%s\n' \
        "$name" "$name" "$package" "$purpose" \
        >>"$asset_dir/local-deb-manifest.tsv"
done

for purpose in rga-runtime rga-development; do
    resolved="$("$PROJECT_DIR/scripts/find-local-deb.sh" "$asset_dir" "$purpose")"
    [[ -s "$resolved" ]] || fail "$purpose did not resolve"
done
grep -Fq 'rga/librga2_*_arm64.deb|arm64|rga-runtime' \
    "$PROJECT_DIR/config/local-debs/packages.conf" || fail "RGA runtime input is missing"
grep -Fq 'rga/librga-dev_*_arm64.deb|arm64|rga-development' \
    "$PROJECT_DIR/config/local-debs/packages.conf" || fail "RGA development input is missing"
grep -Fq 'dma_buf_sync_end | dma_buf_sync_read' \
    "$PROJECT_DIR/tests/target/assets/rga-smoke.cpp" || fail "dma-buf read END sync is missing"
grep -Fq 'RGA_SMOKE_OK' "$PROJECT_DIR/tests/target/assets/rga-smoke.cpp" ||
    fail "RGA acceptance marker is missing"
bash -n "$PROJECT_DIR/scripts/build-rga-smoke.sh" \
    "$PROJECT_DIR/scripts/install-rga.sh" \
    "$PROJECT_DIR/tests/target/test-rga.sh"

echo "RGA local-DEB and dma-buf smoke checks passed"
