#!/usr/bin/env python3
"""Tests for mdrootfs.py. `python3 scripts/test_mdrootfs.py`; also run by the
`releaseTest` check. Standard library only, like the tool."""

import contextlib
import io
import os
import stat
import sys
import tarfile
import tempfile
import unittest
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mdrootfs  # noqa: E402

# docs/rootfs-spec.md quotes this: the tree `sample_tree` builds. A second
# implementation of the format should arrive at the same digest.
SAMPLE_TREE_DIGEST = "1cb4990e4557b548759f593c103a1a05e0d4558f9c5fb0e3b53969165ae88852"


def run(*argv):
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        status = mdrootfs.main(list(argv))
    return status, out.getvalue()


def sample_tree(root):
    """/usr/lib/{libA.dylib, libB.dylib -> libA.dylib, data.txt}, /usr/share/doc/readme."""
    os.makedirs(os.path.join(root, "usr/lib"))
    os.makedirs(os.path.join(root, "usr/share/doc"))
    with open(os.path.join(root, "usr/lib/libA.dylib"), "wb") as f:
        f.write(b"\xcf\xfa\xed\xfe not really a mach-o\n")
    os.chmod(os.path.join(root, "usr/lib/libA.dylib"), 0o555)
    with open(os.path.join(root, "usr/lib/data.txt"), "wb") as f:
        f.write(b"data\n")
    os.chmod(os.path.join(root, "usr/lib/data.txt"), 0o444)
    os.symlink("libA.dylib", os.path.join(root, "usr/lib/libB.dylib"))
    with open(os.path.join(root, "usr/share/doc/readme"), "wb") as f:
        f.write(b"")
    for d in ("usr/share/doc", "usr/share", "usr/lib", "usr"):
        os.chmod(os.path.join(root, d), 0o555)


def add(tar, name, kind="file", data=b"", mode=None, target=""):
    info = tarfile.TarInfo(name)
    info.mtime = 1
    if kind == "dir":
        info.type = tarfile.DIRTYPE
        info.mode = 0o755 if mode is None else mode
        tar.addfile(info)
    elif kind == "symlink":
        info.type = tarfile.SYMTYPE
        info.linkname = target
        info.mode = 0o777
        tar.addfile(info)
    elif kind == "hardlink":
        info.type = tarfile.LNKTYPE
        info.linkname = target
        tar.addfile(info)
    elif kind == "fifo":
        info.type = tarfile.FIFOTYPE
        tar.addfile(info)
    else:
        info.size = len(data)
        info.mode = 0o644 if mode is None else mode
        tar.addfile(info, io.BytesIO(data))


def pack(tree, out):
    """What the Nix derivation does with GNU tar, done with tarfile."""
    with tarfile.open(out, "w:gz") as tar:
        add(tar, "./", "dir")

        def walk(host, rel):
            for name in sorted(os.listdir(host)):
                full = os.path.join(host, name)
                arc = f"./{rel}{name}"
                st = os.lstat(full)
                if stat.S_ISLNK(st.st_mode):
                    add(tar, arc, "symlink", target=os.readlink(full))
                elif stat.S_ISDIR(st.st_mode):
                    add(tar, arc, "dir")
                    walk(full, f"{rel}{name}/")
                else:
                    with open(full, "rb") as f:
                        add(tar, arc, data=f.read(), mode=0o755 if st.st_mode & 0o111 else 0o644)

        walk(tree, "")


