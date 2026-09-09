#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${PROJECT_DIR}/scripts/build-cross-example.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

for spec in 'libdrm:libdrm:deb'; do
    IFS=: read -r example source format <<<"$spec"
    output="$(CROSS_BASE_TAG=future-release \
        CROSS_OUTPUT_DIR="${tmp_dir}/output" \
        "$SCRIPT" --print-plan "$example")"
    grep -Fxq "example=${example}" <<<"$output" ||
        fail "wrong example plan: $example"
    grep -Fxq "source.package=${source}" <<<"$output" ||
        fail "wrong source package: $example"
    grep -Fxq "package.format=${format}" <<<"$output" ||
        fail "wrong package format: $example"
done

for document in CROSS-LIBDRM.md; do
    [[ -s "${PROJECT_DIR}/docs/${document}" ]] || fail "missing example document: $document"
done
grep -Fq 'dpkg-buildpackage --host-arch arm64' \
    "${PROJECT_DIR}/containers/deb-cross-example/entrypoint.sh" ||
    fail "Debian examples do not cross-build for ARM64"
libdrm_config="${PROJECT_DIR}/package/libdrm"
mapfile -t libdrm_patches <"${libdrm_config}/series"
(( ${#libdrm_patches[@]} > 0 )) || fail "libdrm patch series is empty"
for patch_name in "${libdrm_patches[@]}"; do
    [[ "$patch_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.patch$ &&
       -s "${libdrm_config}/patches/${patch_name}" ]] ||
        fail "invalid libdrm patch series entry: $patch_name"
done
grep -Eq '^\+[a-z0-9][a-z0-9.+~]*$' "${libdrm_config}/version-suffix" ||
    fail "libdrm local Debian version suffix is invalid"
grep -Fq -- '--volume "${PROJECT_DIR}:/workspace:ro"' "$SCRIPT" ||
    fail "Debian package builds cannot read repository patch policy"
grep -Fq 'patch --batch --forward' \
    "${PROJECT_DIR}/containers/deb-cross-example/entrypoint.sh" ||
    fail "Debian package builder does not apply the reviewed patch series"
if grep -REn 'drm(Set|Drop)Master|drm(Get|Auth)Magic|name = "rockchip"' \
        "${libdrm_config}/patches"; then
    fail "libdrm patch set changes global DRM selection or authentication semantics"
fi

echo "libdrm cross-build checks passed"
