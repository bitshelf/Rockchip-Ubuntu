"""Write a minimal ARM64 ET_REL with a real .modinfo section for host fixtures."""
import struct
import sys
from pathlib import Path

path, release = Path(sys.argv[1]), sys.argv[2]
names = b'\0.shstrtab\0.modinfo\0'
info = b'vermagic=' + release.encode() + b' SMP preempt_rt aarch64\0license=GPL\0'
sections = (64 + len(names) + len(info) + 7) & ~7
ident = b'\x7fELF\x02\x01\x01' + bytes(9)
header = struct.pack('<16sHHIQQQIHHHHHH', ident, 1, 183, 1, 0, 0, sections,
                     0, 64, 0, 0, 64, 3, 1)
data = header + names + info
data += bytes(sections - len(data)) + bytes(64)
data += struct.pack('<IIQQQQIIQQ', 1, 3, 0, 0, 64, len(names), 0, 0, 1, 0)
data += struct.pack('<IIQQQQIIQQ', 11, 1, 0, 0, 64 + len(names), len(info), 0, 0, 1, 0)
path.write_bytes(data)
