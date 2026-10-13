#!/usr/bin/env bash
set -Eeuo pipefail
test -x tests/target/test-webgpu-vulkan.sh
bash -n tests/target/test-webgpu-vulkan.sh
grep -Fq 'WEBGPU_VULKAN_HARDWARE_OK' tests/target/test-webgpu-vulkan.sh
grep -Fq 'readback' tests/target/assets/webgpu-render.html
echo "WebGPU/Vulkan QA contract passed"
