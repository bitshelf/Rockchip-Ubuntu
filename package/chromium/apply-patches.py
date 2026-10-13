#!/usr/bin/env python3
"""Apply or verify an ordered Chromium patch series, including overlapping patches."""
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

source, directory = map(lambda value: Path(value).resolve(), sys.argv[1:])
names = [line.strip() for line in (directory / "series").read_text().splitlines()
         if line.strip() and not line.lstrip().startswith("#")]
patches = []
files = set()
for name in names:
    if not re.fullmatch(r"[A-Za-z0-9_.-]+\.patch", name):
        raise SystemExit("invalid Chromium patch filename")
    patch = directory / name
    patches.append(patch)
    for line in patch.read_text().splitlines():
        if line.startswith("+++ b/"):
            relative = Path(line[6:].split("\t", 1)[0])
            if relative.is_absolute() or ".." in relative.parts:
                raise SystemExit("invalid Chromium patch target")
            target = source / relative
            if not target.is_file() or target.is_symlink() or not target.resolve().is_relative_to(source):
                raise SystemExit("missing or unsafe Chromium patch target: " + str(relative))
            files.add(relative)
if not patches or not files:
    raise SystemExit("empty Chromium patch series")

def apply(tree, patch, reverse=False):
    command = ["git", "-C", str(tree), "apply"]
    if reverse:
        command.append("--reverse")
    return subprocess.run(command + [str(patch)], capture_output=True).returncode == 0

# Reconstruct a clean prefix in a disposable copy. This handles an existing
# complete series whose later patches changed the earlier patches' context,
# and validates the entire next series before changing the build source.
for count in range(len(patches), -1, -1):
    with tempfile.TemporaryDirectory(prefix="chromium-patches-") as temporary:
        tree = Path(temporary)
        for relative in files:
            (tree / relative).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source / relative, tree / relative)
        if not all(apply(tree, patch, True) for patch in reversed(patches[:count])):
            continue
        if not all(apply(tree, patch) for patch in patches):
            continue
        for relative in files:
            target = source / relative
            if target.read_bytes() != (tree / relative).read_bytes():
                shutil.copy2(tree / relative, target)
        print(f"CHROMIUM_PATCH_SERIES_OK patches={len(patches)} previous={count}")
        break
else:
    raise SystemExit("Chromium source matches neither the clean patch series nor an applied prefix")
