#!/usr/bin/env python3
"""Verify fileset headers and identities independently of the assembler."""
from pathlib import Path
import struct
import sys

image = Path(sys.argv[1]).read_bytes()
magic, cpu, subtype, kind, count, size, flags, reserved = struct.unpack_from('<8I', image)
assert magic == 0xFEEDFACF and cpu == 0x01000007 and kind == 12
assert flags & 0x80000000, 'kernel must be marked MH_DYLIB_IN_CACHE'
end = 32 + size
assert end <= len(image)
offset = 32
entries = []
segments = []
thread = False
for _ in range(count):
    command, length = struct.unpack_from('<2I', image, offset)
    assert length >= 8 and length % 8 == 0 and offset + length <= end
    assert command != 0x1D, 'raw kernel signature is invalid after fileset conversion'
    if command == 0x80000035:
        assert length >= 32
        vmaddr, fileoff, nameoff, entry_reserved = struct.unpack_from('<QQII', image, offset + 8)
        assert 32 <= nameoff < length and entry_reserved == 0
        name = image[offset + nameoff:offset + length].split(b'\0', 1)[0]
        entries.append((name, vmaddr, fileoff))
    elif command == 0x19:
        assert length >= 72
        vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<4Q', image, offset + 24)
        assert fileoff + filesize <= len(image)
        segments.append((vmaddr, vmsize, fileoff, filesize))
    elif command == 5:
        thread = True
    offset += length
assert offset == end and thread
expected = [b'com.apple.kernel', *(s.encode() for s in sys.argv[2:])]
assert [e[0] for e in entries] == expected, 'fileset entry identities/order'
assert len(set(expected)) == len(expected)
for name, vm, off in entries[1:]:
    assert off + 32 <= len(image)
    nested = struct.unpack_from('<8I', image, off)
    assert nested[0] == 0xFEEDFACF and nested[1] == cpu and nested[3] == 11
    assert any(base <= vm < base + n for base, n, _, _ in segments)
_, header_vm, header_fileoff = entries[0]
assert header_fileoff == 0
assert any(vm == header_vm and off == 0 and n >= end for vm, _, off, n in segments)
print(f'x86_64 MH_FILESET verified: kernel and {len(entries)-1} drivers')
