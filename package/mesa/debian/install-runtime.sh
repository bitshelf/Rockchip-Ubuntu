#!/bin/bash
set -Eeuo pipefail
inputs="${SDK_OUTPUT_DIR:?}/mesa-panvk/stage"
destination="${1:?}"
test -s "$inputs/libvulkan_panfrost.so"
test -s "$inputs/SOURCE.json"
test -s "$inputs/LICENSE"
(cd "$inputs" && sha256sum -c SHA256SUMS)
readelf -h "$inputs/libvulkan_panfrost.so" | grep -Eq 'Machine:[[:space:]]+AArch64$'
python3 - "$inputs/SOURCE.json" <<'PY'
import json,re,sys
d=json.load(open(sys.argv[1]))
assert d['release_status']=='upstream-development-snapshot'
assert d['commit']=='76b9372c4e5d186f57d22d3a4f95dd1c5e04ece2'
assert re.fullmatch('[a-f0-9]{64}',d['archive_sha256'])
assert re.fullmatch('[a-f0-9]{64}',d['patch_sha256'])
PY
install -D -m 0644 "$inputs/libvulkan_panfrost.so" \
    "$destination/usr/lib/aarch64-linux-gnu/libvulkan_panfrost_experimental.so"
install -D -m 0644 "$inputs/SOURCE.json" "$destination/usr/share/doc/mesa-panvk-experimental/SOURCE.json"
install -D -m 0644 "$inputs/LICENSE" "$destination/usr/share/doc/mesa-panvk-experimental/LICENSE"
install -d "$destination/usr/share/vulkan/icd.d"
cat >"$destination/usr/share/vulkan/icd.d/panfrost_icd.aarch64.json" <<'JSON'
{"ICD":{"api_version":"1.4.363","library_arch":"64","library_path":"/usr/lib/aarch64-linux-gnu/libvulkan_panfrost_experimental.so"},"file_format_version":"1.0.1"}
JSON
