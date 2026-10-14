#!/usr/bin/env python3
"""Exercise fail-closed candidate binding, reboot continuity and soak limits."""
import copy
import hashlib
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[2] / "scripts/check-release-gates.py"
SPEC = importlib.util.spec_from_file_location("gates", SOURCE)
gates = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gates)


class GatesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        (self.base / "fixture").write_bytes(b"synthetic gate fixture; never hardware evidence\n")
        record = {"path": "fixture", "sha256": gates.digest(self.base / "fixture")}
        self.candidate = {"schema": "ubuntu-candidate-v1", "product": "ubuntu26-gnome",
                          "webgpu_backend": "gles-compat", "serial": "fixture-board",
                          "kernel_release": "6.1-test",
                          "artifacts": {name: copy.deepcopy(record) for name in gates.ARTIFACTS}}
        identity = hashlib.sha256(json.dumps(self.candidate, sort_keys=True,
                                            separators=(",", ":")).encode()).hexdigest()
        ids = [f"00000000-0000-0000-0000-{i:012x}" for i in range(4)]
        check = {"status": "passed", "exit_code": 0, "log": record,
                 "boot_id": ids[-1], "actual_hardware": True}
        self.evidence = {"schema": "ubuntu-acceptance-v1", "candidate_sha256": identity,
                         "serial": "fixture-board", "kernel_release": self.candidate["kernel_release"],
                         "image": {n: copy.deepcopy(check) for n in gates.IMAGE_CHECKS},
                         "target": {n: copy.deepcopy(check) for n in gates.TARGET_CHECKS},
                         "reboot": [{"before_boot_id": a, "after_boot_id": b, "controlled": True,
                                     "status": "passed", "kernel_sha256": record["sha256"], "log": record}
                                    for a, b in zip(ids, ids[1:])],
                         "soak": {"boot_id": ids[-1], "status": "passed",
                                  "workloads": ["gpu", "video", "npu", "cpu"],
                                  "heartbeat_seconds": list(range(0, 3601, 60)),
                                  "workload_errors": 0, "unexpected_reboots": 0, "log": record}}
        self.evidence["target"]["webgpu-hardware"].update(
            backend="gles-compat", feature_level="compatibility", fallback_adapter=False,
            render_readback=True, compute_values_checked=256)

    def validate(self):
        return gates.validate(self.candidate, self.evidence, self.base, self.base)

    def test_complete_fixture(self):
        self.assertTrue(self.validate()["promoted"])

    def server_fixture(self):
        self.candidate["product"] = "ubuntu26-server"
        self.candidate.pop("webgpu_backend")
        check = self.evidence["target"]["gpu-egl"]
        self.evidence["target"] = {name: copy.deepcopy(check)
                                  for name in gates.SERVER_TARGET_CHECKS}
        self.evidence["candidate_sha256"] = hashlib.sha256(json.dumps(
            self.candidate, sort_keys=True, separators=(",", ":")).encode()).hexdigest()

    def test_server_has_its_own_policy(self):
        self.server_fixture()
        result = self.validate()
        self.assertTrue(result["promoted"])
        self.assertEqual(result["product"], "ubuntu26-server")
        self.assertIsNone(result["webgpu_feature_level"])
        self.evidence["target"].pop("network")
        with self.assertRaises(ValueError):
            self.validate()

    def test_server_cannot_claim_desktop_capability(self):
        self.server_fixture()
        self.candidate["webgpu_backend"] = "gles-compat"
        self.evidence["candidate_sha256"] = hashlib.sha256(json.dumps(
            self.candidate, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        with self.assertRaises(ValueError):
            self.validate()

    def test_product_change_cannot_reuse_another_profile(self):
        self.server_fixture()
        self.candidate["product"] = "ubuntu26-gnome"
        self.candidate["webgpu_backend"] = "gles-compat"
        self.evidence["candidate_sha256"] = hashlib.sha256(json.dumps(
            self.candidate, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        with self.assertRaises(ValueError):
            self.validate()

    def test_xfce_requires_physical_xserver_evidence(self):
        self.candidate["product"] = "ubuntu26-xfce"
        self.evidence["candidate_sha256"] = hashlib.sha256(json.dumps(
            self.candidate, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        with self.assertRaises(ValueError):
            self.validate()
        self.evidence["target"]["xfce-xserver"] = self.evidence["target"].pop("gnome")
        self.assertEqual(self.validate()["product"], "ubuntu26-xfce")
        self.evidence["target"]["xfce-xserver"]["actual_hardware"] = False
        with self.assertRaises(ValueError):
            self.validate()

    def test_target_identity_comes_from_candidate(self):
        self.candidate["serial"] = "replacement-board"
        self.evidence["serial"] = "replacement-board"
        self.evidence["candidate_sha256"] = hashlib.sha256(json.dumps(
            self.candidate, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        self.assertTrue(self.validate()["promoted"])
        self.candidate["serial"] = ""
        self.evidence["serial"] = ""
        self.evidence["candidate_sha256"] = hashlib.sha256(json.dumps(
            self.candidate, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        with self.assertRaises(ValueError):
            self.validate()

    def test_core_capability_requires_matching_evidence(self):
        self.candidate["webgpu_backend"] = "vulkan-core"
        self.evidence["candidate_sha256"] = hashlib.sha256(json.dumps(
            self.candidate, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        with self.assertRaises(ValueError):
            self.validate()
        self.evidence["target"]["webgpu-hardware"].update(
            backend="vulkan-core", feature_level="core")
        self.assertEqual(self.validate()["webgpu_feature_level"], "core")
        self.candidate.pop("webgpu_backend")
        with self.assertRaises(ValueError):
            self.validate()

    def test_reject_incomplete_or_unrelated_evidence(self):
        mutations = [
            lambda e: e.update(serial="another-fixture-board"),
            lambda e: e.update(candidate_sha256="0" * 64),
            lambda e: e["target"].pop("watchdog-expiry"),
            lambda e: e["target"]["chromium-mpp"].update(actual_hardware=False),
            lambda e: e["target"]["webgpu-hardware"].update(status="deferred"),
            lambda e: e["target"]["webgpu-hardware"].update(backend="vulkan-core"),
            lambda e: e["target"]["webgpu-hardware"].update(feature_level="core"),
            lambda e: e["target"]["webgpu-hardware"].update(fallback_adapter=True),
            lambda e: e["target"]["webgpu-hardware"].update(compute_values_checked=0),
            lambda e: e["target"]["gpu-egl"].update(exit_code=True),
            lambda e: e["target"]["isp-3a"].update(boot_id="old boot"),
            lambda e: e["reboot"].pop(),
            lambda e: e["reboot"][1].update(controlled=False),
            lambda e: e["reboot"][1].update(before_boot_id=e["reboot"][0]["before_boot_id"]),
            lambda e: e["reboot"][2].update(after_boot_id=e["reboot"][0]["after_boot_id"]),
            lambda e: e["soak"].update(heartbeat_seconds=[0, 3600]),
            lambda e: e["soak"].update(heartbeat_seconds=list(range(0, 1801, 60))),
            lambda e: e["soak"].update(heartbeat_seconds=[float("nan"), 3600]),
            lambda e: e["soak"].update(unexpected_reboots=1),
            lambda e: e["soak"].update(workload_errors=False),
            lambda e: e["soak"].update(workloads=["cpu"]),
        ]
        original = copy.deepcopy(self.evidence)
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                self.evidence = copy.deepcopy(original)
                mutation(self.evidence)
                with self.assertRaises(ValueError):
                    self.validate()

    def test_reject_changed_or_escaped_files(self):
        (self.base / "fixture").write_text("changed")
        with self.assertRaises(ValueError):
            self.validate()
        for name in ("../outside", "/etc/passwd"):
            with self.assertRaises(ValueError):
                gates.file_record({"path": name, "sha256": "0" * 64}, self.base)
        (self.base / "link").symlink_to(self.base / "fixture")
        with self.assertRaises(ValueError):
            gates.file_record({"path": "link", "sha256": gates.digest(self.base / "fixture")}, self.base)

    def test_malformed_input_replaces_stale_promotion(self):
        candidate = self.base / "candidate.json"
        evidence = self.base / "evidence.json"
        output = self.base / "promotion.json"
        candidate.write_text(json.dumps(self.candidate))
        evidence.write_text("[]")
        output.write_text('{"promoted": true}')
        result = subprocess.run([sys.executable, str(SOURCE), str(candidate), str(evidence),
                                 "--output", str(output)], capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(json.loads(output.read_text())["promoted"])


if __name__ == "__main__":
    unittest.main()
