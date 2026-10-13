#!/usr/bin/env python3
"""Fetch a pinned GNOME release and reject unsafe ZIP members."""
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import stat
import urllib.request
import zipfile

URL = "https://extensions.gnome.org/download-extension/kimpanel@kde.org.shell-extension.zip?version_tag=75158"
SHA256 = "7a12cddb91964e3aaf207f794ede485f581567fce5bbae0370399159ccddc31a"
with urllib.request.urlopen(URL, timeout=60) as response:
    archive = response.read(1024 * 1024)
assert hashlib.sha256(archive).hexdigest() == SHA256, "Kimpanel source checksum mismatch"
root = Path("extension")
root.mkdir()
with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
    for entry in bundle.infolist():
        path = PurePosixPath(entry.filename)
        assert not path.is_absolute() and ".." not in path.parts, "unsafe ZIP path"
        assert not stat.S_ISLNK(entry.external_attr >> 16), "ZIP symlink is not allowed"
        assert entry.file_size < 1024 * 1024, "oversized ZIP member"
        destination = root.joinpath(*path.parts)
        if entry.is_dir():
            destination.mkdir(parents=True, exist_ok=True)
        else:
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(bundle.read(entry))
            destination.chmod(0o644)
metadata = json.loads((root / "metadata.json").read_text())
assert metadata["uuid"] == "kimpanel@kde.org" and metadata["version"] == 92
assert "50" in metadata["shell-version"], "GNOME 50 support is required"
(root / "SOURCE").write_text(f"url={URL}\nsha256={SHA256}\nversion=92\n")
