#!/usr/bin/env python3
"""Reject modules and SDK header packages built for another kernel."""
import argparse
from pathlib import Path
import struct
import subprocess
import tarfile


def module_release(path):
    data = path.read_bytes()
    if len(data) < 64 or data[:6] != b'\x7fELF\x02\x01':
        raise ValueError(f'not an ELF64 little-endian module: {path}')
    if struct.unpack_from('<HH', data, 16) != (1, 183):
        raise ValueError(f'not an ARM64 relocatable module: {path}')
    offset = struct.unpack_from('<Q', data, 40)[0]
    size, count, names_index = struct.unpack_from('<HHH', data, 58)
    if size != 64 or not count or names_index >= count or offset + count * size > len(data):
        raise ValueError(f'invalid ELF sections: {path}')
    sections = [struct.unpack_from('<IIQQQQIIQQ', data, offset + i * size) for i in range(count)]
    def contents(section):
        start, length = section[4:6]
        if start + length > len(data):
            raise ValueError(f'truncated ELF section: {path}')
        return data[start:start + length]
    names = contents(sections[names_index])
    versions = []
    for section in sections:
        name = names[section[0]:].split(b'\0', 1)[0]
        if name == b'.modinfo':
            versions += [value[9:].split()[0].decode('ascii') for value in contents(section).split(b'\0')
                         if value.startswith(b'vermagic=') and value[9:].split()]
    if len(versions) != 1:
        raise ValueError(f'missing or ambiguous module vermagic: {path}')
    return versions[0]


def check_headers(path, release):
    expected = f'usr/src/linux-headers-{release}/include/config/kernel.release'
    found = False
    process = subprocess.Popen(['dpkg-deb', '--fsys-tarfile', str(path)], stdout=subprocess.PIPE)
    try:
        with tarfile.open(fileobj=process.stdout, mode='r|') as archive:
            for member in archive:
                if member.name.removeprefix('./') == expected:
                    if not member.isfile() or member.size > 256:
                        raise ValueError(f'invalid headers kernel.release: {path}')
                    found = archive.extractfile(member).read().decode('ascii').strip() == release
        if process.wait() != 0:
            raise ValueError(f'cannot inspect headers DEB: {path}')
    finally:
        process.stdout.close()
        if process.poll() is None:
            process.terminate()
            process.wait()
    if not found:
        raise ValueError(f'headers do not match kernel {release}: {path}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--release', required=True)
    parser.add_argument('--module', type=Path, action='append', default=[])
    parser.add_argument('--headers', type=Path, action='append', default=[])
    args = parser.parse_args()
    try:
        for path in args.module:
            if module_release(path) != args.release:
                raise ValueError(f'module vermagic does not match kernel {args.release}: {path}')
        for path in args.headers:
            check_headers(path, args.release)
    except (OSError, ValueError, struct.error, UnicodeError, tarfile.TarError) as error:
        parser.exit(1, f'ERROR: {error}\n')
    print(f'KERNEL_ASSET_MATCH_OK release={args.release} modules={len(args.module)} headers={len(args.headers)}')


if __name__ == '__main__':
    main()