class Case(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="mdrootfs-test-")
        self.tmp = self._tmp.name
        self.tree = self.path("tree")
        sample_tree(self.tree)
        self.manifest = self.path("m.yaml")
        self.artifact = self.path("r.tar.gz")
        self.spec = self.path("s.yaml")
        status, out = run("manifest", self.tree, "-o", self.manifest,
                          "--identity", "project=minidarwin", "--identity", "arch=aarch64",
                          "--identity", "min_os=26.0", "--llvm", "21.1.8",
                          "--apple-source", "xnu=xnu-12377.121.6=sha256-abc=")
        self.assertEqual(status, 0, out)
        pack(self.tree, self.artifact)
        status, out = run("spec", "--manifest", self.manifest, "--artifact", self.artifact,
                          "--sequence", "3", "-o", self.spec)
        self.assertEqual(status, 0, out)

    def tearDown(self):
        # The sample tree is read-only, as a store path is.
        for dirpath, dirnames, _ in os.walk(self.tmp):
            for d in dirnames:
                p = os.path.join(dirpath, d)
                if not os.path.islink(p):
                    os.chmod(p, 0o755)
        self._tmp.cleanup()

    def path(self, *parts):
        return os.path.join(self.tmp, *parts)

    def verify(self, *argv):
        return run("verify", *argv)

    def assertVerifies(self, *argv):
        status, out = self.verify(*argv)
        self.assertEqual(status, 0, out)
        self.assertTrue(out.rstrip().endswith("OK"), out)
        return out

    def assertFails(self, needle, *argv):
        status, out = self.verify(*argv)
        self.assertEqual(status, 1, out)
        self.assertIn(needle, out)
        return out

    def extracted(self):
        dest = self.path("x")
        self.assertVerifies("--spec", self.spec, "--manifest", self.manifest,
                            "--artifact", self.artifact, "--extract-to", dest)
        return dest

    def write_tar(self, build, manifest=None):
        bad = self.path("bad.tar.gz")
        with tarfile.open(bad, "w:gz") as tar:
            build(tar)
        return self.verify("--manifest", manifest or self.manifest, "--artifact", bad)


class Formats(Case):
    def test_the_sample_tree_has_the_documented_digest(self):
        manifest = mdrootfs.load_manifest(self.manifest)
        self.assertEqual(manifest.tree, SAMPLE_TREE_DIGEST)

    def test_modes_are_normalized_from_a_read_only_tree(self):
        manifest = mdrootfs.load_manifest(self.manifest)
        modes = {e["path"]: e.get("mode") for e in manifest.entries}
        self.assertEqual(modes["/usr/lib/libA.dylib"], "0755")
        self.assertEqual(modes["/usr/lib/data.txt"], "0644")
        self.assertEqual(modes["/usr"], "0755")

    def test_a_release_verifies(self):
        out = self.assertVerifies("--spec", self.spec, "--manifest", self.manifest, "--artifact", self.artifact)
        self.assertIn("0 missing, 0 modified, 0 wrong-type, 0 mode, 0 unexpected", out)

    def test_a_bundle_verifies_and_is_reproducible(self):
        a, b = self.path("a.zip"), self.path("b.zip")
        for out in (a, b):
            status, text = run("bundle", "--spec", self.spec, "--manifest", self.manifest,
                               "--artifact", self.artifact, "-o", out)
            self.assertEqual(status, 0, text)
        with open(a, "rb") as fa, open(b, "rb") as fb:
            self.assertEqual(fa.read(), fb.read())
        out = self.assertVerifies("--bundle", a)
        self.assertIn("integrity only", out)
        # A spec from outside the bundle is the one that counts.
        out = self.assertVerifies("--bundle", a, "--spec", self.spec)
        self.assertIn("bundle's own spec is ignored", out)

    def test_a_bundle_holds_exactly_three_members(self):
        bad = self.path("bad.zip")
        with zipfile.ZipFile(bad, "w") as z:
            z.write(self.spec, "spec.yaml")
            z.write(self.manifest, "manifest.yaml")
            z.write(self.artifact, "rootfs.tar.gz")
            z.writestr("../evil", b"x")
        self.assertFails("members must be exactly", "--bundle", bad)

    def test_the_manifest_is_canonical(self):
        with open(self.manifest) as f:
            text = f.read()
        for mutated in (text.replace("format: 1", "format:  1"),
                        text.replace('owner: "minidarwin"', "owner: minidarwin"),
                        text + "# trailing comment\n"):
            with open(self.manifest, "w") as f:
                f.write(mutated)
            self.assertFails("canonical", "--manifest", self.manifest)

    def test_a_directory_digest_must_match_its_contents(self):
        with open(self.manifest) as f:
            text = f.read()
        manifest = mdrootfs.load_manifest(self.manifest)
        old = manifest.by_path["/usr/share"]["digest"]
        with open(self.manifest, "w") as f:
            f.write(text.replace(old, "0" * 64))
        self.assertFails("does not match", "--manifest", self.manifest)

    def test_a_manifest_rejects_unsafe_entries(self):
        base = mdrootfs.load_manifest(self.manifest)

        def attempt(entries, needle):
            with self.assertRaises(mdrootfs.Invalid) as caught:
                mdrootfs.check_entries(entries, "m")
            self.assertIn(needle, str(caught.exception))

        d = dict(path="/usr", type="directory", mode="0755", digest="0" * 64)
        attempt([d, dict(path="/usr/../etc", type="file", mode="0644", size=0, sha256="0" * 64)], "unsafe")
        attempt([d, dict(path="/usr/Lib", type="directory", mode="0755", digest="0" * 64),
                 dict(path="/usr/lib", type="directory", mode="0755", digest="0" * 64)], "only in case")
        attempt([dict(path="/usr/x", type="file", mode="0644", size=0, sha256="0" * 64)], "parent")
        attempt([d, dict(path="/usr/x", type="file", mode="4755", size=0, sha256="0" * 64)], "mode")
        for target in ("/etc/passwd", "../../etc", "a/../../..", "../.."):
            attempt([d, dict(path="/usr/l", type="symlink", target=target)], "symlink")
        attempt(list(reversed(base.entries)), "")

    def test_symlinks_may_climb_their_own_ancestors(self):
        mdrootfs.check_symlink_target("/usr/lib/l", "../../usr/lib/x", "t")
        mdrootfs.check_symlink_target("/System/Library/Frameworks/F.framework/F", "Versions/Current/F", "t")

    def test_a_manifest_refuses_a_dangling_symlink(self):
        tree = self.path("dangling")
        os.makedirs(os.path.join(tree, "usr"))
        os.symlink("nothing", os.path.join(tree, "usr/l"))
        status, out = run("manifest", tree, "-o", self.path("d.yaml"),
                          "--identity", "project=p", "--identity", "arch=a")
        self.assertEqual(status, 1)
        self.assertIn("dangling", out)

    def test_yaml_round_trips(self):
        doc = {"a": 1, "b": None, "c": {"d": "x y: z", "e": []}, "f": [{"g": "h", "i": 2}, ], "j": ["k"]}
        text = mdrootfs.dump_yaml("# h\n", doc)
        self.assertEqual(mdrootfs.parse_yaml(text, "t"), doc)

    def test_yaml_refuses_what_it_would_have_to_guess(self):
        for text in ("min_os: 26.0\n", "mode: 0755\n", "a: &x 1\n", "a: |\n  b\n", "a:\n  - b: c\n",
                     "a: 1\na: 2\n", "a: 'x\n", "a: b: c\n"):
            with self.assertRaises(mdrootfs.Invalid, msg=text):
                mdrootfs.parse_yaml(text, "t")


