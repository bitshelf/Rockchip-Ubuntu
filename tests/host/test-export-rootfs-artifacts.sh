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

echo "Server rootfs artifact export checks passed"
