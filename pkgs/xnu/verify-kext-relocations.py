#!/usr/bin/env python3
"""Independently compare every Apple-linker relocation against final KC bytes."""
from pathlib import Path
import plistlib
import struct
import sys


def macho(data, header=0):
    magic, cpu, subtype, kind, count, size, flags, reserved = struct.unpack_from('<8I', data, header)
    assert magic == 0xFEEDFACF and cpu == 0x01000007
    end = header + 32 + size
    assert end <= len(data)
    off = header + 32
    segments, entries, symbols, dynamic = [], {}, None, None
    for _ in range(count):
        command, length = struct.unpack_from('<2I', data, off)
        assert length >= 8 and off + length <= end
        if command == 0x19:
            segments.append(struct.unpack_from('<4Q', data, off + 24))
        elif command == 2:
            symbols = struct.unpack_from('<4I', data, off + 8)
        elif command == 0xb:
            dynamic = struct.unpack_from('<18I', data, off + 8)
        elif command == 0x80000035:
            vm, file, name, reserved = struct.unpack_from('<QQII', data, off + 8)
            identifier = data[off+name:off+length].split(b'\0',1)[0].decode()
            entries[identifier] = (vm,file)
        off += length
    assert off == end
    return segments, entries, symbols, dynamic


def fileoff(segments, vm, size):
    for base, span, off, count in segments:
        if base <= vm and vm - base + size <= count:
            return off + vm - base
    raise AssertionError(f'pointer location outside file-backed segments: {vm:#x}')


def exports(data, table, slide):
    off, count, strings, length = table
    assert off + count*16 <= len(data) and strings+length <= len(data)
    result, names = {}, []
    for i in range(count):
        name, type, section, desc, value = struct.unpack_from('<IBBHQ', data, off + i*16)
        assert name < length
        start = strings + name
        end = data.find(b'\0', start, strings + length)
        assert end >= start
        name = data[start:end].decode()
        names.append(name)
        if type & 0xe0 or not type & 1:
            continue
        if type & 0xe == 14:
            result[name] = value + slide
        elif type & 0xe == 2:
            result[name] = value
    return result, names


collection = Path(sys.argv[1]).read_bytes()
outer_segments, entries, _, _ = macho(collection)
kernel = Path(sys.argv[2]).read_bytes()
_, _, symbol_table, _ = macho(kernel)
available, _ = exports(kernel, symbol_table, 0)
relocations = 0
for path in map(Path, sys.argv[3:]):
    info = plistlib.loads((path/'Contents/Info.plist').read_bytes())
    original = (path/'Contents/MacOS'/info['CFBundleExecutable']).read_bytes()
    vm, header = entries[info['CFBundleIdentifier']]
    final_segments, _, _, _ = macho(collection, header)
    segments, _, table, dynamic = macho(original)
    assert min(s[0] for s in segments) == 0
    defined, names = exports(original, table, vm)
    available.update(defined)
    for external, offset, count in ((False,dynamic[16],dynamic[17]), (True,dynamic[14],dynamic[15])):
        assert offset + count*8 <= len(original)
        for i in range(count):
            address, bits = struct.unpack_from('<iI',original,offset + i*8)
            symbol, pcrel, width, ext, kind = bits&0xffffff, (bits>>24)&1, 1<<((bits>>25)&3), (bits>>27)&1, bits>>28
            assert ext == external and address >= 0
            before = fileoff(segments,address,width)
            # The loader maps the outer PRELINK_TEXT segment. Nested kext
            # headers retain image-relative file offsets.
            after = fileoff(outer_segments,vm+address,width)
            assert after+width <= len(collection)
            if not external:
                assert kind==0 and width==8 and not pcrel
                expected = struct.unpack_from('<Q',original,before)[0] + vm
                actual = struct.unpack_from('<Q',collection,after)[0]
            else:
                target = available[names[symbol]]
                if kind==0:
                    assert width==8 and not pcrel
                    expected = target + struct.unpack_from('<Q',original,before)[0]
                    actual = struct.unpack_from('<Q',collection,after)[0]
                else:
                    assert kind==2 and width==4 and pcrel
                    expected = target - (vm+address+4) + struct.unpack_from('<i',original,before)[0]
                    actual = struct.unpack_from('<i',collection,after)[0]
            assert actual == expected, (info['CFBundleIdentifier'],address,hex(actual),hex(expected))
            relocations += 1
print(f'{relocations} kext pointer/call relocations independently verified')