class Specs(Case):
    def write(self, text, name="user.yaml"):
        path = self.path(name)
        with open(path, "w") as f:
            f.write(text)
        return path

    def test_a_hand_written_spec_is_accepted(self):
        sha, size = mdrootfs.sha256_file(self.artifact)
        msha, _ = mdrootfs.sha256_file(self.manifest)
        spec = self.write(f"""\
---
# my own mirror
format: 1
artifact:
  format: tar+gzip
  sha256: {sha}   # from the release page
  sources:
  - https://mirror.example.org/rootfs.tar.gz
manifest:
  sha256: '{msha}'
system_files:
  policy: repair
""")
        out = self.assertVerifies("--spec", spec, "--manifest", self.manifest, "--artifact", self.artifact)
        self.assertIn("ignoring 'system_files'", out)

    def test_a_strict_spec_needs_both_hashes(self):
        spec = self.write("format: 1\nartifact: {format: tar+gzip}\nmanifest: {}\n")
        self.assertFails("64 lowercase hex", "--spec", spec)

    def test_an_insecure_spec_says_so_and_checks_what_it_can(self):
        spec = self.write("format: 1\nartifact: {format: tar+gzip, sha256: null}\nmanifest: {}\n"
                          "verification: {policy: insecure}\n")
        out = self.assertVerifies("--spec", spec, "--manifest", self.manifest, "--artifact", self.artifact)
        self.assertIn("INSECURE", out)
        self.assertIn("NOT CHECKED", out)

    def test_the_artifact_must_match_the_spec(self):
        with open(self.artifact, "ab") as f:
            f.write(b"\0")
        self.assertFails("artifact:", "--spec", self.spec, "--manifest", self.manifest, "--artifact", self.artifact)

    def test_the_manifest_must_match_the_spec(self):
        other = self.path("other.yaml")
        os.chmod(os.path.join(self.tree, "usr"), 0o755)
        with open(os.path.join(self.tree, "usr/extra"), "w") as f:
            f.write("x")
        run("manifest", self.tree, "-o", other, "--identity", "project=minidarwin", "--identity", "arch=aarch64")
        self.assertFails("manifest:", "--spec", self.spec, "--manifest", other)

    def test_plain_http_is_not_a_source(self):
        spec = self.write("format: 1\nartifact: {format: tar+gzip, sources: [http://x/r.tar.gz]}\n"
                          "manifest: {}\nverification: {policy: insecure}\n")
        self.assertFails("https://", "--spec", spec)

    def test_stamping_adds_the_release_and_keeps_the_hashes(self):
        stamped = self.path("stamped.yaml")
        commit = "0123456789abcdef0123456789abcdef01234567"
        status, out = run("stamp", self.spec, "-o", stamped, "--repository", "V3L0C1T13S/minidarwin",
                          "--tag", "v3", "--commit", commit)
        self.assertEqual(status, 0, out)
        spec = mdrootfs.load_spec(stamped)
        self.assertEqual(spec.release, {"sequence": 3, "tag": "v3", "commit": commit,
                                        "repository": "V3L0C1T13S/minidarwin"})
        self.assertEqual(spec.artifact["sources"],
                         ["https://github.com/V3L0C1T13S/minidarwin/releases/download/v3/r.tar.gz"])
        self.assertEqual(spec.artifact["sha256"], mdrootfs.load_spec(self.spec).artifact["sha256"])
        self.assertVerifies("--spec", stamped, "--manifest", self.manifest, "--artifact", self.artifact)
        # Once only, and never backwards.
        status, _ = run("stamp", stamped, "-o", self.path("again.yaml"), "--repository", "a/b",
                        "--tag", "v4", "--commit", commit)
        self.assertEqual(status, 1)
        status, out = run("stamp", self.spec, "-o", self.path("back.yaml"), "--repository", "a/b",
                          "--tag", "v2", "--commit", commit, "--previous", stamped)
        self.assertEqual(status, 1)
        self.assertIn("does not follow", out)


