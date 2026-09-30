#!/usr/bin/env python3
"""Independent flat-package fixtures and behavioral tests for mdpkg.

The fixtures are built here from the format descriptions, not with Apple's
tools, and mdpkg is only ever run against temporary roots. MDPKG names the
binary; MC_PKG optionally names the pinned Midnight Commander package.
"""
import ctypes
import datetime
import gzip
import hashlib
import os
from pathlib import Path
import plistlib
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zlib


def cpio(entries, newc=False):
    out = bytearray()
    for ino, (name, mode, data) in enumerate([*entries, ("TRAILER!!!", 0, b"")], 1):
        name = name.encode() + b"\0"
        if newc:
            fields = [ino, mode, 0, 0, 1, 123, len(data), 0, 0, 0, 0, len(name), 0]
            out.extend(b"070701" + b"".join(f"{x:08x}".encode() for x in fields))
            out.extend(name)
            out.extend(b"\0" * (-len(out) % 4))
            out.extend(data)
            out.extend(b"\0" * (-len(out) % 4))
        else:
            fields = [(0, 6), (ino, 6), (mode, 6), (0, 6), (0, 6), (1, 6), (0, 6),
                      (123, 11), (len(name), 6), (len(data), 11)]
            out.extend(b"070707" + b"".join(f"{x:0{n}o}".encode() for x, n in fields))
            out.extend(name)
            out.extend(data)
    out.extend(b"\0" * (-len(out) % 512))
    return bytes(out)


def xar(files, algorithm="sha1", named_header=True):
    """A XAR with zlib members. Algorithms other than sha1/md5 are header
    type 3 ("other"), named in a 64-byte header unless NAMED_HEADER is off."""
    size = hashlib.new(algorithm).digest_size
    doc = ET.Element("xar")
    toc = ET.SubElement(doc, "toc")
    check = ET.SubElement(toc, "checksum", style=algorithm)
    ET.SubElement(check, "offset").text = "0"
    ET.SubElement(check, "size").text = str(size)
    heap = bytearray(b"\0" * size)
    directories = {"": toc}
    for path, value in files.items():
        parent = ""
        bits = path.split("/")
        for bit in bits[:-1]:
            current = parent + "/" + bit if parent else bit
            if current not in directories:
                node = ET.SubElement(directories[parent], "file")
                ET.SubElement(node, "name").text = bit
                ET.SubElement(node, "type").text = "directory"
                directories[current] = node
            parent = current
        node = ET.SubElement(directories[parent], "file")
        ET.SubElement(node, "name").text = bits[-1]
        ET.SubElement(node, "type").text = "file"
        data = ET.SubElement(node, "data")
        packed = zlib.compress(value)
        for name, v in [("offset", len(heap)), ("length", len(packed)), ("size", len(value))]:
            ET.SubElement(data, name).text = str(v)
        ET.SubElement(data, "encoding", style="application/x-gzip")
        ET.SubElement(data, "archived-checksum", style=algorithm).text = hashlib.new(algorithm, packed).hexdigest()
        ET.SubElement(data, "extracted-checksum", style=algorithm).text = hashlib.new(algorithm, value).hexdigest()
        heap.extend(packed)
    xml = ET.tostring(doc)
    compressed = zlib.compress(xml)
    heap[:size] = hashlib.new(algorithm, compressed).digest()
    kind = {"sha1": 1, "md5": 2}.get(algorithm, 3)
    name = algorithm.encode().ljust(36, b"\0") if kind == 3 and named_header else b""
    header = struct.pack(">4sHHQQI", b"xar!", 28 + len(name), 1, len(compressed), len(xml), kind) + name
    return header + compressed + heap


def component_files(entries, *, script=None, location="/", newc=False, payload=None,
                    identifier="org.minidarwin.test"):
    info = ET.Element("pkg-info", {"format-version": "2", "identifier": identifier,
                                   "version": "1.0", "install-location": location, "relocatable": "false"})
    ET.SubElement(info, "payload", numberOfFiles=str(len(entries)))
    files = {"Payload": gzip.compress(cpio(entries, newc)) if payload is None else payload,
             "Bom": b"BOMStore" + b"\0" * 24}
    if script is not None:
        ET.SubElement(ET.SubElement(info, "scripts"), "postinstall", file="./postinstall")
        files["Scripts"] = gzip.compress(cpio([("./postinstall", stat.S_IFREG | 0o755, script)]))
    files["PackageInfo"] = ET.tostring(info)
    return files


