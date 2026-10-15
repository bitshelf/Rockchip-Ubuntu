#!/usr/bin/env python3
"""Package and build self-contained, external Ubuntu platform inputs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile

PROJECT = Path(__file__).resolve().parents[1]


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def load(root):
    root = root.resolve()
    data = json.loads((root / 'build.json').read_text())
    if data.get('schema') != 'ubuntu-build-inputs-v1':
        raise ValueError('unsupported build.json schema')
    soc = data['soc']
    if not re.fullmatch(r'[a-z0-9][a-z0-9._-]*', soc):
        raise ValueError('invalid soc')
    base = data['boot']['base_dtb']
    if Path(base).name != base or not base.endswith('.dtb'):
        raise ValueError('base_dtb must be a DTB filename')
    if data['gpu_stack'] not in ('panfrost', 'libmali'):
        raise ValueError('invalid gpu_stack')
    if data.get('chromium_webgpu_backend', 'auto') not in ('auto', 'gles-compat'):
        raise ValueError('invalid chromium_webgpu_backend')
    variants = data['variants']
    if not isinstance(variants, list) or not variants or len(set(variants)) != len(variants) or any(v not in ('server', 'desktop', 'desktop-xfce') for v in variants):
        raise ValueError('variants must contain supported Server/GNOME/XFCE products')
    cmdline = data['boot'].get('cmdline', 'root=PARTLABEL=rootfs rootfstype=erofs rootwait ro')
    if not isinstance(cmdline, str) or '\n' in cmdline or '\r' in cmdline or '\0' in cmdline:
        raise ValueError('invalid boot cmdline')
    for name in ('build.json', f'platform-assets/{soc}', f'platform-assets/{soc}/boot/{base}', 'sources/update-engine.tar', 'sources/update-engine.tar.source-info'):
        path = root / name
        if not path.exists() or root not in path.resolve().parents or path.is_symlink():
            raise ValueError(f'missing or unsafe input: {name}')
    return root, data


def env_for(root, data, output):
    return os.environ | {
        'BUILD_OUTPUT_DIR': str(output), 'SOC_MODEL': data['soc'],
        'PLATFORM_ASSET_DIR': str(root / 'platform-assets' / data['soc']),
        'BOOTFS_BASE_DTB': data['boot']['base_dtb'],
        'GPU_STACK': data['gpu_stack'],
        'CHROMIUM_WEBGPU_BACKEND': data.get('chromium_webgpu_backend', 'auto'),
        'UPDATE_ENGINE_SOURCE_ARCHIVE': str(root / 'sources/update-engine.tar'),
    }


def check(root, output):
    root, data = load(root)
    env = env_for(root, data, output)
    run(str(PROJECT / 'scripts/stage-sdk-assets.sh'), '--check', env=env)
    run(str(PROJECT / 'build.sh'), 'update-engine', '--check', env=env)
    return root, data


def pack(root, output):
    root, data = check(root, PROJECT / 'build/input-check')
    # Inputs alone are transported: published images and previous bundles are excluded.
    members = ['build.json', f"platform-assets/{data['soc']}", 'sources']
    if (root / 'firmware').is_dir():
        run('python3', str(PROJECT / 'scripts/pack-firmware.py'), 'check', '--inputs', str(root / 'firmware'))
        members.append('firmware')
    if (root / 'overlays').is_dir():
        members.append('overlays')
    with tempfile.TemporaryDirectory() as tmp:
        archive = Path(tmp) / 'inputs.tar'
        with tarfile.open(archive, 'w') as tar:
            for name in members:
                for path in [root / name, *sorted((root / name).rglob('*'))] if (root / name).is_dir() else [root / name]:
                    if path.is_symlink() or not (path.is_dir() or path.is_file()):
                        raise ValueError(f'unsupported input: {path}')
                    info = tar.gettarinfo(str(path), arcname=str(path.relative_to(root)))
                    info.uid = info.gid = info.mtime = 0
                    info.uname = info.gname = ''
                    info.mode = 0o755 if path.is_dir() else 0o644
                    if path.is_file():
                        with path.open('rb') as stream:
                            tar.addfile(info, stream)
                    else:
                        tar.addfile(info)
        output.parent.mkdir(parents=True, exist_ok=True)
        stage = Path(str(output) + '.stage')
        run('zstd', '-q', '-T0', '-10', '-f', str(archive), '-o', str(stage))
        stage.replace(output)
    with output.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    Path(str(output) + '.sha256').write_text(f'{digest}  {output.name}\n')
    print(f'bundle={output}\nsha256={digest}')


def fetch(url, expected, destination):
    if not re.fullmatch(r'[a-fA-F0-9]{64}', expected):
        raise ValueError('BUILD_INPUTS_SHA256 must pin the uploaded directory bundle')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent) as tmp:
        work = Path(tmp)
        archive = work / 'inputs.tar.zst'
        args = ['curl', '--fail', '--silent', '--show-error', '--location']
        if os.environ.get('BUILD_INPUTS_AUTH_HEADER'):
            args += ['--header', os.environ['BUILD_INPUTS_AUTH_HEADER']]
        run(*args, '--output', str(archive), url)
        with archive.open('rb') as stream:
            if hashlib.file_digest(stream, 'sha256').hexdigest() != expected.lower():
                raise ValueError('build inputs checksum mismatch')
        unpacked = work / 'inputs.tar'
        with unpacked.open('wb') as stream:
            run('zstd', '-q', '-dc', str(archive), stdout=stream)
        extracted = work / 'artifacts'
        extracted.mkdir()
        with tarfile.open(unpacked) as tar:
            for member in tar.getmembers():
                name = Path(member.name)
                if name.is_absolute() or '..' in name.parts or not (member.isfile() or member.isdir()):
                    raise ValueError(f'unsafe archive entry: {member.name}')
            tar.extractall(extracted, filter='data')
        check(extracted, PROJECT / 'build/input-check')
        if destination.exists():
            raise ValueError('fetch destination already exists; use a fresh CI input directory')
        extracted.rename(destination)


def build(root, output, variant):
    root, data = check(root, output)
    if variant not in data['variants']:
        raise ValueError(f'{variant} not enabled in build.json')
    output.mkdir(parents=True, exist_ok=True)
    env = env_for(root, data, output)
    overlays = root / 'overlays'
    overlays.mkdir(exist_ok=True)
    env['DTS_OVERLAY_DIR'] = str(overlays)
    policy = output / 'bootfs.conf'
    # JSON string escaping is compatible with double-quoted shell assignments,
    # except dollar signs and backticks, which must remain literal.
    cmdline = data['boot'].get('cmdline', 'root=PARTLABEL=rootfs rootfstype=erofs rootwait ro')
    quoted = json.dumps(cmdline).replace('$', '\\$').replace('`', '\\`')
    # Extlinux uses deciseconds. SDK U-Boot converts these to whole seconds;
    # values below 10 leave the menu waiting indefinitely for serial input.
    policy.write_text('BOOTFS_SIZE_MB=256\nBOOTFS_LABEL=boot\nBOOTFS_INSTALLED_DTB=board.dtb\nBOOTFS_TIMEOUT=30\nBOOTFS_CMDLINE=' + quoted + '\n')
    env['BOOTFS_CONFIG'] = str(policy)
    env['ROOTFS_VARIANT'] = env['FIRSTBOOT_PROFILE'] = variant
    run(str(PROJECT / 'build.sh'), variant, '--check', env=env)
    run(str(PROJECT / 'build.sh'), 'update-engine', env=env)
    run(str(PROJECT / 'build.sh'), variant, env=env)
    run(str(PROJECT / 'build.sh'), 'overlay-root', env=env)
    env['ROOTFS_INCLUDE_FILESYSTEM_IMAGES'] = 'yes'
    run(str(PROJECT / 'scripts/export-rootfs-artifacts.sh'), env=env)
    if os.environ.get('CLEAN_CI_WORK') == 'yes':
        # Only disposable work belonging to this successful build is removed.
        mounts = subprocess.check_output(['findmnt', '-rn', '-o', 'TARGET'], text=True).splitlines()
        work = output / 'work'
        for path in (work / f"resolute-{variant}", work / 'overlay-root'):
            if output == Path('/') or path.is_symlink() or any(m == str(path) or m.startswith(str(path) + '/') for m in mounts):
                raise ValueError('refusing unsafe or mounted CI work cleanup')
            run('sudo', '-n', 'rm', '-rf', '--', str(path))
    images = list((output / 'images').glob('*.rootfs.erofs.img'))
    if len(images) != 1:
        raise ValueError('expected one rootfs filesystem image')
    published = PROJECT / 'artifacts' / variant
    published.mkdir(parents=True, exist_ok=True)
    target = published / 'ubuntu-rootfs.img'
    run('cp', '--reflink=auto', str(images[0]), str(target))
    with target.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    Path(str(target) + '.sha256').write_text(f'{digest}  {target.name}\n')
    shutil.copy2(root / 'build.json', published / 'build.json')
    # Publish each filesystem once. The base tarball remains a local build
    # artifact; uploading it and a second EROFS copy inflates large CI archives.
    for source in sorted((output / 'images').iterdir()):
        if not source.is_file() or source == images[0] or source.name == images[0].name + '.sha256':
            continue
        if '.rootfs.tar.gz' in source.name:
            continue
        if source.name.endswith(('.img', '.sha256', '.manifest', '.filelist', '.build-info', '.qa.json')):
            run('cp', '--reflink=auto', str(source), str(published / source.name))
    print(f'published={target}\nsha256={digest}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('check', 'pack', 'fetch', 'build'))
    parser.add_argument('--inputs', type=Path, default=PROJECT / 'artifacts')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--variant', choices=('server', 'desktop', 'desktop-xfce'), default='server')
    args = parser.parse_args()
    root = args.inputs.absolute()
    if args.mode == 'pack':
        pack(root, (args.output or PROJECT / 'artifacts/ubuntu-build-inputs.tar.zst').absolute())
    elif args.mode == 'fetch':
        fetch(os.environ['BUILD_INPUTS_URL'], os.environ['BUILD_INPUTS_SHA256'], root)
    else:
        output = (args.output or Path(os.environ.get('BUILD_OUTPUT_DIR', str(PROJECT / 'build'))) / args.variant).absolute()
        if args.mode == 'check':
            check(root, output)
        else:
            build(root, output, args.variant)


if __name__ == '__main__':
    main()