class Trees(Case):
    def test_a_modified_file_is_reported(self):
        root = self.extracted()
        with open(os.path.join(root, "usr/lib/data.txt"), "wb") as f:
            f.write(b"DATA\n")
        self.assertFails("modified   /usr/lib/data.txt", "--manifest", self.manifest, "--tree", root)

    def test_a_missing_file_is_reported(self):
        root = self.extracted()
        os.unlink(os.path.join(root, "usr/lib/libA.dylib"))
        self.assertFails("missing    /usr/lib/libA.dylib", "--manifest", self.manifest, "--tree", root)

    def test_a_symlink_replaced_by_a_file_is_the_wrong_type(self):
        root = self.extracted()
        link = os.path.join(root, "usr/lib/libB.dylib")
        os.unlink(link)
        with open(link, "wb") as f:
            f.write(b"\xcf\xfa\xed\xfe not really a mach-o\n")
        self.assertFails("wrong-type /usr/lib/libB.dylib", "--manifest", self.manifest, "--tree", root)

    def test_a_retargeted_symlink_is_modified(self):
        root = self.extracted()
        link = os.path.join(root, "usr/lib/libB.dylib")
        os.unlink(link)
        os.symlink("data.txt", link)
        self.assertFails("modified   /usr/lib/libB.dylib", "--manifest", self.manifest, "--tree", root)

    def test_a_mode_change_is_reported(self):
        root = self.extracted()
        os.chmod(os.path.join(root, "usr/lib/data.txt"), 0o755)
        self.assertFails("mode       /usr/lib/data.txt", "--manifest", self.manifest, "--tree", root)

    def test_extra_files_are_unexpected_unless_allowed(self):
        root = self.extracted()
        with open(os.path.join(root, "usr/lib/user-state"), "w") as f:
            f.write("mine")
        os.makedirs(os.path.join(root, "Users/me/Library"))
        out = self.assertFails("unexpected /usr/lib/user-state", "--manifest", self.manifest, "--tree", root)
        self.assertIn("unexpected /Users", out)
        self.assertNotIn("/Users/me", out)
        self.assertVerifies("--manifest", self.manifest, "--tree", root, "--allow-extra")

    def test_a_directory_swapped_for_a_symlink_is_not_followed(self):
        root = self.extracted()
        outside = self.path("outside")
        os.makedirs(outside)
        # A perfect copy of what the manifest expects, reached through a link.
        for name in os.listdir(os.path.join(root, "usr/lib")):
            src = os.path.join(root, "usr/lib", name)
            if os.path.islink(src):
                os.symlink(os.readlink(src), os.path.join(outside, name))
            else:
                with open(src, "rb") as f, open(os.path.join(outside, name), "wb") as g:
                    g.write(f.read())
                os.chmod(os.path.join(outside, name), os.stat(src).st_mode)
        lib = os.path.join(root, "usr/lib")
        for name in os.listdir(lib):
            os.unlink(os.path.join(lib, name))
        os.rmdir(lib)
        os.symlink(outside, lib)
        out = self.assertFails("wrong-type /usr/lib", "--manifest", self.manifest, "--tree", root)
        self.assertIn("missing    /usr/lib/libA.dylib", out)


