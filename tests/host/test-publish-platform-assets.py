#!/usr/bin/env python3
"""Exercise actual HTTP upload formats against a local release API fixture."""
import hashlib
import json
import os
import shutil
from pathlib import Path
import subprocess
import tempfile
import threading
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

repo = Path(__file__).resolve().parents[2]
received = []
packages = {}
expected_authorization = None

class ReleaseAPI(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def require_auth(self):
        assert self.headers.get('Authorization') == expected_authorization

    def do_PUT(self):
        self.require_auth()
        assert self.path.startswith('/api/packages/test/generic/')
        assert self.headers['Content-Type'] == 'application/octet-stream'
        assert self.path not in packages
        packages[self.path] = self.rfile.read(int(self.headers['Content-Length']))
        self.send_response(201)
        self.end_headers()

    def do_GET(self):
        self.require_auth()
        if self.path.startswith('/api/packages/'):
            self.send_response(200 if self.path in packages else 404)
            self.end_headers()
            self.wfile.write(packages.get(self.path, b''))
            return
        payload = json.dumps({"id": 1, "assets": [], "upload_url": f"http://127.0.0.1:{self.server.server_port}/upload{{?name}}"}).encode()
        self.send_response(200)
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        self.require_auth()
        body = self.rfile.read(int(self.headers['Content-Length']))
        name = parse_qs(urlparse(self.path).query)['name'][0]
        if self.path.startswith('/upload'):
            assert self.headers['Content-Type'] == 'application/octet-stream'
            content = body
        else:
            assert self.headers['Content-Type'].startswith('multipart/form-data;')
            message = BytesParser().parsebytes(b'Content-Type: ' + self.headers['Content-Type'].encode() + b'\r\nMIME-Version: 1.0\r\n\r\n' + body)
            parts = [part for part in message.walk() if part.get_param('name', header='Content-Disposition') == 'attachment']
            assert len(parts) == 1 and parts[0].get_filename() == name
            content = parts[0].get_payload(decode=True)
        received.append((name, content))
        self.send_response(201)
        self.end_headers()
        self.wfile.write(b'{}')

with tempfile.TemporaryDirectory() as tmp:
    bin_dir = Path(tmp)/'bin'
    bin_dir.mkdir()
    argv_log = Path(tmp)/'curl-argv.jsonl'
    real_curl = shutil.which('curl')
    wrapper = bin_dir/'curl'
    wrapper.write_text('#!/usr/bin/env python3\n'
        'import json, os, pathlib, stat, sys\n'
        'paths=[a[1:] for a in sys.argv[1:] if a.startswith("@")]\n'
        'for name in paths: assert stat.S_IMODE(os.stat(name).st_mode)==0o600\n'
        'for key in ("ASSET_TOKEN","ASSET_AUTH_HEADER","GH_TOKEN","GITHUB_TOKEN","FORGEJO_ADMIN_PASSWORD"): assert key not in os.environ\n'
        'with open('+repr(str(argv_log))+',"a") as f: f.write(json.dumps({"argv":sys.argv[1:],"private_files":paths})+"\\n")\n'
        'os.execv('+repr(real_curl)+',['+repr(real_curl)+',*sys.argv[1:]])\n')
    wrapper.chmod(0o755)
    bundle = Path(tmp)/'platform-assets-test.tar.zst'
    bundle.write_bytes(b'asset-fixture\x00\x01')
    checksum = Path(str(bundle)+'.sha256')
    checksum.write_text(f'{hashlib.sha256(bundle.read_bytes()).hexdigest()}  {bundle.name}\n')
    server = ThreadingHTTPServer(('127.0.0.1', 0), ReleaseAPI)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    address = f'http://127.0.0.1:{server.server_port}'
    fixture_env = {k:v for k,v in os.environ.items() if k not in ('ASSET_TOKEN','ASSET_AUTH_HEADER','GH_TOKEN','GITHUB_TOKEN','FORGEJO_ADMIN_USER','FORGEJO_ADMIN_PASSWORD')}
    for provider in ('github', 'forgejo'):
        expected_authorization = ('Bearer ' if provider=='github' else 'token ') + 'local-fixture-only'
        env = fixture_env | {'PATH': str(bin_dir)+os.pathsep+os.environ['PATH'], 'ASSET_PROVIDER': provider, 'ASSET_REPOSITORY':'test/assets', 'ASSET_TAG':'fixture', 'ASSET_TOKEN':'local-fixture-only', 'PLATFORM_ASSET_BUNDLE':str(bundle), 'ASSET_API_URL':address, 'ASSET_SERVER_URL':address}
        result = subprocess.run(['bash', '-x', str(repo/'scripts/publish-platform-assets.sh')], env=env, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        assert b'local-fixture-only' not in result.stderr
        assert received[-2:] == [(bundle.name, bundle.read_bytes()), (checksum.name, checksum.read_bytes())]
    env = env | {'ASSET_UPLOAD_KIND': 'generic'}
    for _ in range(2):
        subprocess.run(['bash', str(repo/'scripts/publish-platform-assets.sh')], env=env, check=True, stdout=subprocess.DEVNULL)
    assert list(packages.values()) == [bundle.read_bytes(), checksum.read_bytes()]
    expected_authorization = 'Basic Zml4dHVyZTpvbmx5'
    subprocess.run(['bash', str(repo/'scripts/publish-platform-assets.sh')], env=env | {'ASSET_AUTH_HEADER':'Authorization: '+expected_authorization}, check=True, stdout=subprocess.DEVNULL)
    before = argv_log.read_text()
    result = subprocess.run(['bash', str(repo/'scripts/publish-platform-assets.sh')], env=env | {'ASSET_AUTH_HEADER':'Authorization: invalid\nX-Injected: true'}, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    assert result.returncode != 0 and argv_log.read_text() == before
    expected_authorization = 'token local-fixture-only'
    remote_path = next(iter(packages))
    packages[remote_path] = b'remote-corruption'
    result = subprocess.run(['bash', str(repo/'scripts/publish-platform-assets.sh')], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    assert result.returncode != 0 and packages[remote_path] == b'remote-corruption'
    previous_count = len(received)
    bundle.write_bytes(b'corrupt')
    result = subprocess.run(['bash', str(repo/'scripts/publish-platform-assets.sh')], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    assert result.returncode != 0 and len(received) == previous_count
    rows = [json.loads(line) for line in argv_log.read_text().splitlines()]
    assert rows and all(row['private_files'] for row in rows)
    assert all('local-fixture-only' not in ' '.join(row['argv']) and 'Zml4dHVyZTpvbmx5' not in ' '.join(row['argv']) for row in rows)
    assert all(not Path(name).exists() for row in rows for name in row['private_files'])
    server.shutdown()
print('GitHub/Forgejo authenticated HTTP uploads, private credential transport, cleanup and corrupt-bundle rejection passed')
