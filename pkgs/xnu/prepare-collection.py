#!/usr/bin/env python3
"""Remove the raw kernel signature invalidated by fileset header conversion.

Compacting load commands preserves every segment and payload file offset. The
unused signature blob remains in LINKEDIT; no valid signature is advertised.
"""
from pathlib import Path
import struct
import sys

path = Path(sys.argv[1])
image = bytearray(path.read_bytes())
magic, cpu, subtype, kind, count, size, flags, reserved = struct.unpack_from('<8I', image)
assert magic == 0xFEEDFACF and kind == 12
end = 32 + size
assert end <= len(image)
offset = 32
commands = []
removed = 0
for _ in range(count):
    command, length = struct.unpack_from('<2I', image, offset)
    assert length >= 8 and length % 8 == 0 and offset + length <= end
    if command == 0x1D:  # LC_CODE_SIGNATURE
        assert length == 16
        blob_offset, blob_size = struct.unpack_from('<2I', image, offset + 8)
        assert blob_offset + blob_size <= len(image)
        removed += 1
    else:
        commands.append(image[offset:offset + length])
    offset += length
assert offset == end and removed <= 1
new = b''.join(commands)
image[32:end] = new + bytes(size - len(new))
struct.pack_into('<2I', image, 16, count - removed, len(new))
path.write_bytes(image)