def distribution(*components, extra=""):
    """A static Distribution selecting each (identifier, member-dir) pair."""
    lines = "".join(f'<line choice="c{i}"/>' for i in range(len(components)))
    choices = "".join(f'<choice id="c{i}"><pkg-ref id="{ident}"/></choice>'
                      f'<pkg-ref id="{ident}">#{ref}</pkg-ref>'
                      for i, (ident, ref) in enumerate(components))
    return (f"<installer-gui-script minSpecVersion='1'>{extra}"
            f"<choices-outline>{lines}</choices-outline>{choices}</installer-gui-script>")


def set_xattr(path, name, value):
    """os.setxattr is Linux-only; call Darwin's setxattr(2) directly."""
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.setxattr(os.fsencode(path), name.encode(), value, len(value), 0, 0x0001):
        raise OSError(ctypes.get_errno(), "setxattr")


def get_xattr(path, name):
    libc = ctypes.CDLL(None, use_errno=True)
    buf = ctypes.create_string_buffer(256)
    n = libc.getxattr(os.fsencode(path), name.encode(), buf, 256, 0, 0x0001)
    if n < 0:
        raise OSError(ctypes.get_errno(), "getxattr")
    return buf.raw[:n]


def read_xar(path):
    """Test oracle; does not use the C installer or Apple Installer."""
    data = Path(path).read_bytes()
    magic, size, version, packed_size, unpacked_size, algorithm = struct.unpack(">4sHHQQI", data[:28])
    assert magic == b"xar!" and version == 1
    raw = zlib.decompress(data[size:size + packed_size])
    assert len(raw) == unpacked_size
    toc = ET.fromstring(raw).find("toc")
    heap = size + packed_size
    result = {}

    def walk(node, prefix=""):
        for item in node.findall("file"):
            name = prefix + item.findtext("name")
            content = item.find("data")
            if content is not None:
                offset, length = int(content.findtext("offset")), int(content.findtext("length"))
                value = data[heap + offset:heap + offset + length]
                if content.find("encoding").get("style") == "application/x-gzip":
                    value = zlib.decompress(value)
                assert len(value) == int(content.findtext("size"))
                result[name] = value
            walk(item, name + "/")
    walk(toc)
    return result


