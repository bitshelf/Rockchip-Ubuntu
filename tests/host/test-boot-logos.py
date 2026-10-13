#!/usr/bin/env python3
"""Reject unsafe or unsupported vendor boot logo inputs before packaging."""

import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "boot_logos", Path(__file__).resolve().parents[2] / "scripts/check-boot-logos.py"
)
logos = importlib.util.module_from_spec(spec)
spec.loader.exec_module(logos)


class LogoValidation(unittest.TestCase):
    def test_bmp_inputs(self):
        header = struct.pack("<2sIII", b"BM", 58, 0, 54)
        header += struct.pack("<IiiHHIIiiII", 40, 1, -1, 1, 24, 0, 4, 0, 0, 0, 0)
        valid = header + bytes([0, 0, 255, 0])
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "logo.bmp"
            path.write_bytes(valid)
            logos.validate(path)
            for offset, value, fmt in (
                (2, 59, "<I"), (10, 0, "<I"), (14, 108, "<I"),
                (18, 4097, "<i"), (22, 0, "<i"), (26, 2, "<H"),
                (28, 8, "<H"), (30, 1, "<I"),
            ):
                with self.subTest(offset=offset):
                    corrupt = bytearray(valid)
                    struct.pack_into(fmt, corrupt, offset, value)
                    path.write_bytes(corrupt)
                    with self.assertRaises(ValueError):
                        logos.validate(path)
            path.write_bytes(valid[:54])
            with self.assertRaises(ValueError):
                logos.validate(path)
            path.unlink()
            path.symlink_to("missing.bmp")
            with self.assertRaises(ValueError):
                logos.validate(path)


if __name__ == "__main__":
    unittest.main()