class HostileTarballs(Case):
    def test_parent_traversal(self):
        status, out = self.write_tar(lambda t: add(t, "../evil", data=b"x"))
        self.assertEqual(status, 1)
        self.assertIn("unsafe", out)

    def test_absolute_names(self):
        status, out = self.write_tar(lambda t: add(t, "/etc/evil", data=b"x"))
        self.assertEqual(status, 1)
        self.assertIn("absolute", out)

    def test_writing_through_a_symlink(self):
        def build(t):
            add(t, "usr", "symlink", target="/tmp")
            add(t, "usr/lib", "dir")
        status, out = self.write_tar(build)
        self.assertEqual(status, 1)
        self.assertIn("is a symlink, manifest says directory", out)

    def test_an_entry_before_its_parent(self):
        status, out = self.write_tar(lambda t: add(t, "usr/lib/data.txt", data=b"data\n"))
        self.assertEqual(status, 1)
        self.assertIn("before its parent", out)

    def test_hardlinks_fifos_and_setuid(self):
        for kind, extra, needle in (("hardlink", {"target": "usr/lib/libA.dylib"}, "not a file"),
                                    ("fifo", {}, "not a file"),
                                    ("file", {"mode": 0o4755, "data": b"x"}, "set-id")):
            def build(t, kind=kind, extra=extra):
                add(t, "usr", "dir")
                add(t, "usr/lib", "dir")
                add(t, "usr/lib/libA.dylib", kind, **extra)
            status, out = self.write_tar(build)
            self.assertEqual(status, 1, kind)
            self.assertIn(needle, out)

    def test_names_the_manifest_does_not(self):
        status, out = self.write_tar(lambda t: add(t, "evil", data=b"x"))
        self.assertEqual(status, 1)
        self.assertIn("not in the manifest", out)

    def test_duplicates(self):
        def build(t):
            add(t, "usr", "dir")
            add(t, "usr", "dir")
        status, out = self.write_tar(build)
        self.assertEqual(status, 1)
        self.assertIn("twice", out)

    def test_a_file_larger_than_the_manifest_says(self):
        def build(t):
            add(t, "usr", "dir")
            add(t, "usr/lib", "dir")
            add(t, "usr/lib/data.txt", data=b"data\n" * 1000)
        status, out = self.write_tar(build)
        self.assertEqual(status, 1)
        self.assertIn("manifest says 5", out)

    def test_a_directory_mode_from_the_tarball_is_what_gets_compared(self):
        def build(t):
            add(t, "usr", "dir", mode=0o700)
        status, out = self.write_tar(build)
        self.assertEqual(status, 1)
        self.assertIn("mode       /usr", out)


if __name__ == "__main__":
    unittest.main()
