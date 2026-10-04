#!/usr/bin/env python3
"""Verify the standalone loader's Mach-O type and load-command contract."""
from pathlib import Path
import struct
import sys

blob = Path(sys.argv[1]).read_bytes()
magic, cpu, subtype, kind, count, size, flags, reserved = struct.unpack_from('<8I', blob)
assert magic == 0xfeedfacf and cpu == 0x01000007 and kind == 7, 'not an x86_64 MH_DYLINKER'
offset = 32
assert offset + size <= len(blob), 'truncated commands'
seen = set()
for _ in range(count):
    cmd, length = struct.unpack_from('<II', blob, offset)
    assert length >= 8 and offset + length <= 32 + size, 'invalid command'
    assert cmd not in (0xc, 0x18, 0x80000018, 0x8000001f, 0x80000023), 'dynamic library dependency'
    if cmd == 0xf:  # LC_ID_DYLINKER
        start = struct.unpack_from('<I', blob, offset + 8)[0]
        assert 12 <= start < length
        assert blob[offset + start:offset + length].split(b'\0', 1)[0] == b'/usr/lib/dyld'
    seen.add(cmd)
    offset += length
assert offset == 32 + size
assert 0xf in seen and (5 in seen or 0x80000028 in seen), 'missing identity or entry'
assert 0x1d in seen, 'missing code signature'
