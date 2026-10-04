#!/usr/bin/env python3
"""Verify GPT, FAT payloads, repeatability, and EFI loading under QEMU TCG."""
import argparse
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import zlib
import uuid


def verify_gpt(path):
    data = path.read_bytes()
    assert data[510:512] == b"\x55\xaa" and data[450] == 0xEE
    headers = []
    for offset in (512, len(data) - 512):
        header = bytearray(data[offset:offset + 92])
        assert header[:8] == b"EFI PART"
        crc, = struct.unpack_from("<I", header, 16)
        struct.pack_into("<I", header, 16, 0)
        assert zlib.crc32(header) == crc
        current, backup = struct.unpack_from("<QQ", header, 24)
        assert current * 512 == offset and backup in (1, len(data) // 512 - 1)
        table_lba, count, entry_size, table_crc = struct.unpack_from("<QIII", header, 72)
        table = data[table_lba * 512:table_lba * 512 + count * entry_size]
        assert len(table) == count * entry_size and zlib.crc32(table) == table_crc
        headers.append((header, table))
    assert headers[0][1] == headers[1][1]
    first, last = struct.unpack_from("<QQ", headers[0][1], 32)
    assert first == 2048 and first < last < len(data) // 512 - 33
    return first * 512


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--loader", required=True, type=Path)
    parser.add_argument("--qemu", required=True)
    parser.add_argument("--firmware-code", required=True, type=Path)
    parser.add_argument("--firmware-vars", required=True, type=Path)
    args = parser.parse_args()
    assembler = Path(__file__).with_name("make-efi-disk.py")
    with tempfile.TemporaryDirectory(prefix="minidarwin-boot-test-") as tmp:
        tmp = Path(tmp)
        kernel = tmp / "invalid-kernel"
        kernel.write_bytes(b"invalid-kernel")
        # Deliberately malformed: reaching its parse error proves the handoff
        # without claiming that an actual XNU kernel has booted.
        images = [tmp / "first.img", tmp / "second.img"]
        root = tmp / 'root-partition.img'
        root.write_bytes(bytes(range(256)) * 8)
        for disk in images:
            subprocess.run([sys.executable, str(assembler), "--loader", str(args.loader),
                            "--kernel", str(kernel), "--boot-args", "-v serial=3",
                            "--root-partition", str(root), "--output", str(disk)], check=True)
        assert images[0].read_bytes() == images[1].read_bytes(), "disk is not reproducible"
        offset = verify_gpt(images[0])
        data = images[0].read_bytes()
        entry = data[2 * 512 + 128:2 * 512 + 256]
        assert uuid.UUID(bytes_le=entry[:16]) == uuid.UUID('0fc63daf-8483-4772-8e79-3d69d8477de4')
        first, last = struct.unpack_from('<QQ', entry, 32)
        assert first % 2048 == 0 and first > offset // 512
        assert data[first * 512:(last + 1) * 512] == root.read_bytes()
        image_arg = f"{images[0]}@@{offset}"
        for file, expected in (("BOOTX64.EFI", args.loader.read_bytes()),
                               ("kernel", kernel.read_bytes()),
                               ("boot-args.txt", b"-v serial=3\n")):
            result = subprocess.check_output(["mtype", "-i", image_arg, f"::/EFI/BOOT/{file}"])
            assert result == expected, f"wrong FAT contents for {file}"
        vars_file = tmp / "vars.fd"
        shutil.copyfile(args.firmware_vars, vars_file)
        log = tmp / "serial.log"
        command = [args.qemu, "-machine", "q35", "-cpu", "max,vendor=GenuineIntel,family=6,model=60,stepping=3", "-accel", "tcg", "-m", "512",
                   "-object", "rng-random,id=rng0,filename=/dev/urandom", "-device", "virtio-rng-pci,rng=rng0",
                   "-d", "cpu_reset,guest_errors", "-D", str(tmp / "debug.log"),
                   "-drive", f"if=pflash,format=raw,readonly=on,file={args.firmware_code}",
                   "-drive", f"if=pflash,format=raw,file={vars_file}",
                   "-drive", f"file={images[0]},format=raw,snapshot=on",
                   "-serial", f"file:{log}", "-serial", "null", "-serial", "null",
                   "-display", "none", "-monitor", "none", "-net", "none", "-no-reboot"]
        with (tmp / "qemu.log").open("wb") as stderr:
            process = subprocess.Popen(command, stdout=stderr, stderr=stderr)
            try:
                deadline = time.monotonic() + 120
                while time.monotonic() < deadline:
                    text = log.read_text(errors="replace") if log.exists() else ""
                    if "failed to parse Mach-O: Invalid Parameter" in text:
                        assert "XNU EFI loader start" in text
                        assert "kernel size: 14 bytes" in text
                        print("GPT/FAT repeatability and QEMU EFI handoff passed")
                        return
                    if process.poll() is not None:
                        break
                    time.sleep(0.1)
                print(text)
                print((tmp / "qemu.log").read_text(errors="replace"))
                debug = tmp / "debug.log"
                if debug.exists():
                    print(debug.read_text(errors="replace")[-12000:])
                raise AssertionError("QEMU did not reach the loader's kernel parse check")
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


if __name__ == "__main__":
    main()
