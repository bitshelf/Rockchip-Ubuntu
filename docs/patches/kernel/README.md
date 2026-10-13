# JR3576 ISP runtime compatibility

Apply `0001-rkisp-support-legacy-two-buffer-mesh-query.patch` to the matching
JR3576 Linux 6.1 tree before building the Server kernel. The Ubuntu repository
carries this patch; the SDK checkout is not modified.

The supplied camera-engine-rkaiq 6.30.4 ARM64 binary issues
`RKISP_CMD_GET_MESHBUF_INFO` with a 28-byte payload (two buffer descriptors).
This kernel uses a 36-byte payload (three descriptors), so the ioctl number
changes and the old request returns ENOTTY. RKAIQ then dereferences an absent
CAC LUT buffer during prepare. Board strace and GDB confirm both failures.

The patch adds the old request as a separate compatibility operation, copies
its input fields into the current descriptor, and returns its first two
buffers. The current operation and allocation policy remain unchanged. The
32-bit compatibility dispatcher accepts the old operation too; only ARM64
userspace is exercised in this board run.

Validate by starting the real OV13855 RKAIQ service and streaming frames with
its realtime statistics thread active. Image quality is outside this test.
