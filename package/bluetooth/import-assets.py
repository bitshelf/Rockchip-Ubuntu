#!/usr/bin/env python3
"""Import optional, externally supplied Bluetooth files without board policy."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def inspect(source):
    if source.is_symlink():
        raise ValueError('Bluetooth input directory must not be a symlink')
    if not source.exists():
        return None
    if not source.is_dir():
        raise ValueError('Bluetooth inputs must be a directory')
    for path in source.rglob('*'):
        if path.is_symlink() or not (path.is_file() or path.is_dir()):
            raise ValueError(f'unsupported input: {path.relative_to(source)}')
    if any(p.name not in ('config.json', 'rootfs') for p in source.iterdir()):
        raise ValueError('only config.json and rootfs/ are accepted')
    config = json.loads((source / 'config.json').read_text()) if (source / 'config.json').exists() else {}
    if not isinstance(config, dict) or set(config) - {'schema', 'packages'}:
        raise ValueError('unsupported Bluetooth configuration fields')
    if config.get('schema', 'linux-bluetooth-assets-v1') != 'linux-bluetooth-assets-v1':
        raise ValueError('unsupported Bluetooth input schema')
    packages = config.get('packages', ['bluez'])
    if not isinstance(packages, list) or any(not isinstance(p, str) or not re.fullmatch(r'[a-z0-9][a-z0-9+.-]*', p) for p in packages):
        raise ValueError('packages must contain plain APT package names')
    tree = source / 'rootfs'
    if not tree.is_dir():
        raise ValueError('missing Bluetooth rootfs/ directory')
    files = []
    services = []
    prefixes = ('usr/lib/firmware/', 'usr/libexec/platform-bluetooth/', 'etc/platform-bluetooth/')
    for path in sorted(tree.rglob('*')):
        if path.is_dir():
            continue
        name = path.relative_to(tree).as_posix()
        unit = re.fullmatch(r'usr/lib/systemd/system/(platform-bluetooth[a-zA-Z0-9_.-]*\.service)', name)
        options = re.fullmatch(r'etc/modprobe.d/platform-bluetooth[a-zA-Z0-9_.-]*\.conf', name)
        if not name.startswith(prefixes) and not unit and not options:
            raise ValueError(f'unsupported Bluetooth target: {name}')
        executable = name.startswith('usr/libexec/platform-bluetooth/')
        if executable:
            with path.open('rb') as stream:
                header = stream.read(20)
            if header.startswith(b'\x7fELF'):
                if len(header) != 20 or header[4:6] != b'\x02\x01' or int.from_bytes(header[18:20], 'little') != 183:
                    raise ValueError(f'helper must be ARM64 ELF: {name}')
            elif not header.startswith(b'#!'):
                raise ValueError(f'helper must be ARM64 ELF or an interpreter script: {name}')
        files.append({'path': name, 'sha256': digest(path), 'mode': 0o755 if executable else 0o644})
        if unit:
            services.append(unit[1])
    if not files:
        raise ValueError('Bluetooth rootfs/ contains no files')
    receipt = {'schema': 'linux-bluetooth-assets-v1', 'packages': sorted(set(packages)), 'files': files, 'services': services}
    if (source / 'config.json').exists():
        receipt['config_sha256'] = digest(source / 'config.json')
    receipt['sha256'] = hashlib.sha256(json.dumps(receipt, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    return receipt


def safe_target(root, name):
    target = root / name
    for path in (target, *target.parents):
        if path == root:
            break
        if path.is_symlink():
            raise ValueError(f'rootfs target contains symlink: {name}')
        if path != target and path.exists() and not path.is_dir():
            raise ValueError(f'rootfs target parent is not a directory: {name}')
    return target


def install(source, root, receipt):
    if receipt is None:
        return
    if root.is_symlink() or not root.is_dir():
        raise ValueError('rootfs must be an existing real directory')
    # Validate every destination before copying; never overwrite package-owned files.
    for entry in receipt['files']:
        target = safe_target(root, entry['path'])
        if target.exists() and (not target.is_file() or digest(target) != entry['sha256']):
            raise ValueError(f'Bluetooth target collision: {entry["path"]}')
    links = []
    for service in receipt['services']:
        name = 'etc/systemd/system/multi-user.target.wants/' + service
        target = root / name
        parent = safe_target(root, str(Path(name).parent))
        if parent.exists() and not parent.is_dir():
            raise ValueError(f'Bluetooth service parent is not a directory: {service}')
        expected = '/usr/lib/systemd/system/' + service
        if target.is_symlink():
            if target.readlink().as_posix() != expected:
                raise ValueError(f'Bluetooth service link collision: {service}')
        elif target.exists():
            raise ValueError(f'Bluetooth service link collision: {service}')
        links.append((target, expected))
    output = safe_target(root, 'usr/share/platform-bluetooth/assets.json')
    if output.exists() and not output.is_file():
        raise ValueError('Bluetooth receipt target is not a file')
    for entry in receipt['files']:
        target = root / entry['path']
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source / 'rootfs' / entry['path'], target)
        target.chmod(entry['mode'])
    for target, expected in links:
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.is_symlink():
            target.symlink_to(expected)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(receipt, sort_keys=True, indent=2) + '\n')
    output.chmod(0o644)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('check', 'packages', 'install'))
    parser.add_argument('--inputs', required=True, type=Path)
    parser.add_argument('--rootfs', type=Path)
    args = parser.parse_args()
    try:
        receipt = inspect(args.inputs)
        if args.action == 'packages':
            print('\n'.join(receipt['packages']) if receipt else '', end='\n' if receipt else '')
        elif args.action == 'install':
            if args.rootfs is None:
                raise ValueError('--rootfs is required for install')
            install(args.inputs, args.rootfs, receipt)
        else:
            print(json.dumps(receipt or {'status': 'absent'}, sort_keys=True))
    except (ValueError, OSError, TypeError) as error:
        parser.exit(1, f'Bluetooth inputs: {error}\n')


if __name__ == '__main__':
    main()
