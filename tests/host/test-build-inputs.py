#!/usr/bin/env python3
"""Check portable input selection, archive transport and hostile path rejection."""
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
from pathlib import Path
import tempfile
import threading
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

script = Path(__file__).resolve().parents[2] / 'scripts/build-inputs.py'
spec = importlib.util.spec_from_file_location('build_inputs', script)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class Handler(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


with tempfile.TemporaryDirectory() as tmp:
    project = Path(tmp)
    module.PROJECT = project
    (project / 'scripts').mkdir()
    shutil.copy2(script.parent / 'package-manifest.py', project / 'scripts/package-manifest.py')
    bluetooth_importer = project / 'package/bluetooth/import-assets.py'
    bluetooth_importer.parent.mkdir(parents=True)
    shutil.copy2(script.parent.parent / 'package/bluetooth/import-assets.py', bluetooth_importer)
    for path in (project / 'scripts/stage-sdk-assets.sh', project / 'build.sh'):
        path.write_text('#!/bin/sh\nexit 0\n')
        path.chmod(0o755)
    for soc in ('rk3576', 'rk3588'):
        root = project / soc
        boot = root / f'platform-assets/{soc}/boot'
        boot.mkdir(parents=True)
        (boot / 'board.dtb').write_bytes(b'fixture')
        (root / 'sources').mkdir()
        for name in ('update-engine.tar', 'update-engine.tar.source-info'):
            (root / 'sources' / name).write_bytes(b'fixture')
        data = {'schema': 'ubuntu-build-inputs-v1', 'soc': soc, 'gpu_stack': 'panfrost',
                'variants': ['server', 'desktop', 'desktop-xfce'], 'boot': {'base_dtb': 'board.dtb'}}
        (root / 'build.json').write_text(json.dumps(data))
        # Published files must never be sent back as build inputs.
        (root / 'ubuntu-rootfs.img').write_bytes(b'not-an-input')
        # One platform has optional radio files; the other exercises absence.
        if soc == 'rk3588':
            radio = root / 'bluetooth/rootfs/usr/libexec/platform-bluetooth/start'
            radio.parent.mkdir(parents=True)
            radio.write_text('#!/bin/sh\nexit 0\n')
            radio.chmod(0o755)
        bundle = project / f'{soc}.tar.zst'
        module.pack(root, bundle)
        server = ThreadingHTTPServer(('127.0.0.1', 0), lambda *a, **k: Handler(*a, directory=tmp, **k))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        url = f'http://127.0.0.1:{server.server_port}/{bundle.name}'
        digest = hashlib.sha256(bundle.read_bytes()).hexdigest()
        dest = project / f'fetched-{soc}'
        module.fetch(url, digest, dest)
        assert not (dest / 'ubuntu-rootfs.img').exists()
        assert (dest / 'bluetooth').exists() == (soc == 'rk3588')
        if soc == 'rk3588':
            restored = dest / 'bluetooth/rootfs/usr/libexec/platform-bluetooth/start'
            assert restored.read_bytes() == radio.read_bytes()
            assert restored.stat().st_mode & 0o777 == 0o644
            target = project / 'radio-rootfs'
            target.mkdir()
            subprocess.run(['python3', str(bluetooth_importer), 'install', '--inputs', str(dest / 'bluetooth'), '--rootfs', str(target)], check=True)
            assert (target / 'usr/libexec/platform-bluetooth/start').stat().st_mode & 0o777 == 0o755
        _, selected = module.load(dest)
        env = module.env_for(dest, selected, project / 'output')
        assert env['SOC_MODEL'] == soc and env['BOOTFS_BASE_DTB'] == 'board.dtb'
        # Exercise the CI-generated policy, rather than the separate SDK
        # default: its menu timeout must survive U-Boot's decisecond conversion.
        output = project / f'build-{soc}'
        (output / 'images').mkdir(parents=True)
        (output / 'images/root.rootfs.erofs.img').write_bytes(b'fixture')
        (output / 'images/root.rootfs.erofs.img.manifest').write_text('# ubuntu-package-manifest-v1\nfixture 1.0 arm64\n')
        captured_envs = []
        real_run = module.run
        def fixture_run(*args, **kwargs):
            if kwargs.get('env') and args[0] == str(project / 'build.sh') and args[1:] != ('update-engine', '--check'):
                captured_envs.append(kwargs['env'])
            if args[0] == 'cp':
                return real_run(*args, **kwargs)
        module.run = fixture_run
        try:
            module.build(dest, output, 'desktop-xfce')
        finally:
            module.run = real_run
        assert captured_envs and all(e['ROOTFS_PACKAGE_MANIFEST'] == '' for e in captured_envs), 'default build unexpectedly froze packages'
        timeout = int(subprocess.check_output(
            ['bash', '-c', 'source "$1"; printf "%s" "$BOOTFS_TIMEOUT"',
             'boot-policy-qa', str(output / 'bootfs.conf')], text=True))
        assert timeout // 10 > 0, 'SDK U-Boot would wait indefinitely at the boot menu'
        try:
            module.fetch(url, '0' * 64, project / 'corrupt')
        except ValueError:
            pass
        else:
            raise AssertionError('corrupt download accepted')
        assert not (project / 'corrupt').exists()
        server.shutdown()
        # Merely placing a manifest in artifacts does not enable freezing.
        (root / 'manifests').mkdir()
        (root / 'manifests/xfce.manifest').write_text('# ubuntu-package-manifest-v1\nfixture 1.0 arm64\n')
        data['package_manifests'] = {'desktop-xfce': 'manifests/xfce.manifest'}
        (root / 'build.json').write_text(json.dumps(data))
        locked_bundle = project / f'{soc}-locked.tar.zst'
        module.pack(root, locked_bundle)
        # Check that only an explicit product selection reaches build.sh.
        captured_envs.clear()
        module.run = fixture_run
        try:
            module.build(root, output, 'desktop-xfce')
        finally:
            module.run = real_run
        assert captured_envs and all(e['ROOTFS_PACKAGE_MANIFEST'] == str(root / 'manifests/xfce.manifest') for e in captured_envs)
        data['package_manifests']['desktop-xfce'] = '../escape.manifest'
        (root / 'build.json').write_text(json.dumps(data))
        try:
            module.load(root)
        except ValueError:
            pass
        else:
            raise AssertionError('manifest path escape accepted')
        data.pop('package_manifests')
        data['boot']['base_dtb'] = '../../outside.dtb'
        (root / 'build.json').write_text(json.dumps(data))
        try:
            module.load(root)
        except ValueError:
            pass
        else:
            raise AssertionError('path escape accepted')
print('Self-contained RK3576/RK3588 input selection and verified transport passed')

# Upload success is a workflow prerequisite; cleanup itself verifies both copies
# and must leave all files untouched if any guard fails.
with tempfile.TemporaryDirectory() as temp:
    previous_project = module.PROJECT
    previous_cleanup = os.environ.get('CLEAN_CI_WORK')
    module.PROJECT = Path(temp) / 'project'
    output = Path(temp) / 'build'
    images = output / 'images'
    published = module.PROJECT / 'artifacts/server'
    images.mkdir(parents=True)
    published.mkdir(parents=True)
    source = images / 'fixture.rootfs.erofs.img'
    target = published / 'ubuntu-rootfs.img'
    checksum = published / 'ubuntu-rootfs.img.sha256'
    source.write_bytes(b'uploaded image')
    target.write_bytes(source.read_bytes())
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    checksum.write_text(f'{digest}  ubuntu-rootfs.img\n')
    keep = images / 'fixture.rootfs.tar.gz'
    keep.write_bytes(b'preserved base')
    try:
        os.environ.pop('CLEAN_CI_WORK', None)
        try:
            module.clean_cache(output, 'server')
        except ValueError:
            pass
        else:
            raise AssertionError('implicit cleanup accepted')
        os.environ['CLEAN_CI_WORK'] = 'yes'
        target.write_bytes(b'corrupt')
        try:
            module.clean_cache(output, 'server')
        except ValueError:
            pass
        else:
            raise AssertionError('corrupt cache accepted')
        assert source.exists() and target.exists()
        target.unlink()
        target.symlink_to(source)
        try:
            module.clean_cache(output, 'server')
        except ValueError:
            pass
        else:
            raise AssertionError('symlink cache accepted')
        assert source.exists() and target.is_symlink()
        target.unlink()
        target.write_bytes(source.read_bytes())
        module.clean_cache(output, 'server')
        assert not source.exists() and not target.exists()
        assert keep.read_bytes() == b'preserved base' and checksum.exists()
        module.clean_cache(output, 'server')
    finally:
        module.PROJECT = previous_project
        if previous_cleanup is None:
            os.environ.pop('CLEAN_CI_WORK', None)
        else:
            os.environ['CLEAN_CI_WORK'] = previous_cleanup
print('Uploaded image cache checksum and deletion guards passed')
