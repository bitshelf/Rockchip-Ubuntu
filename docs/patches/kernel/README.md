# Rockchip kernel compatibility patches

Apply `0001-rkisp-support-legacy-two-buffer-mesh-query.patch` to the matching
vendor Linux 6.1 tree with the affected RKISP ABI before building the Server kernel. The Ubuntu repository
carries this patch; the SDK checkout is not modified.

The supplied camera-engine-rkaiq 6.30.4 ARM64 binary issues
`RKISP_CMD_GET_MESHBUF_INFO` with a 28-byte payload (two buffer descriptors).
This kernel uses a 36-byte payload (three descriptors), so the ioctl number
changes and the old request returns ENOTTY. RKAIQ then dereferences an absent
CAC LUT buffer during prepare. Use target strace and GDB to confirm this mismatch before applying it.

The patch adds the old request as a separate compatibility operation, copies
its input fields into the current descriptor, and returns its first two
buffers. The current operation and allocation policy remain unchanged. The
32-bit compatibility dispatcher accepts the old operation too; ARM64 and compat userspace require separate target validation.

Validate by starting the real sensor-specific RKAIQ service and streaming frames with
its realtime statistics thread active. Image quality is outside this test.

## EROFS configuration

Use `config/kernel/overlay-root.conf` as a configuration fragment in the external
SDK kernel build. Validate the resolved kernel config with
`scripts/check-kernel-config.sh`; EROFS must be built in before switch_root.
No product-specific defconfig or device-tree source patch is required for EROFS.
Base DTBs, board wiring, modules and the compiled kernel remain external assets.
