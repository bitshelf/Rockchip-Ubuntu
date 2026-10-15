#!/usr/bin/env python3
"""Export final installed DEBs and optionally enforce an explicit version manifest."""
import argparse
import hashlib
from pathlib import Path
import re
import subprocess

SCHEMA = '# ubuntu-package-manifest-v1'
PIN = 'etc/apt/preferences.d/99-ubuntu-build-manifest.pref'
POLICY = 'etc/apt/apt.conf.d/99-ubuntu-build-manifest'


def entry(name, version, arch):
    if not re.fullmatch(r'[a-z0-9][a-z0-9+.-]*', name):
        raise ValueError(f'invalid package name: {name}')
    if not re.fullmatch(r'[0-9][A-Za-z0-9.+:~\-]*', version):
        raise ValueError(f'invalid version for {name}')
    if arch not in ('arm64', 'all'):
        raise ValueError(f'unsupported architecture for {name}: {arch}')
    return (name, arch), version


def load(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError('manifest must be a regular file')
    result = {}
    lines = path.read_text().splitlines()
    if not lines or lines[0] != SCHEMA:
        raise ValueError('use the final v1 manifest (package, version, architecture), not the base ubuntu-image manifest')
    for number, line in enumerate(lines[1:], 2):
        if not line.strip() or line.startswith('#'):
            continue
        fields = line.split()
        if len(fields) != 3:
            raise ValueError(f'invalid manifest row {number}')
        key, version = entry(*fields)
        if key in result:
            raise ValueError(f'duplicate manifest package: {key}')
        result[key] = version
    if not result:
        raise ValueError('empty package manifest')
    return result


def installed(root):
    result = {}
    status = root / 'var/lib/dpkg/status'
    for stanza in status.read_text().split('\n\n'):
        fields = {}
        for line in stanza.splitlines():
            if line and not line[0].isspace() and ': ' in line:
                key, value = line.split(': ', 1)
                fields[key] = value
        state = fields.get('Status', '').split()
        if not state or state[-1] in ('not-installed', 'config-files'):
            continue
        if len(state) != 3 or state[1:] != ['ok', 'installed']:
            raise ValueError(f'incompletely installed package: {fields.get("Package", "unknown")}')
        key, version = entry(fields['Package'], fields['Version'], fields['Architecture'])
        if key in result:
            raise ValueError(f'duplicate installed package: {key}')
        result[key] = version
    if not result:
        raise ValueError('rootfs has no fully installed DEB packages')
    return result


def export(root, output):
    packages = installed(root)
    output.parent.mkdir(parents=True, exist_ok=True)
    text = SCHEMA + '\n# package\tversion\tarchitecture\n'
    text += ''.join(f'{name}\t{version}\t{arch}\n' for (name, arch), version in sorted(packages.items()))
    output.write_text(text)
    Path(str(output) + '.sha256').write_text(f'{hashlib.sha256(text.encode()).hexdigest()}  {output.name}\n')
    print(f'Exported {len(packages)} installed DEB versions: {output}')


def local_packages(directories):
    result = {}
    for directory in directories:
        if not directory.exists():
            continue
        for path in sorted(directory.glob('*.deb')):
            if path.is_symlink():
                raise ValueError(f'symlinked local DEB: {path}')
            # Read control metadata without executing package scripts.
            values = [subprocess.check_output(['dpkg-deb', '-f', str(path), field], text=True).strip()
                      for field in ('Package', 'Version', 'Architecture')]
            key, version = entry(*values)
            if key in result and result[key] != version:
                raise ValueError(f'conflicting local DEB versions for {key}')
            result[key] = version
    return result


def pins(root, manifest, directories):
    expected = load(manifest)
    local = local_packages(directories)
    # Local overrides can replace archive packages (for example v4l-utils).
    # Let ubuntu-image install its archive dependency first. The overlay installs
    # the supplied DEB, and final exact verification certifies that replacement.
    rows = ['Package: *\nPin: release *\nPin-Priority: -1\n']
    for (name, arch), version in sorted(expected.items()):
        key = (name, arch)
        if key in local:
            if local[key] != version:
                raise ValueError(f'local DEB version differs from manifest: {name}: {local[key]} != {version}')
            pin, priority = '*', 500
        else:
            pin, priority = version, 1001
        selector = name if arch == 'all' else f'{name}:{arch}'
        rows.append(f'Package: {selector}\nPin: version {pin}\nPin-Priority: {priority}\n')
    target = root / PIN
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text('\n'.join(rows))
    policy = root / POLICY
    policy.parent.mkdir(parents=True, exist_ok=True)
    policy.write_text('APT::Get::allow-downgrades "true";\n')
    print(f'Applied explicit manifest: {len(expected)} DEB versions; unavailable versions fail the build')


def verify(root, manifest):
    expected, actual = load(manifest), installed(root)
    missing = sorted(set(expected) - set(actual))
    extra = sorted(set(actual) - set(expected))
    changed = [(key, expected[key], actual[key]) for key in sorted(set(expected) & set(actual))
               if expected[key] != actual[key]]
    if missing or extra or changed:
        raise ValueError(f'package manifest mismatch: missing={missing}, extra={extra}, versions={changed}')
    print(f'Exact final DEB package set verified: {len(expected)} packages')


def finalize(root, manifest):
    verify(root, manifest)
    # This is a build policy, not a permanent customer apt/hold policy.
    for name in (PIN, POLICY):
        (root / name).unlink(missing_ok=True)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('mode', choices=('check', 'export', 'pins', 'verify', 'finalize'))
    p.add_argument('--rootfs', type=Path)
    p.add_argument('--manifest', type=Path)
    p.add_argument('--output', type=Path)
    p.add_argument('--debs-dir', type=Path, action='append', default=[])
    a = p.parse_args()
    if a.mode == 'check':
        if a.manifest is None:
            p.error('check requires --manifest')
        print(f'Valid manifest: {len(load(a.manifest))} packages')
        return
    if a.rootfs is None or not a.rootfs.is_absolute() or (a.mode in ('pins', 'finalize') and a.rootfs.resolve() == Path('/')) or not a.rootfs.is_dir():
        p.error('--rootfs must be an existing absolute build rootfs directory, never /')
    if a.mode == 'export':
        if a.output is None:
            p.error('export requires --output')
        export(a.rootfs, a.output)
    else:
        if a.manifest is None:
            p.error('this mode requires --manifest')
        if a.mode == 'pins':
            pins(a.rootfs, a.manifest, a.debs_dir)
        elif a.mode == 'verify':
            verify(a.rootfs, a.manifest)
        else:
            finalize(a.rootfs, a.manifest)


if __name__ == '__main__':
    main()
