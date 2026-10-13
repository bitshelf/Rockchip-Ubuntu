#!/usr/bin/env python3
"""Validate the bounded, uncompressed BMP pair consumed by Rockchip U-Boot."""

import argparse
from pathlib import Path
import struct


def validate(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"not a regular logo: {path}")
    size = path.stat().st_size
    if not 54 <= size <= 16 * 1024 * 1024:
        raise ValueError(f"unsupported logo size: {path}")
    with path.open("rb") as stream:
        header = stream.read(54)
    signature, declared_size, _, offset = struct.unpack_from("<2sIII", header)
    dib_size, width, height, planes, depth, compression = struct.unpack_from(
        "<IiiHHI", header, 14
    )
    if signature != b"BM" or declared_size != size:
        raise ValueError(f"invalid BMP file header: {path}")
    if dib_size != 40 or planes != 1 or depth not in (24, 32) or compression != 0:
        raise ValueError(f"logo requires a BITMAPINFOHEADER and uncompressed RGB: {path}")
    if not 1 <= width <= 4096 or not 1 <= abs(height) <= 4096:
        raise ValueError(f"unsupported BMP dimensions: {path}")
    stride = ((width * depth + 31) // 32) * 4
    if offset < 54 or offset + stride * abs(height) != size:
        raise ValueError(f"truncated or trailing BMP pixel data: {path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--required", action="store_true")
    args = parser.parse_args()
    paths = [args.directory / name for name in ("logo.bmp", "logo_kernel.bmp")]
    if not args.required and not any(p.exists() or p.is_symlink() for p in paths):
        return
    try:
        for path in paths:
            validate(path)
    except (OSError, ValueError, struct.error) as error:
        parser.exit(1, f"ERROR: {error}\n")
    print("BOOT_LOGO_BMP_PAIR_OK")


if __name__ == "__main__":
    main()
