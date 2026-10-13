#!/usr/bin/env python3
"""Controlled DUT diagnostics. Probe success never certifies a reset."""
import argparse
import array
import fcntl
import json
import os
from pathlib import Path
import shutil
import struct
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument("action", choices=("probe", "panic", "watchdog-reset", "verify-panic", "verify-watchdog"))
parser.add_argument("--evidence", type=Path)
parser.add_argument("--confirm-reset", action="store_true")
parser.add_argument("--timeout", type=int, default=15)
args = parser.parse_args()
if os.geteuid() != 0:
    raise SystemExit("run as root on the DUT")
compatible = Path("/proc/device-tree/compatible").read_bytes().split(b"\0")
if not any(value.startswith(b"rockchip,") for value in compatible):
    raise SystemExit("reset QA requires an identified Rockchip DUT")
boot_id = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
if args.action.startswith("verify-"):
    if not args.evidence:
        parser.error("--evidence is required")
    record = json.loads((args.evidence/"armed.json").read_text())
    expected = "panic" if args.action == "verify-panic" else "watchdog-reset"
    assert record["action"] == expected, "reset action does not match evidence"
    assert boot_id != record["boot_id"], "DUT has not rebooted"
    matches = []
    panic_matches = []
    for label, root in (("live", Path("/sys/fs/pstore")), ("archive", Path("/var/lib/systemd/pstore"))):
        for path in root.rglob("*"):
            if path.is_file() and record["marker"].encode() in path.read_bytes():
                destination = args.evidence/"after-pstore"/label/path.relative_to(root)
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, destination)
                matches.append(str(path))
                if b"Kernel panic - not syncing: sysrq triggered crash" in path.read_bytes():
                    panic_matches.append(str(path))
    if expected == "panic":
        assert panic_matches, "matching SysRq panic record is absent from pstore and its archive"
    result = {"action": expected, "boot_id_before": record["boot_id"], "boot_id_after": boot_id,
              "marker": record["marker"], "pstore_matches": matches, "panic_matches": panic_matches,
              "reset_observed": True, "passed": expected == "panic",
              "watchdog_requires_host_timing_and_serial_reset_reason": expected != "panic"}
    (args.evidence/"result.json").write_text(json.dumps(result, indent=2)+"\n")
    print(json.dumps(result))
    # Watchdog evidence still needs host timing and serial reset attribution.
    # A partial verification must not look like a passed target gate.
    raise SystemExit(0 if result["passed"] else 2)
if args.action != "probe" and (not args.confirm_reset or not args.evidence):
    parser.error("controlled reset requires --confirm-reset and --evidence")
if not 5 <= args.timeout <= 60:
    parser.error("timeout must be 5..60 seconds")
record = {"action": args.action, "boot_id": boot_id, "kernel": os.uname().release,
          "marker": "UBUNTU_DIAGNOSTICS_"+uuid.uuid4().hex, "armed_unix": time.time()}
if args.evidence:
    args.evidence.mkdir(parents=True, exist_ok=False)
    for label, root in (("live", Path("/sys/fs/pstore")), ("archive", Path("/var/lib/systemd/pstore"))):
        if root.is_dir():
            shutil.copytree(root, args.evidence/"before-pstore"/label)
if args.action == "panic":
    assert Path("/proc/sys/kernel/sysrq").exists(), "SysRq is unavailable"
    Path("/proc/sys/kernel/panic").write_text(str(args.timeout))
    (args.evidence/"armed.json").write_text(json.dumps(record, indent=2)+"\n")
    with open("/dev/kmsg", "w") as log:
        log.write("<2>"+record["marker"]+" controlled SysRq panic\n")
    os.sync()
    print(json.dumps(record), flush=True)
    Path("/proc/sysrq-trigger").write_text("c")
    raise SystemExit("SysRq panic did not reset the DUT")
# GETSUPPORT is the stable watchdog ABI; it also works without WATCHDOG_SYSFS.
# Opening the device starts it, so only proceed when magic-close can stop it.
config = Path("/proc/config.gz")
import gzip
config_text = gzip.decompress(config.read_bytes()).decode() if config.exists() else Path("/boot/config-"+os.uname().release).read_text()
assert "CONFIG_WATCHDOG_NOWAYOUT=y" not in config_text, "nowayout watchdog cannot be safely probed"
fd = os.open("/dev/watchdog0", os.O_WRONLY | os.O_CLOEXEC)
try:
    info = bytearray(40)
    fcntl.ioctl(fd, 0x80285700, info, True)  # WDIOC_GETSUPPORT
    options, firmware, identity = struct.unpack("II32s", info)
    identity = identity.split(b"\0", 1)[0].decode()
    assert options & 0x100, "watchdog lacks magic-close support"
    assert identity == "Synopsys DesignWare Watchdog", "unexpected watchdog identity"
    value = array.array("i", [0])
    fcntl.ioctl(fd, 0x80045707, value, True)  # WDIOC_GETTIMEOUT
    record.update(identity=identity, options=options, timeout_seconds=value[0])
    if args.action == "probe":
        record["reset_tested"] = False
        print(json.dumps(record), flush=True)
    else:
        value[0] = args.timeout
        fcntl.ioctl(fd, 0xC0045706, value, True)  # WDIOC_SETTIMEOUT
        record["timeout_seconds"] = value[0]
        (args.evidence/"armed.json").write_text(json.dumps(record, indent=2)+"\n")
        with open("/dev/kmsg", "w") as log:
            log.write("<2>"+record["marker"]+" controlled watchdog expiry\n")
        os.sync()
        fcntl.ioctl(fd, 0x80045705, value, True)  # WDIOC_KEEPALIVE
        print(json.dumps(record), flush=True)
        time.sleep(2*value[0]+10)
        raise RuntimeError("watchdog did not reset within the expected timeout")
finally:
    os.write(fd, b"V")
    os.close(fd)
