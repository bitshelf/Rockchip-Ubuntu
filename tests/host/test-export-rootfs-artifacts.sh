#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

images="$tmp_dir/images"
prefix="$images/ubuntu-test-server-arm64"
install -d -m 0755 "$images"
printf 'rootfs fixture\n' >"${prefix}.rootfs.tar.gz"
for suffix in manifest filelist build-info qa.json; do
    printf '%s fixture\n' "$suffix" >"${prefix}.${suffix}"
done
(
    cd "$images"
    sha256sum "$(basename "${prefix}.rootfs.tar.gz")" \
        >"$(basename "${prefix}.rootfs.tar.gz.sha256")"
)

output="$tmp_dir/github-output"
GITHUB_OUTPUT="$output" "$PROJECT_DIR/scripts/export-rootfs-artifacts.sh" "$images"
grep -Fxq 'name=ubuntu-test-server-arm64' "$output" ||
    fail "artifact name output is missing"
grep -Fxq "${prefix}.rootfs.tar.gz" "$output" ||
    fail "rootfs path output is missing"
grep -Fxq "${prefix}.qa.json" "$output" || fail "QA path output is missing"

printf 'corrupt\n' >>"${prefix}.rootfs.tar.gz"
if GITHUB_OUTPUT="$output" \
        "$PROJECT_DIR/scripts/export-rootfs-artifacts.sh" "$images" \
        >/dev/null 2>&1; then
    fail "corrupt rootfs passed artifact export"
fi

desktop="$images/ubuntu-test-desktop-arm64"
for suffix in rootfs.tar.gz manifest filelist build-info qa.json; do
    printf 'desktop %s fixture\n' "$suffix" >"${desktop}.${suffix}"
done
for image in "${desktop}.rootfs.tar.gz" "${desktop}.rootfs.erofs.img" "$images/boot-test.img" "$images/userdata-test.img"; do
    [[ -f "$image" ]] || printf 'filesystem fixture\n' >"$image"
    (cd "$images"; sha256sum "$(basename "$image")" >"$(basename "$image").sha256")
done
ROOTFS_VARIANT=desktop ROOTFS_INCLUDE_FILESYSTEM_IMAGES=yes GITHUB_OUTPUT="$output" \
    "$PROJECT_DIR/scripts/export-rootfs-artifacts.sh" "$images"
grep -Fxq "${desktop}.rootfs.erofs.img" "$output" || fail 'EROFS missing from desktop export'
grep -Fxq "$images/boot-test.img" "$output" || fail 'boot missing from desktop export'
grep -Fxq "$images/userdata-test.img" "$output" || fail 'userdata missing from desktop export'
xfce="$images/ubuntu-test-desktop-xfce-arm64"
for suffix in rootfs.tar.gz manifest filelist build-info qa.json rootfs.erofs.img; do
    printf 'XFCE fixture\n' >"${xfce}.${suffix}"
done
for image in "${xfce}.rootfs.tar.gz" "${xfce}.rootfs.erofs.img"; do
    (cd "$images"; sha256sum "$(basename "$image")" >"$(basename "$image").sha256")
done
ROOTFS_VARIANT=desktop-xfce ROOTFS_INCLUDE_FILESYSTEM_IMAGES=yes GITHUB_OUTPUT="$output" \
    "$PROJECT_DIR/scripts/export-rootfs-artifacts.sh" "$images"
grep -Fxq "${xfce}.rootfs.erofs.img" "$output" || fail 'XFCE export selected another desktop'
printf 'corrupt\n' >>"$images/boot-test.img"
if ROOTFS_VARIANT=desktop ROOTFS_INCLUDE_FILESYSTEM_IMAGES=yes \
        "$PROJECT_DIR/scripts/export-rootfs-artifacts.sh" "$images" >/dev/null 2>&1; then
    fail 'corrupt boot image passed desktop export'
fi
echo "Server/Desktop rootfs and filesystem artifact export checks passed"
