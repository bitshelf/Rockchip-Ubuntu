#!/usr/bin/env python3
"""Check portable input selection, archive transport and hostile path rejection."""
import hashlib
import importlib.util
import json
import os
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
        _, selected = module.load(dest)
        env = module.env_for(dest, selected, project / 'output')
        assert env['SOC_MODEL'] == soc and env['BOOTFS_BASE_DTB'] == 'board.dtb'
        # Exercise the CI-generated policy, rather than the separate SDK
        # default: its menu timeout must survive U-Boot's decisecond conversion.
        output = project / f'build-{soc}'
        (output / 'images').mkdir(parents=True)
        (output / 'images/root.rootfs.erofs.img').write_bytes(b'fixture')
        real_run = module.run
        def fixture_run(*args, **kwargs):
            if args[0] == 'cp':
                return real_run(*args, **kwargs)
        module.run = fixture_run
        try:
            module.build(dest, output, 'desktop-xfce')
        finally:
            module.run = real_run
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
        data['boot']['base_dtb'] = '../../outside.dtb'
        (root / 'build.json').write_text(json.dumps(data))
        try:
            module.load(root)
        except ValueError:
            pass
        else:
            raise AssertionError('path escape accepted')
print('Self-contained RK3576/RK3588 input selection and verified transport passed')
