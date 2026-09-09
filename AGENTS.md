# Ubuntu repository rules

- Its supported products are `server`, `desktop` (GNOME), and
  `desktop-xfce` for Rockchip arm64.
- Make every source change inside this repository. Do not modify SDK
  repositories as part of an Ubuntu feature; carry reviewed SDK changes as
  patches and porting documentation here.
- Build root filesystems on a non-containerized Debian or Ubuntu host. Native
  ARM64 is the primary development path; keep the x86 QEMU path supported.
- Treat `BUILD_OUTPUT_DIR` as reproducible working output (`build/` by default
  on x86) and `artifacts/` as published output. Native ARM64 and its Forgejo
  runner must use the same output directory. Never overwrite
  `debian/linaro-rootfs.img` or another SDK image.
- Keep SDK products and lab inputs out of Git: kernel images, base DTBs, kernel
  modules, firmware DEBs, vendor blobs, and credentials. Move them through the
  platform-asset interface and verify their SHA256 manifests.
- A feature is not complete without focused QA, documentation, configuration,
  and machine-readable evidence. Package presence alone is not hardware proof.
- Implement one reversible feature at a time. Fold old follow-up fixes into
  the feature being migrated instead of reproducing a chain of fix commits.
- Build local runtime packages through `scripts/build-local-debs.sh`; extend
  the local-DEB build, staging and install manifests instead of adding a set
  of top-level scripts for each package.
- Stage each completed feature for review. Do not create a commit until the
  user explicitly approves and asks for it.