def read_odc(data):
    if data.startswith(b"\x1f\x8b"):
        data = gzip.decompress(data)
    position = 0
    records = []
    while position < len(data):
        header = data[position:position + 76]
        assert header[:6] == b"070707"
        mode = int(header[18:24], 8)
        uid, gid = int(header[24:30], 8), int(header[30:36], 8)
        namesize, size = int(header[59:65], 8), int(header[65:76], 8)
        name = data[position + 76:position + 76 + namesize - 1].decode()
        start = position + 76 + namesize
        value = data[start:start + size]
        assert len(value) == size
        position = start + size
        if name == "TRAILER!!!":
            break
        records.append((name.removeprefix("./") if name != "." else "", mode, uid, gid, value))
    return records


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="mdpkg-tests-")
        self.base = Path(self.tmp.name)
        self.root = self.base / "root"
        self.root.mkdir()
        (self.root / "base-file").write_bytes(b"unchanged")
        self.pkg = self.base / "test.pkg"
        self.binary = os.environ["MDPKG"]
        self.entries = [("./usr", stat.S_IFDIR | 0o755, b""),
                        ("./usr/bin", stat.S_IFDIR | 0o755, b""),
                        ("./usr/bin/tool", stat.S_IFREG | 0o755, b"hello\n"),
                        ("./usr/bin/alias", stat.S_IFLNK | 0o777, b"tool")]

    def tearDown(self):
        self.tmp.cleanup()

    def package(self, entries=None, **kwargs):
        self.pkg.write_bytes(xar(component_files(self.entries if entries is None else entries, **kwargs)))

    def run_cli(self, *args, ok=True, env=None):
        result = subprocess.run([self.binary, *args], capture_output=True, text=True,
                                env=None if env is None else {**os.environ, **env})
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result

    def install(self, ok=True, *extra):
        return self.run_cli("install", "--pkg", str(self.pkg), "--root", str(self.root), *extra, ok=ok)

    def original_intact(self):
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), ["base-file"])
        self.assertEqual((self.root / "base-file").read_bytes(), b"unchanged")

    def test_install_modes_links_receipts_and_inventory(self):
        self.package()
        self.install()
        tool = self.root / "usr/bin/tool"
        self.assertEqual(tool.read_bytes(), b"hello\n")
        self.assertEqual(stat.S_IMODE(tool.stat().st_mode), 0o755)
        self.assertEqual(tool.stat().st_mtime, 123)
        self.assertEqual(os.readlink(self.root / "usr/bin/alias"), "tool")
        receipt = plistlib.loads((self.root / "private/var/db/receipts/org.minidarwin.test.plist").read_bytes())
        self.assertEqual(receipt["PackageIdentifier"], "org.minidarwin.test")
        self.assertEqual(receipt["PackageVersion"], "1.0")
        self.assertEqual(receipt["InstallPrefixPath"], "/")
        self.assertEqual(receipt["PackageFileName"], "test.pkg")
        self.assertIsInstance(receipt["InstallDate"], datetime.datetime)
        inventory = plistlib.loads((self.root / "private/var/db/mdpkg/org.minidarwin.test.inventory.plist").read_bytes())
        self.assertEqual(len(inventory["Entries"]), 4)
        self.assertEqual((self.root / "base-file").read_bytes(), b"unchanged")
        self.install(ok=False)
        self.assertEqual(tool.read_bytes(), b"hello\n")

    def test_newc_and_nonroot_location(self):
        self.package(newc=True, location="/opt")
        self.install()
        self.assertEqual((self.root / "opt/usr/bin/tool").read_bytes(), b"hello\n")

    def test_raw_cpio(self):
        self.package(payload=cpio(self.entries))
        self.install()

    def test_traversal_absolute_escape_and_duplicates(self):
        for entries in [
            [("../../outside", stat.S_IFREG | 0o644, b"bad")],
            [("/absolute", stat.S_IFREG | 0o644, b"bad")],
            [("link", stat.S_IFLNK | 0o777, b"../outside")],
            [("same", stat.S_IFREG | 0o644, b"a"), ("same", stat.S_IFREG | 0o644, b"b")],
            [("a/b", stat.S_IFREG | 0o644, b"a"), ("a", stat.S_IFLNK | 0o777, b"base-file")],
            [("private/var/db/receipts/evil", stat.S_IFREG | 0o644, b"bad")],
        ]:
            with self.subTest(entries=entries):
                self.package(entries)
                self.install(ok=False)
                self.original_intact()

    def test_unsupported_types_and_hardlinks(self):
        for mode in [stat.S_IFIFO | 0o644, stat.S_IFCHR | 0o644, stat.S_IFREG | 0o4755]:
            self.package([("bad", mode, b"")])
            self.install(ok=False)
            self.original_intact()

    def test_collision(self):
        self.package([("base-file", stat.S_IFREG | 0o644, b"changed")])
        self.install(ok=False)
        self.original_intact()

    def test_existing_symlink_parent(self):
        outside = self.base / "outside"
        outside.mkdir()
        (self.root / "usr").symlink_to(outside, target_is_directory=True)
        self.package()
        self.install(ok=False)
        self.assertEqual(list(outside.iterdir()), [])

    def test_root_refusals(self):
        self.package()
        self.run_cli("install", "--pkg", str(self.pkg), "--root", "/", ok=False)
        link = self.base / "root-link"
        link.symlink_to(self.root, target_is_directory=True)
        self.run_cli("install", "--pkg", str(self.pkg), "--root", str(link), ok=False)
        self.run_cli("install", "--pkg", str(self.pkg), "--root", "/nix/store/fake-root", ok=False)
        self.original_intact()

    def test_scripts_require_runner_and_failure_rolls_back(self):
        self.package(script=b"#!/bin/sh\nexit 0\n")
        self.install(ok=False)
        self.original_intact()
        runner = self.base / "failing-runner"
        runner.write_text("#!/bin/sh\nexit 7\n")
        runner.chmod(0o755)
        self.install(False, "--script-runner", str(runner))
        self.original_intact()
        self.assertFalse(Path(str(self.root) + ".mdpkg-transaction").exists())

    def test_preinstall_and_postinstall_inventory(self):
        files = component_files(self.entries, script=b"#!/bin/sh\nexit 0\n")
        info = ET.fromstring(files["PackageInfo"])
        ET.SubElement(info.find("scripts"), "preinstall", file="./preinstall")
        files["PackageInfo"] = ET.tostring(info)
        files["Scripts"] = gzip.compress(cpio([
            ("./preinstall", stat.S_IFREG | 0o755, b"#!/bin/sh\nexit 0\n"),
            ("./postinstall", stat.S_IFREG | 0o755, b"#!/bin/sh\nexit 0\n"),
        ]))
        self.pkg.write_bytes(xar(files))
        runner = self.base / "test-runner"
        runner.write_text(f"#!{sys.executable}\n" + """import os, sys
from pathlib import Path
script, workdir, package, location, root = sys.argv[1:]
assert os.getcwd() == workdir
assert os.environ['DSTVOLUME'] == root
assert os.environ['DSTROOT'] == location
assert os.environ['PACKAGE_PATH'] == package
assert location == root
if Path(script).name == 'preinstall':
    Path(root, 'pre-created').write_text('pre')
else:
    Path(root, 'usr/bin/tool').write_text('post')
""")
        runner.chmod(0o755)
        self.install(True, "--script-runner", str(runner))
        inventory = plistlib.loads((self.root / "private/var/db/mdpkg/org.minidarwin.test.inventory.plist").read_bytes())
        changes = {(entry["path"], entry["change"]) for entry in inventory["Entries"] if entry["origin"] == "script"}
        self.assertIn(("pre-created", "created"), changes)
        self.assertIn(("usr/bin/tool", "modified"), changes)

    def test_existing_metadata_rejected_without_loss(self):
        path = self.root / "base-file"
        try:
            set_xattr(path, "com.minidarwin.test", b"preserve")
        except OSError:
            self.skipTest("extended attributes not supported")
        self.package()
        self.install(ok=False)
        self.original_intact()
        self.assertEqual(get_xattr(path, "com.minidarwin.test"), b"preserve")

    def test_existing_nanosecond_timestamp_preserved(self):
        path = self.root / "base-file"
        os.utime(path, ns=(1234567890123456789, 1234567890123456789))
        self.package()
        self.install()
        self.assertEqual(path.stat().st_mtime_ns, 1234567890123456789)

    def test_checksum_and_truncation(self):
        self.package()
        good = self.pkg.read_bytes()
        for bad in [good[:20], good[:-10], good[:60] + bytes([good[60] ^ 1]) + good[61:]]:
            self.pkg.write_bytes(bad)
            self.install(ok=False)
            self.original_intact()

    def test_decompression_limit(self):
        self.package()
        data = bytearray(self.pkg.read_bytes())
        data[16:24] = struct.pack(">Q", 512 * 1024 * 1024)
        self.pkg.write_bytes(data)
        self.install(ok=False)
        self.original_intact()

    def test_invalid_cpio(self):
        for payload in [b"pbzxunsupported", cpio(self.entries)[:150], cpio(self.entries) + b"nonzero"]:
            self.package(payload=payload)
            self.install(ok=False)
            self.original_intact()

    def test_distribution(self):
        files = {"component.pkg/" + name: data for name, data in component_files(self.entries).items()}
        distribution = '''<installer-script><choices-outline><line choice="c"/></choices-outline>
<choice id="c"><pkg-ref id="org.minidarwin.test"/></choice>
<pkg-ref id="org.minidarwin.test">#component.pkg</pkg-ref></installer-script>'''
        files["Distribution"] = distribution.encode()
        self.pkg.write_bytes(xar(files))
        self.install()
        self.assertTrue((self.root / "usr/bin/tool").exists())
        for bad in [distribution.replace('<choice id="c">', '<choice id="c" selected="system.version()">'),
                    distribution.replace("#component.pkg", "https://example.invalid/pkg"),
                    distribution.replace("</installer-script>", "<installation-check script='check()'/></installer-script>")]:
            files["Distribution"] = bad.encode()
            self.pkg.write_bytes(xar(files))
            self.run_cli("inspect", "--pkg", str(self.pkg), ok=False)

    def test_checksum_algorithms(self):
        files = component_files(self.entries)
        for algorithm, named in [("sha1", True), ("md5", True), ("sha256", True),
                                 ("sha512", True), ("sha256", False)]:
            with self.subTest(algorithm=algorithm, named=named):
                self.pkg.write_bytes(xar(files, algorithm, named))
                self.run_cli("inspect", "--pkg", str(self.pkg))
        data = bytearray(xar(files, "sha256"))
        data[28:34] = b"sha512"  # header and TOC disagree
        self.pkg.write_bytes(data)
        self.run_cli("inspect", "--pkg", str(self.pkg), ok=False)

    def test_product_archive(self):
        files = {}
        for ident, ref, tool in [("org.minidarwin.one", "Tool One.pkg", "one"),
                                 ("org.minidarwin.two", "two.pkg", "two")]:
            component = component_files([("./usr", stat.S_IFDIR | 0o755, b""),
                                         (f"./usr/{tool}", stat.S_IFREG | 0o644, b"x")],
                                        identifier=ident)
            info = ET.fromstring(component["PackageInfo"])
            ET.SubElement(ET.SubElement(info, "bundle-version"), "bundle", id="org.example.app")
            component["PackageInfo"] = ET.tostring(info)
            files.update({f"{ref}/{name}": data for name, data in component.items()})
        files["Distribution"] = distribution(
            ("org.minidarwin.one", "Tool%20One.pkg"), ("org.minidarwin.two", "two.pkg"),
            extra='<options hostArchitectures="arm64,x86_64" customize="never"/>').encode()
        self.pkg.write_bytes(xar(files))
        result = self.run_cli("inspect", "--pkg", str(self.pkg))
        self.assertIn("org.minidarwin.one 1.0 /: 2 payload entries", result.stdout)
        self.assertIn("host architectures (not enforced): arm64,x86_64", result.stdout)
        self.install()
        self.assertTrue((self.root / "usr/one").exists() and (self.root / "usr/two").exists())
        for ident in ("org.minidarwin.one", "org.minidarwin.two"):
            self.assertTrue((self.root / f"private/var/db/receipts/{ident}.bom").exists())

    def test_components_may_not_overlap(self):
        files = {}
        for ident in ("org.minidarwin.one", "org.minidarwin.two"):
            files.update({f"{ident}.pkg/{name}": data for name, data in
                          component_files(self.entries, identifier=ident).items()})
        files["Distribution"] = distribution(("org.minidarwin.one", "org.minidarwin.one.pkg"),
                                             ("org.minidarwin.two", "org.minidarwin.two.pkg")).encode()
        self.pkg.write_bytes(xar(files))
        self.install(ok=False)
        self.original_intact()

    def test_symlink_chain_escape(self):
        # Each link is contained on its own; d/l -> d/s/../x is not.
        self.package([("./d", stat.S_IFDIR | 0o755, b""),
                      ("./d/s", stat.S_IFLNK | 0o777, b".."),
                      ("./d/l", stat.S_IFLNK | 0o777, b"s/../x")])
        self.install(ok=False)
        self.original_intact()

    def test_payload_follows_base_symlinks(self):
        (self.root / "private/etc").mkdir(parents=True)
        (self.root / "etc").symlink_to("private/etc")
        self.package([("./etc", stat.S_IFDIR | 0o755, b""),
                      ("./etc/tool.conf", stat.S_IFREG | 0o644, b"conf")])
        self.install()
        self.assertEqual(os.readlink(self.root / "etc"), "private/etc")
        self.assertEqual((self.root / "private/etc/tool.conf").read_bytes(), b"conf")
        inventory = plistlib.loads((self.root / "private/var/db/mdpkg/org.minidarwin.test.inventory.plist").read_bytes())
        placed = {e["path"]: e.get("package-path") for e in inventory["Entries"]}
        self.assertEqual(placed["private/etc/tool.conf"], "etc/tool.conf")

    def test_escaping_base_symlink(self):
        outside = self.base / "outside"
        outside.mkdir()
        (self.root / "etc").symlink_to("../outside")
        self.package([("./etc/tool.conf", stat.S_IFREG | 0o644, b"conf")])
        self.install(ok=False)
        self.assertEqual(list(outside.iterdir()), [])

    def test_lock_is_exclusive(self):
        import fcntl
        self.package()
        with open(str(self.root) + ".mdpkg-lock", "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.install(ok=False)
        self.original_intact()
        self.install()

    def test_source_date_epoch(self):
        self.package()
        self.run_cli("install", "--pkg", str(self.pkg), "--root", str(self.root),
                     env={"SOURCE_DATE_EPOCH": "86400"})
        receipt = plistlib.loads((self.root / "private/var/db/receipts/org.minidarwin.test.plist").read_bytes())
        self.assertEqual(receipt["InstallDate"], datetime.datetime(1970, 1, 2))

    def test_cli(self):
        self.assertIn("mdpkg ", self.run_cli("--version").stdout)
        self.assertIn("usage:", self.run_cli("--help").stdout)
        self.package()
        self.run_cli(ok=False)
        self.run_cli("inspect", "--pkg", str(self.pkg), "--root", str(self.root), ok=False)
        self.run_cli("install", "--pkg", str(self.pkg), ok=False)
        self.run_cli("install", "--pkg", str(self.pkg), "--pkg", str(self.pkg), ok=False)

    def test_dtd_rejected(self):
        files = component_files(self.entries)
        files["PackageInfo"] = b'<!DOCTYPE pkg-info [<!ENTITY x "bad">]>' + files["PackageInfo"]
        self.pkg.write_bytes(xar(files))
        self.install(ok=False)
        self.original_intact()

    def test_interrupted_publish_recovers_original(self):
        self.package()
        txn = Path(str(self.root) + ".mdpkg-transaction")
        txn.mkdir(mode=0o700)
        (txn / "target").write_text(str(self.root.resolve()))
        self.root.rename(txn / "original")
        (txn / "new").mkdir()
        (txn / "new/unfinished").write_text("bad")
        self.install()
        self.assertEqual((self.root / "base-file").read_bytes(), b"unchanged")
        self.assertFalse((self.root / "unfinished").exists())
        self.assertFalse(txn.exists())

    def test_interrupted_cleanup_completes_publication(self):
        # Both renames happened; only removing the original was left.
        self.package()
        txn = Path(str(self.root) + ".mdpkg-transaction")
        txn.mkdir(mode=0o700)
        (txn / "target").write_text(str(self.root.resolve()))
        (txn / "original").mkdir()
        (txn / "original/old").write_text("old")
        self.install()
        self.assertFalse(txn.exists())
        self.assertEqual((self.root / "base-file").read_bytes(), b"unchanged")

    @unittest.skipUnless(os.environ.get("MC_PKG"), "MC fixture unavailable")
    def test_actual_mc_metadata(self):
        self.pkg = Path(os.environ["MC_PKG"])
        data = self.pkg.read_bytes()
        self.assertEqual(hashlib.sha256(data).hexdigest(), "5b047f602247de2b9cd9f4ed6f4b95fb9083a18a6435477dacbfac5f36bfa030")
        result = self.run_cli("inspect", "--pkg", str(self.pkg))
        self.assertIn("org.rudix.pkg.mc 4.8.7-0 /: 392 payload entries; script postinstall", result.stdout)
        files = read_xar(self.pkg)
        self.assertEqual(len(read_odc(files["mcinstall.pkg/Payload"])), 392)
        self.install(ok=False)
        self.original_intact()


if __name__ == "__main__":
    unittest.main()
