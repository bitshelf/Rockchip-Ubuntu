#!/usr/bin/env python3
"""Verify overlapping patches, partial reuse, idempotence and failure isolation."""
import difflib
from pathlib import Path
import subprocess
import sys
import tempfile

helper = Path(__file__).resolve().parents[2] / "package/chromium/apply-patches.py"
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    source, patches = root / "src", root / "patches"
    source.mkdir(); patches.mkdir()
    versions = ["one\ntwo\nthree\n", "ONE\ntwo\nthree\n", "ONE\nTWO\nthree\n"]
    for i in (1, 2):
        (patches / f"{i}.patch").write_text("".join(difflib.unified_diff(
            versions[i-1].splitlines(True), versions[i].splitlines(True),
            fromfile="a/test.cc", tofile="b/test.cc")))
    (patches / "series").write_text("1.patch\n2.patch\n")
    for initial in versions:
        target = source / "test.cc"
        target.write_text(initial)
        subprocess.run([sys.executable, str(helper), str(source), str(patches)], check=True)
        assert target.read_text() == versions[-1]
        before = target.stat().st_mtime_ns
        subprocess.run([sys.executable, str(helper), str(source), str(patches)], check=True)
        assert target.stat().st_mtime_ns == before, "already patched sources were rewritten"
    target.write_text("incompatible source\n")
    rejected = subprocess.run([sys.executable, str(helper), str(source), str(patches)], capture_output=True)
    assert rejected.returncode and target.read_text() == "incompatible source\n"
    (patches / "2.patch").write_text("--- a/test.cc\n+++ b/../escaped.cc\n")
    rejected = subprocess.run([sys.executable, str(helper), str(source), str(patches)], capture_output=True)
    assert rejected.returncode and not (root / "escaped.cc").exists()
print("CHROMIUM_ORDERED_PATCH_REUSE_OK")
