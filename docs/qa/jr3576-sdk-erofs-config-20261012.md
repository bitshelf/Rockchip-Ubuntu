# JR3576 SDK EROFS configuration

The selected SDK board uses `myd_jr3576_defconfig`, the basic
`rk3576.config` fragment, and `myd_jr3576_ext.config`, in that order.
The last fragment now enables EROFS and its xattr, ACL and security-label
support as built-in options. Compressed EROFS is disabled to match the
current uncompressed rootfs image. Existing built-in OverlayFS and ext4
configuration is retained.

This change requires no kernel C source or DTS changes. EROFS is a kernel
filesystem capability; the boot configuration selects it with
`root=PARTLABEL=rootfs rootfstype=erofs`. A DTS describes hardware and does
not enable filesystem drivers.

The SDK change is carried in
`docs/patches/kernel/0005-jr3576-enable-erofs-in-board-config.patch`.
It can be reverted independently of the earlier SDK configuration changes.

Configuration validation used a separate output directory and the existing
isolated non-RT build tree, with the three selected configuration files
copied from the SDK. The original SDK `.config` and kernel build artifacts
were not replaced. The resolved configuration SHA256 is
`cf1dd26e74e55a93b42a1a2115e9db20d12af54b2569f763b3586006b1acff82`.
`scripts/check-kernel-config.sh` passed all 18 requirements in
`config/kernel/overlay-root.conf`.

Raw evidence is in the SDK workspace under
`output/ubuntu-desktop-jr-20261011/qa/sdk-erofs-config-build.log` and
`sdk-erofs-config-check.log`; the resolved configuration is
`output/ubuntu-jr3576-sdk-erofs-config/.config`.
This validates the persistent configuration, not a newly built or flashed
kernel. The existing lab kernel's real EROFS/OverlayFS boot is separate
evidence and must not be reported as a build of this SDK config commit.
