#!/usr/bin/env python3
"""Exercise external radio assets, rejected inputs and input-bundle wiring."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('bluetooth_assets', PROJECT / 'package/bluetooth/import-assets.py')
assets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assets)


class AssetsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.source = self.base / 'bluetooth'
        self.root = self.base / 'destination'
        self.root.mkdir()

    def add(self, path, data=b'fixture'):
        target = self.source / 'rootfs' / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        return target

    def fixture(self):
        self.add('usr/lib/firmware/provider/radio.bin')
        self.add('usr/libexec/platform-bluetooth/start', b'#!/bin/sh\nexit 0\n')
        self.add('usr/lib/systemd/system/platform-bluetooth.service', b'[Service]\nExecStart=/usr/libexec/platform-bluetooth/start\n')

    def test_absent_is_noop(self):
        self.assertIsNone(assets.inspect(self.source))
        assets.install(self.source, self.root, None)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_install_and_idempotence(self):
        self.fixture()
        receipt = assets.inspect(self.source)
        self.assertEqual(receipt['packages'], ['bluez'])
        assets.install(self.source, self.root, receipt)
        assets.install(self.source, self.root, receipt)
        self.assertEqual((self.root / 'usr/libexec/platform-bluetooth/start').stat().st_mode & 0o777, 0o755)
        self.assertEqual((self.root / 'usr/lib/firmware/provider/radio.bin').stat().st_mode & 0o777, 0o644)
        link = self.root / 'etc/systemd/system/multi-user.target.wants/platform-bluetooth.service'
        self.assertEqual(str(link.readlink()), '/usr/lib/systemd/system/platform-bluetooth.service')
        self.assertEqual(json.loads((self.root / 'usr/share/platform-bluetooth/assets.json').read_text()), receipt)

    def test_input_checksum_changes_with_bytes(self):
        self.fixture()
        first = assets.inspect(self.source)['sha256']
        self.add('usr/lib/firmware/provider/radio.bin', b'changed')
        self.assertNotEqual(first, assets.inspect(self.source)['sha256'])

    def test_bad_package_rejected(self):
        self.fixture()
        (self.source / 'config.json').write_text(json.dumps({'packages': ['bluez\nmalicious']}))
        with self.assertRaises(ValueError):
            assets.inspect(self.source)

    def test_reject_core_path(self):
        self.add('etc/passwd')
        with self.assertRaises(ValueError):
            assets.inspect(self.source)

    def test_reject_source_symlink(self):
        self.fixture()
        (self.source / 'rootfs/usr/lib/firmware/escape').symlink_to('/etc/passwd')
        with self.assertRaises(ValueError):
            assets.inspect(self.source)

    def test_reject_wrong_elf_arch(self):
        header = bytearray(20)
        header[:6] = b'\x7fELF\x02\x01'
        header[18:20] = (62).to_bytes(2, 'little')
        self.add('usr/libexec/platform-bluetooth/helper', header)
        with self.assertRaises(ValueError):
            assets.inspect(self.source)

    def test_no_writes_before_collision_check(self):
        self.fixture()
        target = self.root / 'usr/libexec/platform-bluetooth/start'
        target.parent.mkdir(parents=True)
        target.write_text('package owned')
        with self.assertRaises(ValueError):
            assets.install(self.source, self.root, assets.inspect(self.source))
        self.assertFalse((self.root / 'usr/lib/firmware').exists())
        self.assertEqual(target.read_text(), 'package owned')

    def test_service_parent_collision_has_no_partial_copy(self):
        self.fixture()
        parent = self.root / 'etc/systemd/system/multi-user.target.wants'
        parent.parent.mkdir(parents=True)
        parent.write_text('existing file')
        with self.assertRaises(ValueError):
            assets.install(self.source, self.root, assets.inspect(self.source))
        self.assertFalse((self.root / 'usr').exists())

    def test_destination_symlink_cannot_escape(self):
        self.fixture()
        outside = self.base / 'outside'
        outside.mkdir()
        (self.root / 'usr').symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            assets.install(self.source, self.root, assets.inspect(self.source))
        self.assertEqual(list(outside.iterdir()), [])

    def test_ci_input_environment(self):
        spec = importlib.util.spec_from_file_location('inputs', PROJECT / 'scripts/build-inputs.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        data = {'soc': 'example', 'boot': {'base_dtb': 'base.dtb'}, 'gpu_stack': 'panfrost'}
        self.assertEqual(module.env_for(self.base, data, self.root)['BLUETOOTH_ASSET_DIR'], str(self.source))


if __name__ == '__main__':
    unittest.main()
