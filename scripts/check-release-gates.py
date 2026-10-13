#!/usr/bin/env python3
"""Validate immutable artifacts and same-candidate Ubuntu acceptance evidence."""
import argparse
import hashlib
import json
import math
import re
from pathlib import Path

IMAGE_CHECKS = {"rootfs-integrity", "bootfs-integrity", "userdata-integrity",
                "kernel-config", "module-match", "boot-logos", "package-manifest"}
TARGET_CHECKS = {"gnome", "gpu-egl", "webgpu-hardware", "chromium-mpp",
                 "rknpu", "rkmpp", "rga", "rime-input", "isp-3a",
                 "audio-playback-capture", "kernel-log-allowlist",
                 "pstore-panic", "watchdog-expiry", "rt-cyclictest"}
SERVER_TARGET_CHECKS = {"firstboot", "network", "gpu-egl", "rknpu", "rkmpp",
                        "rga", "isp-3a", "audio-playback-capture",
                        "kernel-log-allowlist", "pstore-panic",
                        "watchdog-expiry", "rt-cyclictest"}
PRODUCT_POLICIES = {"ubuntu26-gnome": TARGET_CHECKS,
                    "ubuntu26-server": SERVER_TARGET_CHECKS}
ARTIFACTS = {"boot", "rootfs", "userdata", "uboot", "kernel",
             "initrd", "dtb", "modules", "source-manifest"}
UUID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\Z")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def file_record(record, base):
    require(isinstance(record, dict), "invalid file record")
    name = record.get("path", "")
    relative = Path(name)
    require(name and not relative.is_absolute() and ".." not in relative.parts,
            "file path must stay inside its evidence directory")
    path = base / relative
    require(path.resolve().is_relative_to(base.resolve()), "file escapes evidence directory")
    require(path.is_file() and not path.is_symlink() and path.stat().st_size > 0,
            f"missing or invalid evidence file: {name}")
    require(digest(path) == record.get("sha256"), f"checksum mismatch: {name}")


def number(value):
    return type(value) in (int, float) and math.isfinite(value)


def validate(candidate, evidence, candidate_base, evidence_base):
    require(candidate.get("schema") == "ubuntu-candidate-v1", "candidate schema")
    product = candidate.get("product")
    require(product in PRODUCT_POLICIES, "unsupported candidate product")
    records = candidate.get("artifacts", {})
    require(ARTIFACTS <= records.keys(), "required candidate artifacts missing")
    for record in records.values():
        file_record(record, candidate_base)
    identity = hashlib.sha256(json.dumps(candidate, sort_keys=True,
                                        separators=(",", ":")).encode()).hexdigest()
    require(evidence.get("schema") == "ubuntu-acceptance-v1", "evidence schema")
    require(evidence.get("candidate_sha256") == identity, "evidence belongs to another candidate")
    require(isinstance(candidate.get("serial"), str) and bool(candidate["serial"].strip()),
            "candidate must identify its target serial")
    require(evidence.get("serial") == candidate["serial"], "wrong target serial")
    require(evidence.get("kernel_release") == candidate.get("kernel_release")
            and bool(candidate.get("kernel_release")), "kernel mismatch")
    webgpu_backend = candidate.get("webgpu_backend")
    if product == "ubuntu26-gnome":
        require(webgpu_backend in {"vulkan-core", "gles-compat"},
                "candidate must declare its WebGPU hardware capability")
    else:
        require(webgpu_backend is None, "Server policy does not certify desktop WebGPU")
    for group, required in (("image", IMAGE_CHECKS), ("target", PRODUCT_POLICIES[product])):
        checks = evidence.get(group, {})
        require(required <= checks.keys(), f"missing {group} checks: {sorted(required - checks.keys())}")
        for name, check in checks.items():
            require(check.get("status") == "passed" and type(check.get("exit_code")) is int
                    and check["exit_code"] == 0, f"failed/deferred check: {group}/{name}")
            file_record(check.get("log"), evidence_base)
            if group == "target":
                require(UUID.fullmatch(check.get("boot_id", "")), f"missing boot ID: {name}")
                require(check.get("actual_hardware") is True, f"hardware proof absent: {name}")
    expected_level = None
    if product == "ubuntu26-gnome":
        webgpu = evidence["target"]["webgpu-hardware"]
        require(webgpu.get("backend") == webgpu_backend, "WebGPU backend differs from candidate")
        expected_level = "core" if webgpu_backend == "vulkan-core" else "compatibility"
        require(webgpu.get("feature_level") == expected_level
                and webgpu.get("fallback_adapter") is False
                and webgpu.get("render_readback") is True
                and webgpu.get("compute_values_checked") == 256,
                "WebGPU hardware render/compute or capability proof missing")
    reboot = evidence.get("reboot", [])
    require(len(reboot) >= 3, "at least three controlled reboots required")
    observed = set()
    previous = None
    for cycle in reboot:
        before, after = cycle.get("before_boot_id", ""), cycle.get("after_boot_id", "")
        require(UUID.fullmatch(before) and UUID.fullmatch(after) and before != after,
                "reboot needs two different boot IDs")
        require(after not in observed, "reboot evidence reused")
        require(previous is None or before == previous, "reboots are not a continuous sequence")
        require(cycle.get("controlled") is True and cycle.get("status") == "passed",
                "uncontrolled/failed reboot")
        require(cycle.get("kernel_sha256") == records["kernel"]["sha256"], "reboot kernel changed")
        file_record(cycle.get("log"), evidence_base)
        observed.update((before, after))
        previous = after
    require(all(check["boot_id"] in observed for check in evidence["target"].values()),
            "target evidence boot not in reboot sequence")
    soak = evidence.get("soak", {})
    require(soak.get("boot_id") == previous and soak.get("status") == "passed",
            "soak must pass on the last tested boot")
    require({"gpu", "video", "npu", "cpu"} <= set(soak.get("workloads", [])),
            "mixed soak workload missing")
    ticks = soak.get("heartbeat_seconds", [])
    require(len(ticks) >= 2 and all(number(t) for t in ticks), "invalid soak heartbeats")
    require(ticks[-1] - ticks[0] >= 3600, "soak shorter than one hour")
    require(all(0 < b-a <= 90 for a, b in zip(ticks, ticks[1:])), "soak heartbeat gap")
    require(all(type(soak.get(key)) is int and soak[key] == 0
                for key in ("workload_errors", "unexpected_reboots")),
            "soak errors or unexpected resets")
    file_record(soak.get("log"), evidence_base)
    return {"schema": "ubuntu-promotion-v1", "candidate_sha256": identity,
            "serial": evidence["serial"], "product": product, "promoted": True,
            "webgpu_backend": webgpu_backend, "webgpu_feature_level": expected_level,
            "gates": {name: "passed" for name in ("image", "target", "reboot", "soak", "promotion")}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    require(args.output.resolve() not in {args.candidate.resolve(), args.evidence.resolve()},
            "output must not overwrite an input")
    try:
        result = validate(json.loads(args.candidate.read_text()), json.loads(args.evidence.read_text()),
                          args.candidate.parent, args.evidence.parent)
    except (ValueError, OSError, KeyError, TypeError, AttributeError) as error:
        result = {"schema": "ubuntu-promotion-v1", "promoted": False, "failure": str(error)}
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))
    return 0 if result["promoted"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
