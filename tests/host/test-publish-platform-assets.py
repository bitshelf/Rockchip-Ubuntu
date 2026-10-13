#!/usr/bin/env python3
"""Exercise actual HTTP upload formats against a local release API fixture."""
import hashlib
import json
import os
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

class ReleaseAPI(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_PUT(self):
        assert self.path.startswith('/api/packages/test/generic/')
        assert self.headers['Content-Type'] == 'application/octet-stream'
        assert self.path not in packages
        packages[self.path] = self.rfile.read(int(self.headers['Content-Length']))
        self.send_response(201)
        self.end_headers()

    def do_GET(self):
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
    bundle = Path(tmp)/'platform-assets-test.tar.zst'
    bundle.write_bytes(b'asset-fixture\x00\x01')
    checksum = Path(str(bundle)+'.sha256')
    checksum.write_text(f'{hashlib.sha256(bundle.read_bytes()).hexdigest()}  {bundle.name}\n')
    server = ThreadingHTTPServer(('127.0.0.1', 0), ReleaseAPI)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    address = f'http://127.0.0.1:{server.server_port}'
    for provider in ('github', 'forgejo'):
        env = os.environ | {'ASSET_PROVIDER': provider, 'ASSET_REPOSITORY':'test/assets', 'ASSET_TAG':'fixture', 'ASSET_TOKEN':'local-fixture-only', 'PLATFORM_ASSET_BUNDLE':str(bundle), 'ASSET_API_URL':address, 'ASSET_SERVER_URL':address}
        subprocess.run(['bash', str(repo/'scripts/publish-platform-assets.sh')], env=env, check=True, stdout=subprocess.DEVNULL)
        assert received[-2:] == [(bundle.name, bundle.read_bytes()), (checksum.name, checksum.read_bytes())]
    env = env | {'ASSET_UPLOAD_KIND': 'generic'}
    for _ in range(2):
        subprocess.run(['bash', str(repo/'scripts/publish-platform-assets.sh')], env=env, check=True, stdout=subprocess.DEVNULL)
    assert list(packages.values()) == [bundle.read_bytes(), checksum.read_bytes()]
    remote_path = next(iter(packages))
    packages[remote_path] = b'remote-corruption'
    result = subprocess.run(['bash', str(repo/'scripts/publish-platform-assets.sh')], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    assert result.returncode != 0 and packages[remote_path] == b'remote-corruption'
    previous_count = len(received)
    bundle.write_bytes(b'corrupt')
    result = subprocess.run(['bash', str(repo/'scripts/publish-platform-assets.sh')], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    assert result.returncode != 0 and len(received) == previous_count
    server.shutdown()
print('GitHub/Forgejo HTTP uploads and corrupt-bundle rejection passed')
