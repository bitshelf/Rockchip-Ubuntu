#!/usr/bin/env python3
"""Exercise full version-set checks and isolated real APT resolution."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('packages', ROOT / 'scripts/package-manifest.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class Manifest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'rootfs'
        (self.root / 'var/lib/dpkg').mkdir(parents=True)
        self.status('1.0')
        self.manifest = Path(self.tmp.name) / 'packages.manifest'
        m.export(self.root, self.manifest)

    def status(self, version):
        (self.root / 'var/lib/dpkg/status').write_text('Package: version-test\nStatus: install ok installed\nArchitecture: arm64\nVersion: '+version+'\nDescription: test\n\nPackage: removed-test\nStatus: deinstall ok config-files\nArchitecture: arm64\nVersion: 1\n')

    def test_held_local_packages_are_included_and_broken_packages_rejected(self):
        p = self.root / 'var/lib/dpkg/status'
        p.write_text(p.read_text().replace('install ok installed', 'hold ok installed'))
        self.assertEqual(m.installed(self.root), {('version-test', 'arm64'): '1.0'})
        p.write_text(p.read_text().replace('hold ok installed', 'install ok unpacked'))
        with self.assertRaises(ValueError):
            m.installed(self.root)

    def test_export_and_verify(self):
        self.assertEqual(m.load(self.manifest), {('version-test', 'arm64'): '1.0'})
        m.verify(self.root, self.manifest)

    def test_changed_missing_and_extra_packages_are_rejected(self):
        self.status('2.0')
        with self.assertRaises(ValueError):
            m.verify(self.root, self.manifest)
        self.status('1.0')
        with (self.root / 'var/lib/dpkg/status').open('a') as f:
            f.write('\n\nPackage: unexpected\nStatus: install ok installed\nVersion: 1\nArchitecture: all\n')
        with self.assertRaises(ValueError):
            m.verify(self.root, self.manifest)
        self.status('1.0')
        self.manifest.write_text(m.SCHEMA+'\nmissing 1 all\n')
        with self.assertRaises(ValueError):
            m.verify(self.root, self.manifest)

    def test_injection_duplicates_and_old_base_manifest_rejected(self):
        for text in ['version-test 1\n', m.SCHEMA+'\nx 1 arm64\nx 2 arm64\n',
                     m.SCHEMA+'\nx 1;touch all\n', m.SCHEMA+'\nx 1 amd64\n']:
            self.manifest.write_text(text)
            with self.assertRaises(ValueError):
                m.load(self.manifest)

    def test_build_pins_removed_only_after_success(self):
        m.pins(self.root, self.manifest, [])
        self.status('2.0')
        with self.assertRaises(ValueError):
            m.finalize(self.root, self.manifest)
        self.assertTrue((self.root / m.PIN).exists())
        self.status('1.0')
        m.finalize(self.root, self.manifest)
        self.assertFalse((self.root / m.PIN).exists())
        self.assertFalse((self.root / m.POLICY).exists())

    def apt(self, *args, check=True):
        # APT reads config fragments before applying command-line -o values.
        # Point it at the fixture from startup so the generated downgrade policy
        # is actually exercised and runner-wide APT settings cannot leak in.
        config = self.aptroot / 'apt-test.conf'
        config.write_text(f'Dir "{self.aptroot}";\n'
                          f'Dir::Etc::parts "{self.root / "etc/apt/apt.conf.d"}";\n'
                          'Dir::Etc::main "-";\n')
        options = ['-o', 'Dir='+str(self.aptroot), '-o', 'Dir::State::status='+str(self.root/'var/lib/dpkg/status'),
                   '-o', 'Dir::Etc::preferencesparts='+str(self.root/'etc/apt/preferences.d'),
                   '-o', 'Dir::Etc::parts='+str(self.root/'etc/apt/apt.conf.d'),
                   '-o', 'APT::Architecture=arm64', '-o', 'APT::Architectures::=arm64',
                   '-o', 'APT::Sandbox::User=root', '-o', 'Debug::NoLocking=true', '-o', 'Dir::Cache::pkgcache=', '-o', 'Dir::Cache::srcpkgcache=']
        result = subprocess.run([('apt-cache' if args[0] == 'policy' else 'apt-get'), *options, *args],
                                env=os.environ | {'APT_CONFIG': str(config)}, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if check and result.returncode:
            self.fail(f'APT fixture failed ({result.returncode}):\n{result.stdout}')
        return result

    @unittest.skipUnless(shutil.which('apt-get') and shutil.which('dpkg-deb'), 'APT and dpkg-deb required')
    def test_real_apt_default_latest_explicit_downgrade_missing_version_and_local_override(self):
        self.aptroot = Path(self.tmp.name) / 'apt'
        for d in ['etc/apt/sources.list.d', 'var/lib/apt/lists/partial', 'var/cache/apt/archives/partial', 'var/log/apt']:
            (self.aptroot/d).mkdir(parents=True)
        repo = Path(self.tmp.name) / 'repo'
        repo.mkdir()
        text = ''
        for name in ['version-test', 'unlisted-test']:
            for version in ['1.0', '2.0']:
                text += f'Package: {name}\nVersion: {version}\nArchitecture: arm64\nMaintainer: Test <test@example.invalid>\nDescription: test\nFilename: {name}_{version}_arm64.deb\nSize: 100\n\n'
        (repo/'Packages').write_text(text)
        (self.aptroot/'etc/apt/sources.list').write_text('deb [trusted=yes] file:'+str(repo)+' ./\n')
        self.apt('update')
        latest = self.apt('-s', 'install', 'version-test').stdout
        self.assertRegex(latest, r'Inst version-test \[1.0\] \(2.0')
        self.status('2.0')
        m.pins(self.root, self.manifest, [])
        locked = self.apt('-s', '-y', 'upgrade').stdout
        self.assertRegex(locked, r'Inst version-test \[2.0\] \(1.0', self.apt('policy', 'version-test').stdout)
        self.assertNotEqual(self.apt('-s', 'install', 'unlisted-test', check=False).returncode, 0)
        self.manifest.write_text(m.SCHEMA+'\nversion-test 3.0 arm64\n')
        m.pins(self.root, self.manifest, [])
        self.assertNotEqual(self.apt('-s', 'install', 'version-test=3.0', check=False).returncode, 0)
        with self.assertRaises(ValueError):
            m.verify(self.root, self.manifest)
        # The vendor override is not in the archive. Its temporary archive
        # dependency may resolve normally, but only the final vendor version passes.
        debdir = Path(self.tmp.name) / 'debs'
        control = Path(self.tmp.name) / 'vendor/DEBIAN'
        control.mkdir(parents=True)
        control.joinpath('control').write_text('Package: version-test\nVersion: 3.0\nArchitecture: arm64\nMaintainer: Test <test@example.invalid>\nDescription: local override\n')
        debdir.mkdir()
        subprocess.run(['dpkg-deb', '--build', str(control.parent), str(debdir/'vendor.deb')], check=True, stdout=subprocess.DEVNULL)
        m.pins(self.root, self.manifest, [debdir])
        allowed = self.apt('-s', 'install', 'version-test').stdout
        self.assertIn('already the newest version (2.0)', allowed)
        self.status('3.0')
        m.finalize(self.root, self.manifest)
        self.manifest.write_text(m.SCHEMA+'\nversion-test 4.0 arm64\n')
        with self.assertRaises(ValueError):
            m.pins(self.root, self.manifest, [debdir])


if __name__ == '__main__':
    unittest.main()
