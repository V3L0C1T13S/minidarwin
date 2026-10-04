#!/usr/bin/env python3
"""Create a deterministic GPT disk with EFI and an optional root partition.

This packages boot inputs; it does not turn a rootfs archive into a filesystem.
The optional ramdisk must already contain a filesystem supported by the kernel.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import uuid
import zlib

SECTOR = 512
ESP_TYPE = uuid.UUID("c12a7328-f81f-11d2-ba4b-00a0c93ec93b")
ROOT_TYPE = uuid.UUID("0fc63daf-8483-4772-8e79-3d69d8477de4")
NAMESPACE = uuid.UUID("da41c826-7cac-4870-90ee-12b31d14b270")


def header(current, backup, last_usable, disk_id, entries_lba, entries_crc):
    data = struct.pack("<8sIIIIQQQQ16sQIII", b"EFI PART", 0x10000, 92, 0, 0,
                       current, backup, 34, last_usable, disk_id.bytes_le,
                       entries_lba, 128, 128, entries_crc)
    crc = zlib.crc32(data)
    return (data[:16] + struct.pack("<I", crc) + data[20:]).ljust(SECTOR, b"\0")


def assemble(output, esp, root=None):
    esp_sectors = esp.stat().st_size // SECTOR
    first, last = 2048, 2048 + esp_sectors - 1
    payloads = [(esp, first, last, ESP_TYPE, "MiniDarwin EFI")]
    if root:
        length = root.stat().st_size
        if not length or length % SECTOR:
            raise ValueError('root partition must be nonempty and sector-aligned')
        start = ((last + 1 + 2047) // 2048) * 2048
        last = start + length // SECTOR - 1
        payloads.append((root, start, last, ROOT_TYPE, "MiniDarwin Root"))
    sectors = ((last + 34 + 2047) // 2048) * 2048
    digest = hashlib.sha256()
    for file, _, _, _, _ in payloads:
        digest.update(struct.pack('<Q', file.stat().st_size))
        with file.open("rb") as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(block)
    disk_id = uuid.uuid5(NAMESPACE, digest.hexdigest())
    entries = b''
    for _, start, end, kind, name in payloads:
        partition_id = uuid.uuid5(disk_id, name)
        entries += struct.pack("<16s16sQQQ72s", kind.bytes_le,
                              partition_id.bytes_le, start, end, 0,
                              name.encode("utf-16le").ljust(72, b"\0"))
    entries = entries.ljust(128 * 128, b"\0")
    entries_crc = zlib.crc32(entries)
    mbr = bytearray(SECTOR)
    mbr[446:462] = struct.pack("<B3sB3sII", 0, b"\0\2\0", 0xEE,
                               b"\xff\xff\xff", 1, min(sectors - 1, 0xFFFFFFFF))
    mbr[510:512] = b"\x55\xaa"
    with output.open("wb") as disk:
        disk.truncate(sectors * SECTOR)
        disk.write(mbr)
        disk.write(header(1, sectors - 1, sectors - 34, disk_id, 2, entries_crc))
        disk.write(entries)
        for file, start, _, _, _ in payloads:
            disk.seek(start * SECTOR)
            with file.open("rb") as source:
                shutil.copyfileobj(source, disk)
        disk.seek((sectors - 33) * SECTOR)
        disk.write(entries)
        disk.write(header(sectors - 1, 1, sectors - 34, disk_id,
                          sectors - 33, entries_crc))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--loader", required=True, type=Path)
    parser.add_argument("--kernel", type=Path)
    parser.add_argument("--ramdisk", type=Path)
    parser.add_argument("--root-partition", type=Path)
    parser.add_argument("--boot-args", default="-v serial=3 keepsyms=1")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    files = [(args.loader, "::/EFI/BOOT/BOOTX64.EFI")]
    if args.kernel:
        files.append((args.kernel, "::/EFI/BOOT/kernel"))
    if args.ramdisk:
        files.append((args.ramdisk, "::/ramdisk.img"))
    payload_size = sum(source.stat().st_size for source, _ in files)
    # FAT metadata and enough free clusters for the largest supported payload.
    size = max(64 * 1024 * 1024, payload_size * 2 + 32 * 1024 * 1024)
    size = ((size + 1024 * 1024 - 1) // (1024 * 1024)) * 1024 * 1024
    env = os.environ.copy()
    env.update(TZ="UTC", MTOOLS_SKIP_CHECK="1", SOURCE_DATE_EPOCH="315532800")
    with tempfile.TemporaryDirectory(prefix="minidarwin-efi-") as tmp:
        tmp = Path(tmp)
        esp = tmp / "esp.img"
        with esp.open("wb") as stream:
            stream.truncate(size)

        def run(tool, *arguments):
            subprocess.run([tool, "-i", str(esp), *arguments], check=True, env=env)

        run("mformat", "-F", "-T", str(size // SECTOR), "-N", "0x4d444152",
            "-v", "MINIDARWIN", "::")
        run("mmd", "::/EFI", "::/EFI/BOOT")
        boot_args = tmp / "boot-args.txt"
        boot_args.write_text(args.boot_args + "\n")
        files.append((boot_args, "::/EFI/BOOT/boot-args.txt"))
        # mcopy -m uses source mtimes. Staging fixes those without changing inputs.
        for index, (source, destination) in enumerate(files):
            staged = tmp / f"payload-{index}"
            shutil.copyfile(source, staged)
            os.utime(staged, (315532800, 315532800))  # FAT's epoch, 1980-01-01.
            run("mcopy", "-m", str(staged), destination)
        assemble(args.output, esp, args.root_partition)


if __name__ == "__main__":
    main()
