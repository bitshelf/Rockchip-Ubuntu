#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

asset_dir="$tmp_dir/platform-assets/test"
package_root="$tmp_dir/package"
install -d -m 0755 "$asset_dir/debs" "$package_root/DEBIAN"
cat >"$package_root/DEBIAN/control" <<'EOF'
Package: libmali-test
Version: 1.0-1
Architecture: arm64
Maintainer: Ubuntu image CI <root@localhost>
Description: local DEB resolver fixture
EOF
dpkg-deb --build "$package_root" "$asset_dir/debs/libmali-test_1.0-1_arm64.deb" >/dev/null
printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    'libmali/libmali-test_1.0-1_arm64.deb' \
    'libmali-test_1.0-1_arm64.deb' 'libmali-test' '1.0-1' 'arm64' \
    'gpu-runtime' >"$asset_dir/local-deb-manifest.tsv"

resolved="$("$PROJECT_DIR/scripts/find-local-deb.sh" "$asset_dir" gpu-runtime)"
[[ "$resolved" == "$asset_dir/debs/libmali-test_1.0-1_arm64.deb" ]] ||
    fail "gpu-runtime did not resolve the manifest package"

printf '%s\n' "$(<"$asset_dir/local-deb-manifest.tsv")" \
    >>"$asset_dir/local-deb-manifest.tsv"
if "$PROJECT_DIR/scripts/find-local-deb.sh" "$asset_dir" gpu-runtime \
        >"$tmp_dir/duplicate.out" 2>&1; then
    fail "duplicate gpu-runtime packages were accepted"
fi

grep -Fq 'libmali/libmali-*_arm64.deb|arm64|gpu-runtime' \
    "$PROJECT_DIR/config/local-debs/packages.conf" ||
    fail "libmali is not part of the local DEB input contract"
grep -Fq 'SUBSYSTEM=="dma_heap", MODE="0666"' \
    "$PROJECT_DIR/package/libmali/60-dma-heap.rules" ||
    fail "dma-buf heap access policy is missing"
bash -n "$PROJECT_DIR/scripts/find-local-deb.sh" \
    "$PROJECT_DIR/scripts/install-libmali.sh" \
    "$PROJECT_DIR/tests/target/test-gpu-headless-egl.sh"

echo "libmali local-DEB and headless EGL integration checks passed"
