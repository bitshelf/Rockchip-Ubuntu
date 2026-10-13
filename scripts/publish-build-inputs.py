#!/usr/bin/env python3
"""Upload artifacts inputs and select their verified bundle for CI."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import urllib.error
import urllib.request

PROJECT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('provider', choices=('forgejo', 'github'))
    parser.add_argument('--repository', required=True, help='owner/repository')
    parser.add_argument('--server', default='https://github.com')
    parser.add_argument('--inputs', type=Path, default=PROJECT / 'artifacts')
    parser.add_argument('--bundle', type=Path)
    parser.add_argument('--build', action='store_true', help='start rootfs CI after uploading')
    parser.add_argument('--ref', help='source branch for --build; defaults to repository default branch')
    args = parser.parse_args()
    if len(args.repository.split('/')) != 2:
        parser.error('repository must be owner/repository')
    bundle = (args.bundle or args.inputs / 'ubuntu-build-inputs.tar.zst').absolute()
    subprocess.run(['python3', str(PROJECT / 'scripts/build-inputs.py'), 'pack', '--inputs', str(args.inputs.absolute()), '--output', str(bundle)], check=True)
    with bundle.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    tag = 'inputs-' + digest[:16]
    token = os.environ.get('ASSET_TOKEN') or os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN')
    header = os.environ.get('ASSET_AUTH_HEADER')
    if args.provider == 'forgejo' and not header and os.environ.get('FORGEJO_ADMIN_USER') and os.environ.get('FORGEJO_ADMIN_PASSWORD'):
        basic = (os.environ['FORGEJO_ADMIN_USER'] + ':' + os.environ['FORGEJO_ADMIN_PASSWORD']).encode()
        header = 'Authorization: Basic ' + base64.b64encode(basic).decode()
    if not token and not header:
        parser.error('configure upload credentials outside the repository')
    headers = {'Accept': 'application/json'}
    if header:
        key, value = header.split(':', 1)
        headers[key] = value.strip()
    else:
        headers['Authorization'] = ('Bearer ' if args.provider == 'github' else 'token ') + token
    api = 'https://api.github.com' if args.provider == 'github' else args.server.rstrip('/') + '/api/v1'

    def request(path, method='GET', data=None):
        body = None if data is None else json.dumps(data).encode()
        req = urllib.request.Request(api + path, data=body, method=method, headers=headers | {'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(req, timeout=60) as response:
                return response.status, json.loads(response.read() or b'{}')
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return 404, {}
            raise RuntimeError(f'{method} {path}: HTTP {error.code}') from None

    env = os.environ | {'ASSET_PROVIDER': args.provider, 'ASSET_REPOSITORY': args.repository,
        'ASSET_UPLOAD_KIND': 'release', 'ASSET_TAG': tag, 'ASSET_SERVER_URL': args.server, 'PLATFORM_ASSET_BUNDLE': str(bundle)}
    if token:
        env['ASSET_TOKEN'] = token
    if header:
        env['ASSET_AUTH_HEADER'] = header
    if args.provider == 'forgejo':
        env |= {'ASSET_UPLOAD_KIND': 'generic', 'ASSET_PACKAGE_NAME': 'ubuntu-build-inputs'}
        url = f"{args.server.rstrip('/')}/api/packages/{args.repository.split('/')[0]}/generic/ubuntu-build-inputs/{tag}/{bundle.name}"
    else:
        # The release API refuses duplicate attachments; already published input
        # versions are checked by downloading instead of overwriting them.
        status, release = request(f'/repos/{args.repository}/releases/tags/{tag}')
        if status == 200:
            assets = {item['name']: item for item in release.get('assets', [])}
            for name in (bundle.name, bundle.name + '.sha256'):
                if name not in assets:
                    raise RuntimeError('existing input release is incomplete')
            url = assets[bundle.name]['browser_download_url']
            req = urllib.request.Request(assets[bundle.name]['url'], headers=headers | {'Accept': 'application/octet-stream'})
            with urllib.request.urlopen(req, timeout=120) as stream:
                if hashlib.file_digest(stream, 'sha256').hexdigest() != digest:
                    raise RuntimeError('existing release input checksum differs')
            env = None
        else:
            url = f'https://github.com/{args.repository}/releases/download/{tag}/{bundle.name}'
    if env is not None:
        subprocess.run([str(PROJECT / 'scripts/publish-platform-assets.sh')], env=env, check=True)
    for name, value in {'BUILD_INPUTS_URL': url, 'BUILD_INPUTS_SHA256': digest}.items():
        path = f'/repos/{args.repository}/actions/variables/{name}'
        status, _ = request(path)
        if args.provider == 'forgejo':
            request(path, 'POST' if status == 404 else 'PUT', {'value': value})
        elif status == 404:
            request(f'/repos/{args.repository}/actions/variables', 'POST', {'name': name, 'value': value})
        else:
            request(path, 'PATCH', {'name': name, 'value': value})
    if args.build:
        ref = args.ref or request(f'/repos/{args.repository}')[1]['default_branch']
        status, _ = request(f'/repos/{args.repository}/actions/workflows/server.yaml/dispatches', 'POST', {'ref': ref, 'inputs': {}})
        if status == 404:
            raise RuntimeError('push the rootfs workflow to the selected source branch before --build')
        print(f'Rootfs CI requested for {ref}')
    print(json.dumps({'repository': args.repository, 'bundle_url': url, 'sha256': digest, 'input_version': tag}, indent=2))


if __name__ == '__main__':
    main()
