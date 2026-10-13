# Experimental PanVK runtime input

The ordinary desktop keeps Ubuntu Mesa. This optional package installs a
separate development Vulkan ICD; selecting it requires both `VK_DRIVER_FILES`
and `PAN_I_WANT_A_BROKEN_VULKAN_DRIVER=1`. It does not establish Vulkan
conformance or production performance. Remove `mesa-panvk-experimental` to
roll back the additional driver.

The validated source is Mesa commit
`76b9372c4e5d186f57d22d3a4f95dd1c5e04ece2`, archive SHA256
`2f8463e9b9d3565ab4661b78cbdf7d6539944ef6b89c1880ec302579a85faaee`.
Keep the official source archive outside Git. Apply
`patches/0001-panvk-skip-non-mali-render-nodes.patch` to that source.

Build on native ARM64 with Meson, Ninja, Clang 21, LLVM 21 development files,
OpenCL headers, SPIR-V tools/headers and Mesa's declared build dependencies:

```sh
CC=clang-21 CXX=clang++-21 meson setup build \
  -Dgallium-drivers= -Dvulkan-drivers=panfrost -Dplatforms=wayland,x11 \
  -Dgbm=disabled -Dglx=disabled -Degl=disabled -Dllvm=enabled \
  -Dmesa-clc=enabled -Dprecomp-compiler=enabled -Dbuild-tests=false
ninja -C build
DESTDIR=/absolute/stage meson install -C build
```

Preserve the successful native build log, compiler versions and Meson build
options with the input. Prepare this directory below `SDK_OUTPUT_DIR`:

```text
mesa-panvk/stage/
  libvulkan_panfrost.so
  LICENSE                 # upstream docs/license.rst
  SOURCE.json
  SHA256SUMS
```

`SOURCE.json` records `upstream`, `commit`, `archive_sha256`,
`release_status: "upstream-development-snapshot"`, `source_modified: true`
and the applied `patch_sha256`. `SHA256SUMS` covers the library, license and
source record. Native packaging checks these inputs and the AArch64 ELF:

```sh
./scripts/build-local-debs.sh mesa-panvk
```

The recipe packages the compiled input; it does not compile or download Mesa.
Its DEB is staged through the local-DEB manifest as
`panvk-experimental-runtime`. Desktop assembly installs and holds it when
present in `artifacts/`; Server and desktop inputs without it remain supported.
The package preserves the compiler output checksum and does not replace the
archive Mesa libraries or ICD. See [WebGPU QA](../../docs/WEBGPU-VULKAN-QA.md)
for the Chromium Vulkan/readback hardware test.
