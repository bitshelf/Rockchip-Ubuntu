"""Combine actual sensor register calibration with SDK ISP39 defaults.

This is a service bring-up fixture, not a sensor/lens tuning conversion.
Run with uv run; keep generated IQ and its provenance outside Git.
"""
import copy
import hashlib
import json
import sys
from pathlib import Path

sensor_path, defaults_path, output_path = map(Path, sys.argv[1:])
sensor = json.loads(sensor_path.read_text())
defaults = json.loads(defaults_path.read_text())
for scene in defaults["main_scene"]:
    for subscene in scene["sub_scene"]:
        if "scene_isp39" not in subscene:
            raise ValueError("defaults must use the ISP39 schema")
calibration = copy.deepcopy(defaults["sensor_calib"])
# Preserve the sensor's gain conversion, exposure conversion, limits and delays.
calibration.update(copy.deepcopy(sensor["sensor_calib"]))
for timing in calibration["CISTimeSet"]["Hdr"]:
    minimum = timing.get("CISTimeRegMin")
    if isinstance(minimum, int):
        timing["CISTimeRegMin"] = {"Coeff": [minimum] * 3}
    timing.setdefault("CISTimeLinePerReg", 1)
calibration["CISTimeSet"]["Linear"].setdefault("CISTimeLinePerReg", 1)
defaults["sensor_calib"] = calibration
defaults["module_calib"] = copy.deepcopy(sensor["module_calib"])
output_path.write_text(json.dumps(defaults, indent=2) + "\n")
provenance = {
    "scope": "ISP39 service bring-up only; image quality and production IQ unqualified",
    "sensor_calibration": str(sensor_path),
    "sensor_sha256": hashlib.sha256(sensor_path.read_bytes()).hexdigest(),
    "isp39_defaults": str(defaults_path),
    "defaults_sha256": hashlib.sha256(defaults_path.read_bytes()).hexdigest(),
    "output_sha256": hashlib.sha256(output_path.read_bytes()).hexdigest(),
    "preserved": ["sensor gain conversion", "sensor exposure conversion",
                  "sensor limits", "sensor update delays", "module metadata"],
    "unsupported_scope": ["image quality", "production tuning", "HDR validation"],
}
output_path.with_name(output_path.name + ".provenance").write_text(json.dumps(provenance, indent=2) + "\n")
