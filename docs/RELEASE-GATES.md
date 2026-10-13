# Ubuntu 26 GNOME release gates

Run `python3 scripts/check-release-gates.py candidate.json acceptance.json
--output promotion.json` after exporting the actual board test logs. Exit code
zero and `promoted: true` require all five gates; incomplete evidence produces
exit code one and a reason. A successful host fixture is not board acceptance.

The candidate uses schema `ubuntu-candidate-v1`, product
`ubuntu26-gnome`, the intended hardware `serial`, `kernel_release`, and an `artifacts` object. Required keys are
`boot`, `rootfs`, `userdata`, `uboot`, `kernel`, `initrd`, `dtb`, `modules`, and
`source-manifest`. Each file record contains a relative `path` and its
`sha256`. Keep the source manifest alongside the artifacts, recording source
commits, dirty patches, build configuration, and platform asset checksums.
Symlinks, directory escapes, missing files, and checksum changes fail.

The immutable candidate must also declare `webgpu_backend`: `vulkan-core` or
`gles-compat`. The `webgpu-hardware` target check records the matching `backend`,
`feature_level` (`core` or `compatibility`), `fallback_adapter: false`,
`render_readback: true` and `compute_values_checked: 256`. Promotion exports
this capability explicitly. A compatibility candidate cannot be promoted as
Vulkan/core, and changing the capability invalidates the candidate digest.
RK3576 has hardware GLES compatibility evidence and laboratory Vulkan/core
render, compute and canvas presentation evidence with an enabled GPU sandbox.
The final candidate still needs its own complete acceptance. The gate verifies the requested hardware WebGPU capability without
silently claiming the larger core feature set.

Acceptance uses schema `ubuntu-acceptance-v1`, the observed hardware
`serial`, matching `kernel_release`, and `candidate_sha256`: SHA256 of the
candidate JSON encoded with sorted keys and compact separators. The `image`
and `target` objects contain the required check names defined at the top of
the validator. Every check needs `status: passed`, integer `exit_code: 0`,
and a `log` file record. Target checks also need their actual `boot_id` and
`actual_hardware: true`, supported by the exported test log. Probe-only
watchdog results, software GPU fallback, package installation, and build
success cannot satisfy the corresponding hardware checks.

The `reboot` array needs at least three continuous controlled cycles. Each
records different `before_boot_id` and `after_boot_id`, `controlled: true`,
`status: passed`, the expected `kernel_sha256`, and its `log`. Target evidence
must come from a boot in this sequence. The `soak` object records the last
boot ID, `status: passed`, workloads containing `gpu`, `video`, `npu`, and
`cpu`, monotonic `heartbeat_seconds` covering at least 3600 seconds with no
gap above 90 seconds, zero `workload_errors` and `unexpected_reboots`, and
its `log`. A manually interrupted test remains incomplete.

The validator checks evidence consistency and integrity. The test runners
must collect truthful hardware observations; JSON labels alone do not
establish video decoding, reset cause, latency, or image quality.

Package-hold and dynamic-linker probes consume their producer's complete
output under `pipefail`. An early-exiting matcher can otherwise produce a
SIGPIPE and report an installed package or resolved library as missing.
`tests/host/test-package-hold-checks.sh` exercises slow, long producer output,
missing matches and producer failures. Keep failed soak runs and restart the
entire duration after correcting a test-runner error; do not append their
heartbeats to a later run or change inference thresholds to obtain a pass.

When performance qualification is explicitly deferred, a separate functional
soak may select `RKNPU_QA_MODE=functional`. This still requires all 200 inference
samples, correct classification, sufficient confidence and positive timings,
and records min/mean/max latency. It does not certify the 15 ms latency limit;
the default `latency` mode and its failed performance records remain unchanged.
Declare this scope in the acceptance report and keep it distinct from loaded
RT or NPU performance qualification.

Host verification: `python3 tests/host/test-release-gates.py` checks a
synthetic complete fixture and rejects missing, stale, altered, unrelated,
uncontrolled, and insufficient-duration evidence. Real GNOME promotion is
pending until the current candidate completes every target gate. XFCE work
follows that acceptance and requires its own product-specific gate policy.
