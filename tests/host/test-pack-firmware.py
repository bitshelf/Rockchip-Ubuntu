#!/usr/bin/env python3
"""Reject unsafe SDK packaging inputs before running external pack tools."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('firmware', Path(__file__).resolve().parents[2] / 'scripts/pack-firmware.py')
f = importlib.util.module_from_spec(spec)
spec.loader.exec_module(f)


class FirmwareInputs(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.inputs = self.root / 'firmware'
        self.inputs.mkdir()
        self.package = ('package-file package-file\nparameter parameter.txt\nbootloader MiniLoaderAll.bin\n'
                        'uboot uboot.img\nboot boot.img\nrootfs rootfs.img\nuserdata userdata.img\n')
        (self.inputs / 'package-file').write_text(self.package)
        (self.inputs / 'MiniLoaderAll.bin').write_bytes(b'\0' * 21 + b'7635')
        (self.inputs / 'parameter.txt').write_text('CMDLINE: mtdparts=:0x20@0x0(uboot),0x20@0x20(boot),0x20@0x40(rootfs),-@0x60(userdata:grow)\n')
        for name in ('uboot.img', 'afptool', 'rkImageMaker'):
            (self.inputs / name).write_bytes(b'fixture')
        self.manifest()
        self.images = self.root / 'images'
        self.images.mkdir()
        for name in ('boot-fixture.img', 'ubuntu-rootfs.img', 'userdata-fixture.img'):
            p = self.images / name
            p.write_bytes(b'fixture')
            (self.images / (name + '.sha256')).write_text(f'{f.sha(p)}  {name}\n')

    def manifest(self):
        data = {p.name: f.sha(p) for p in self.inputs.iterdir() if p.name != 'manifest.json'}
        (self.inputs / 'manifest.json').write_text(json.dumps({'schema': 'ubuntu-sdk-firmware-v1', 'sha256': data}))

    def rejected_pack(self):
        with patch.object(f.subprocess, 'run') as run, patch.object(f.platform, 'machine', return_value='x86_64'):
            with self.assertRaises(ValueError):
                f.pack(self.inputs, self.images, self.root / 'update.img')
            run.assert_not_called()

    def test_valid_chip_and_complete_manifest(self):
        self.assertEqual(f.check(self.inputs)[2], '5367')

    def test_tampered_uboot(self):
        (self.inputs / 'uboot.img').write_bytes(b'changed')
        self.rejected_pack()

    def test_path_escape(self):
        (self.inputs / 'package-file').write_text(self.package + 'misc ../secret\n')
        self.manifest()
        self.rejected_pack()

    def test_missing_uboot_entry(self):
        (self.inputs / 'package-file').write_text(self.package.replace('uboot uboot.img\n', ''))
        self.manifest()
        self.rejected_pack()

    def test_missing_loader(self):
        (self.inputs / 'MiniLoaderAll.bin').unlink()
        self.rejected_pack()

    def test_oversized_rootfs(self):
        p = self.images / 'ubuntu-rootfs.img'
        p.write_bytes(b'X' * (0x20 * 512 + 1))
        (self.images / (p.name + '.sha256')).write_text(f'{f.sha(p)}  {p.name}\n')
        self.rejected_pack()

    def test_wrong_filesystem_hash(self):
        (self.images / 'ubuntu-rootfs.img').write_bytes(b'corrupted')
        self.rejected_pack()

    def test_duplicate_partition(self):
        (self.inputs / 'package-file').write_text(self.package + 'boot other.img\n')
        self.manifest()
        self.rejected_pack()

    def test_uboot_symlink(self):
        (self.inputs / 'uboot.img').unlink()
        (self.inputs / 'uboot.img').symlink_to(self.inputs / 'afptool')
        self.rejected_pack()


if __name__ == '__main__':
    unittest.main()
