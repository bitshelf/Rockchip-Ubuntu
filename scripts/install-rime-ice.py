#!/usr/bin/env python3
"""Install the latest published rime-ice resource bundle into a desktop rootfs."""

from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import stat
import subprocess
import tempfile
import time
import urllib.request
import zipfile
from pathlib import Path, PurePosixPath


DEFAULT_URL = "https://github.com/iDvel/rime-ice/releases/latest/download/full.zip"
MAX_ARCHIVE_SIZE = 256 * 1024 * 1024
# Fcitx5 keeps the rime user data below XDG_DATA_HOME/fcitx5, i.e.
# ~/.local/share/fcitx5/rime (StandardPathsType::PkgData in fcitx5-rime).
RIME_USER_DATA = ".local/share/fcitx5/rime"


def download(url: str, output: Path) -> str:
    # GitHub release assets occasionally stall when read through urllib on the
    # native ARM64 builder.  Prefer curl's bounded transfer and retry handling;
    # retain urllib so the installer remains usable in minimal environments.
    if shutil.which("curl"):
        command = [
            "curl", "--fail", "--location", "--silent", "--show-error",
            "--connect-timeout", "30", "--max-time", "90", "--retry", "2",
            "--retry-all-errors", "--output", str(output),
            "--write-out", "%{url_effective}", url,
        ]
        try:
            result = subprocess.run(
                # Allow all three bounded attempts and curl's retry delays.
                command, check=True, capture_output=True, text=True, timeout=300
            )
            if output.stat().st_size > MAX_ARCHIVE_SIZE:
                raise ValueError("rime-ice archive exceeds size limit")
            return result.stdout.strip() or url
        except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired, ValueError):
            output.unlink(missing_ok=True)
            raise

    request = urllib.request.Request(url, headers={"User-Agent": "ubuntu-image-builder"})
    last_error: Exception | None = None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=120) as response, output.open("wb") as stream:
                resolved_url = response.geturl()
                total = 0
                while chunk := response.read(1024 * 1024):
                    total += len(chunk)
                    if total > MAX_ARCHIVE_SIZE:
                        raise ValueError("rime-ice archive exceeds size limit")
                    stream.write(chunk)
            return resolved_url
        except (OSError, ValueError) as error:
            last_error = error
            output.unlink(missing_ok=True)
            if attempt != 2:
                time.sleep(2**attempt)
    raise RuntimeError(f"failed to download {url}: {last_error}")


def safe_extract(archive: Path, destination: Path) -> Path:
    with zipfile.ZipFile(archive) as bundle:
        for member in bundle.infolist():
            path = PurePosixPath(member.filename)
            mode = member.external_attr >> 16
            if path.is_absolute() or ".." in path.parts or stat.S_ISLNK(mode):
                raise ValueError(f"unsafe archive member: {member.filename}")
        bundle.extractall(destination)

    schemas = list(destination.rglob("rime_ice.schema.yaml"))
    if len(schemas) != 1:
        raise ValueError("archive must contain exactly one rime_ice.schema.yaml")
    source = schemas[0].parent
    if not (source / "default.yaml").is_file():
        raise ValueError("archive is missing default.yaml")
    if not any((source / name).is_file() for name in ("LICENSE.txt", "LICENSE")):
        raise ValueError("archive is missing its license")
    return source


def account_ids(rootfs: Path, account: str) -> tuple[int, int] | None:
    passwd_file = rootfs / "etc/passwd"
    for line in passwd_file.read_text(encoding="utf-8").splitlines():
        fields = line.split(":")
        if fields[0] == account:
            return int(fields[2]), int(fields[3])
    return None


def copy_tree(source: Path, destination: Path) -> None:
    shutil.rmtree(destination, ignore_errors=True)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, destination)
    # A flat ZIP makes source the private TemporaryDirectory (0700). Its
    # permissions are not resource permissions and must not leak into skel.
    destination.chmod(0o755)


def chown_tree(path: Path, uid: int, gid: int) -> None:
    os.chown(path, uid, gid)
    for entry in path.rglob("*"):
        os.chown(entry, uid, gid, follow_symlinks=False)


def install(rootfs: Path, archive: Path, requested_url: str, resolved_url: str) -> None:
    with tempfile.TemporaryDirectory(prefix="rime-ice-extract-") as directory:
        source = safe_extract(archive, Path(directory))
        skel = rootfs / "etc/skel" / RIME_USER_DATA
        copy_tree(source, skel)
        ids = account_ids(rootfs, "ubuntu")
        if ids is not None:
            user = rootfs / "home/ubuntu" / RIME_USER_DATA
            copy_tree(source, user)
            chown_tree(user, *ids)

    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    provenance = rootfs / "usr/share/doc/rime-ice/SOURCE"
    provenance.parent.mkdir(parents=True, exist_ok=True)
    provenance.write_text(
        f"requested-url: {requested_url}\n"
        f"resolved-url: {resolved_url}\n"
        f"sha256: {digest}\n",
        encoding="utf-8",
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rootfs", type=Path, required=True)
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--url", default=os.environ.get("RIME_ICE_URL") or DEFAULT_URL)
    parser.add_argument("--resolved-url", default=os.environ.get("RIME_ICE_RESOLVED_URL"))
    args = parser.parse_args()

    if args.archive:
        install(
            args.rootfs,
            args.archive,
            args.url,
            args.resolved_url or str(args.archive.resolve()),
        )
        return 0

    with tempfile.TemporaryDirectory(prefix="rime-ice-download-") as directory:
        archive = Path(directory) / "full.zip"
        resolved_url = download(args.url, archive)
        install(args.rootfs, archive, args.url, resolved_url)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
