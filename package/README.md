# Package components

Each application or library owns one directory under `package/<component>/`.
Keep reviewed patches, package metadata, Debian recipes and component runtime
files together. SDK source, vendor binaries and generated DEBs remain external
platform inputs or build outputs; do not copy them here.

Layout conventions:

- `debian/`: native Debian packaging recipes, where provided.
- `patches/`, `series`, `version-suffix`: reviewed source changes and versions.
- `src/`: repository-owned application code (currently `rockchip-test`).
- `runtime/`: integration files when a component also carries a source recipe
  (currently the libv4l-rkmpp virtual-endpoint service).
- Existing component service/udev trees retain their relative install layout.

`scripts/build-local-debs.sh` and `config/local-debs/*.conf` remain the common
build/staging/install interface. Top-level `scripts/` orchestrates builds;
`examples/` contains invocations/examples, not component patch repositories.
`tests/` keeps QA and fixtures; `docs/` keeps usage and porting notes.

`config/` owns image definitions, kernel/boot/storage policy and the selection
of packages for products. It does not own application patches or Debian recipes.
Desktop session customization stays in `config/customization/` because it
configures the image's session rather than building a package.

Migration: former `config/lib*`, `config/{adb,isp,mpp,update-engine,rockchip-test}`
and `packaging/` components are now here. `config/v4l` belongs to
`libv4l-rkmpp/runtime`; Chromium patches belong to `chromium/patches`.
No compatibility symlinks are provided; use the updated manifests and scripts.

Kernel and U-Boot source patches remain under `docs/patches/kernel/` and
`docs/patches/u-boot/`. All userspace patches belong to their component
`package/<component>/patches/`, including Chromium and Mesa.
