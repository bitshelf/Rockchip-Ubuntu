#!/usr/bin/env python3
"""Exercise fresh downloads and installed provenance without GitHub access."""
import hashlib
import http.server
import io
import pathlib
import subprocess
import sys
import tempfile
import threading
import zipfile

installer = pathlib.Path(__file__).resolve().parents[2] / "scripts/install-rime-ice.py"
requests = []
archive = b""
failures_remaining = 1

def bundle(marker):
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w") as z:
        for name, content in {
            "rime_ice.schema.yaml": marker, "default.yaml": "schema_list: []",
            "LICENSE": "fixture license",
        }.items():
            z.writestr(name, content)
    return stream.getvalue()

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        global failures_remaining
        requests.append(self.path)
        if failures_remaining:
            failures_remaining -= 1
            self.send_response(503)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(archive)))
        self.end_headers()
        self.wfile.write(archive)
    def log_message(self, *_):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    with tempfile.TemporaryDirectory() as directory:
        root = pathlib.Path(directory)
        (root / "etc").mkdir()
        (root / "etc/passwd").write_text("root:x:0:0::/root:/bin/sh\n")
        url = f"http://127.0.0.1:{server.server_port}/latest/full.zip"
        for marker in ("first-build", "second-build"):
            archive = bundle(marker)
            subprocess.run([sys.executable, str(installer), "--rootfs", str(root), "--url", url], check=True)
            data = root / "etc/skel/.local/share/fcitx5/rime/rime_ice.schema.yaml"
            assert data.read_text() == marker, "cached data survived a new build"
            assert data.parent.stat().st_mode & 0o777 == 0o755
            provenance = (root / "usr/share/doc/rime-ice/SOURCE").read_text()
            assert f"sha256: {hashlib.sha256(archive).hexdigest()}" in provenance
            assert f"requested-url: {url}" in provenance
        assert len(requests) == 3, "a transient failure must retry, and each build must download afresh"
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, "w") as z:
            z.writestr("../escape", "invalid")
        archive = stream.getvalue()
        rejected = subprocess.run([sys.executable, str(installer), "--rootfs", str(root), "--url", url], capture_output=True)
        assert rejected.returncode != 0 and b"unsafe archive member" in rejected.stderr
        assert data.read_text() == "second-build", "rejection altered installed resources"
    print("RIME_ICE_FRESH_DOWNLOAD_PROVENANCE_OK")
finally:
    server.shutdown()
    server.server_close()
