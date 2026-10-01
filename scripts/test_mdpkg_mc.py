#!/usr/bin/env python3
"""Installs the pinned Midnight Commander package into a copy of the x86_64
rootfs with the bootstrap mdpkg and its sandbox runner, and checks the result
independently of mdpkg. Run outside Nix: sandbox-exec cannot nest in Nix's
sandbox. The installed root and report.json are kept for inspection.

Apple's lsbom and pkgutil are used read-only, as format oracles."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import struct
import subprocess
import sys
import tempfile

from test_mdpkg import component_files, read_odc, read_xar, xar

MDROOTFS = Path(__file__).resolve().parent / "mdrootfs.py"
MC_SHA256 = "5b047f602247de2b9cd9f4ed6f4b95fb9083a18a6435477dacbfac5f36bfa030"


def tree(root):
    entries = {}
    def walk(directory):
        for item in sorted(directory.iterdir()):
            relative = item.relative_to(root).as_posix()
            mode = item.lstat().st_mode
            if stat.S_ISLNK(mode):
                entries[relative] = {"type": "symlink", "target": os.readlink(item)}
            elif stat.S_ISDIR(mode):
                entries[relative] = {"type": "directory", "mode": stat.S_IMODE(mode)}
                walk(item)
            elif stat.S_ISREG(mode):
                entries[relative] = {"type": "file", "mode": stat.S_IMODE(mode),
                                     "sha256": hashlib.sha256(item.read_bytes()).hexdigest()}
            else:
                raise AssertionError(f"unsupported filesystem object: {item}")
    walk(root)
    return entries


def macho_libraries(binary):
    data = binary.read_bytes()
    assert data[:4] == b"\xcf\xfa\xed\xfe"
    cpu, subtype, kind, commands = struct.unpack("<IIII", data[4:20])
    assert cpu == 0x1000007, "MC fixture must be x86_64"
    libraries = []
    offset = 32
    for _ in range(commands):
        command, length = struct.unpack("<II", data[offset:offset + 8])
        if command in (12, 0x80000018, 0x8000001F):
            name_offset = struct.unpack("<I", data[offset + 8:offset + 12])[0]
            libraries.append(data[offset + name_offset:offset + length].split(b"\0")[0].decode())
        offset += length
    return libraries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release", required=True, type=Path,
                        help="an x86_64 rootfsRelease output (bundle and manifest)")
    parser.add_argument("--installer", required=True, type=Path)
    parser.add_argument("--runner", required=True, type=Path)
    parser.add_argument("--pkg", required=True, type=Path)
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    assert hashlib.sha256(args.pkg.read_bytes()).hexdigest() == MC_SHA256
    release = args.release.resolve(strict=True)
    [bundle] = release.glob("*.bundle.zip")
    [manifest] = release.glob("*.manifest.yaml")
    assert "-x86_64-" in bundle.name, "use the x86_64 release: MC is an x86_64 package"
    if args.output_dir:
        output = args.output_dir.absolute()
        output.mkdir(mode=0o700, parents=False, exist_ok=False)
    else:
        output = Path(tempfile.mkdtemp(prefix="minidarwin-mc-proof-"))
    output = output.resolve()
    root = output / "root"
    # The released tree, verified and extracted with the release's own tool,
    # has the canonical modes a user's root would have.
    subprocess.run([sys.executable, str(MDROOTFS), "verify", "--bundle", str(bundle),
                    "--extract-to", str(root)], check=True, stdout=subprocess.DEVNULL)
    before = tree(root)
    sentinel = output / "outside-sentinel"
    sentinel.write_bytes(b"outside unchanged\n")
    command = [str(args.installer.resolve()), "install", "-pkg", str(args.pkg.resolve()),
               "-root", str(root), "-script-runner", str(args.runner.resolve())]
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (output / "install.log").write_text(result.stdout)
    assert result.returncode == 0, result.stdout
    after = tree(root)
    for name, metadata in before.items():
        assert after.get(name) == metadata, f"base changed: {name}"
    # The installed root still verifies as the release, plus extra files.
    verified = subprocess.run([sys.executable, str(MDROOTFS), "verify", "--manifest", str(manifest),
                               "--tree", str(root), "--allow-extra"], capture_output=True, text=True)
    (output / "base-verification.log").write_text(verified.stdout + verified.stderr)
    assert verified.returncode == 0, verified.stdout + verified.stderr
    assert sentinel.read_bytes() == b"outside unchanged\n"
    package = read_xar(args.pkg)
    payload = read_odc(package["mcinstall.pkg/Payload"])
    assert len(payload) == 392
    for name, mode, uid, gid, value in payload:
        if not name:
            continue
        path = root / name
        st = path.lstat()
        assert stat.S_IFMT(st.st_mode) == stat.S_IFMT(mode), f"type: {name}"
        if stat.S_ISREG(mode):
            assert path.read_bytes() == value, f"content: {name}"
            assert stat.S_IMODE(st.st_mode) == stat.S_IMODE(mode), f"mode: {name}"
        elif stat.S_ISLNK(mode):
            assert os.readlink(path) == value.decode(), f"symlink: {name}"
        elif name not in before:
            assert stat.S_IMODE(st.st_mode) == stat.S_IMODE(mode), f"directory mode: {name}"
    defaults = root / "usr/local/etc/mc.default"
    configurations = []
    for source in sorted(defaults.iterdir()):
        destination = root / "usr/local/etc/mc" / source.name
        assert destination.read_bytes() == source.read_bytes(), f"postinstall config: {source.name}"
        assert stat.S_IMODE(destination.stat().st_mode) == 0o644
        configurations.append(source.name)
    for name in ("mcdiff", "mcedit", "mcview"):
        assert os.readlink(root / "usr/local/bin" / name) == "mc"
    receipts = root / "private/var/db/receipts"
    bom = receipts / "org.rudix.pkg.mc.bom"
    assert bom.read_bytes() == package["mcinstall.pkg/Bom"]
    # Apple's read-only BOM utility is an independent format oracle, never an
    # installation dependency of mdpkg.
    listing = subprocess.run(["/usr/bin/lsbom", "-s", str(bom)], capture_output=True, text=True, check=True)
    (output / "bom-files.txt").write_text(listing.stdout)
    bom_names = {name.removeprefix("./") if name != "." else "" for name in listing.stdout.splitlines()}
    assert bom_names == {entry[0] for entry in payload}, "BOM/CPIO inventory mismatch"
    receipt = plistlib.loads((receipts / "org.rudix.pkg.mc.plist").read_bytes())
    assert receipt["PackageIdentifier"] == "org.rudix.pkg.mc"
    assert receipt["PackageVersion"] == "4.8.7-0" and receipt["InstallPrefixPath"] == "/"
    # pkgutil, read-only, as a second oracle that the receipt is Apple-shaped.
    info = subprocess.run(["/usr/sbin/pkgutil", "--volume", str(root), "--pkg-info", "org.rudix.pkg.mc"],
                          capture_output=True, text=True, check=True).stdout
    assert "version: 4.8.7-0" in info and "location: /" in info, info
    inventory = plistlib.loads((root / "private/var/db/mdpkg/org.rudix.pkg.mc.inventory.plist").read_bytes())
    records = inventory["Entries"]
    assert len([entry for entry in records if entry["origin"] == "payload"]) == 392
    for name in configurations:
        assert any(entry["origin"] == "script" and entry["change"] == "created" and
                   entry["path"] == "usr/local/etc/mc/" + name for entry in records)
    # A script trying to modify an outside sentinel must fail without publishing
    # any part of its installation. This exercises the same actual runner.
    attack_root = output / "attack-root"
    attack_root.mkdir()
    (attack_root / "original").write_bytes(b"original")
    attack_pkg = output / "attack.pkg"
    script = ("#!/bin/sh\nset -e\nprintf compromised > " + str(sentinel) + "\n").encode()
    attack_pkg.write_bytes(xar(component_files([("installed", stat.S_IFREG | 0o644, b"bad")], script=script)))
    attack = subprocess.run([str(args.installer.resolve()), "install", "-pkg", str(attack_pkg),
                             "-root", str(attack_root), "-script-runner", str(args.runner.resolve())],
                            capture_output=True, text=True)
    (output / "sandbox-denial.log").write_text(attack.stdout + attack.stderr)
    assert attack.returncode != 0, "outside write did not fail"
    assert sentinel.read_bytes() == b"outside unchanged\n"
    assert tree(attack_root) == {"original": {"type": "file", "mode": 0o644,
                                              "sha256": hashlib.sha256(b"original").hexdigest()}}
    libraries = macho_libraries(root / "usr/local/bin/mc")
    missing = [name for name in libraries if not (root / name.lstrip("/")).exists()]
    report = {
        "result": "complete installation verified",
        "release": bundle.name, "base_verifies_with_allow_extra": True, "installed_root": str(root), "package_sha256": MC_SHA256,
        "payload_entries_verified": len(payload), "bom_entries_verified": len(bom_names),
        "configurations_created_by_original_postinstall": configurations,
        "base_entries_unchanged": len(before), "receipt_verified": True,
        "pkgutil_reads_receipt": True,
        "sandbox_outside_write_denied": True, "outside_sentinel_unchanged": True,
        "mc_architecture": "x86_64", "mc_executed": False,
        "missing_runtime_libraries": missing, "dyld_present": (root / "usr/lib/dyld").exists(),
    }
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
