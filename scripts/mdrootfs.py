#!/usr/bin/env python3
"""mdrootfs - manifests, specs and verification for minidarwin rootfs releases.

The formats are defined in docs/rootfs-spec.md; this is their reference
implementation. Standard library only, Python 3.8+, so that a release can be
checked on a machine that has neither Nix nor this checkout.

    mdrootfs manifest TREE -o OUT --identity k=v ... [--llvm V] [--apple-source n=rev=hash ...]
    mdrootfs spec --manifest M --artifact A --sequence N -o OUT
    mdrootfs stamp SPEC -o OUT --repository OWNER/REPO --tag T --commit C [--previous SPEC]
    mdrootfs bundle --spec S --manifest M --artifact A -o OUT.zip
    mdrootfs verify [--spec S] [--manifest M] [--artifact A] [--bundle B] [--tree DIR]

Exit status: 0 verified, 1 verification failed, 2 bad usage.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
import tarfile
import tempfile
import zipfile

FORMAT = 1
TREE_ALGORITHM = "sha256-merkle-v1"
ARTIFACT_FORMAT = "tar+gzip"
OWNER = "minidarwin"

MANIFEST_HEADER = "# minidarwin rootfs manifest. Format: docs/rootfs-spec.md\n"
SPEC_HEADER = "# minidarwin rootfs spec. Format: docs/rootfs-spec.md\n"

# Fixed names inside a bundle, whatever the release calls the files outside it.
BUNDLE_SPEC = "spec.yaml"
BUNDLE_MANIFEST = "manifest.yaml"
BUNDLE_ARTIFACT = "rootfs.tar.gz"
BUNDLE_MEMBERS = (BUNDLE_SPEC, BUNDLE_MANIFEST, BUNDLE_ARTIFACT)

FILE_MODES = ("0644", "0755")
DIR_MODE = "0755"
POLICIES = ("strict", "insecure")

HEX64 = re.compile(r"[0-9a-f]{64}\Z")
COMMIT = re.compile(r"[0-9a-f]{40}\Z")
# Printable ASCII without '/'. No Unicode in v1: normalization (NFC vs NFD) is
# exactly where two filesystems disagree about whether two names are one.
NAME = re.compile(r"[\x20-\x2e\x30-\x7e]+\Z")
KEY = re.compile(r"[A-Za-z_][A-Za-z0-9_-]*")
SOURCE_SCHEMES = ("https://", "file://")

# A spec or manifest is small; refuse to buffer anything that is not.
SPEC_LIMIT = 1 << 20
MANIFEST_LIMIT = 64 << 20


class Invalid(Exception):
    """Input that is not what it claims to be. Exit status 1."""


class Usage(Exception):
    """A command line that cannot be acted on. Exit status 2."""


# --- YAML subset ------------------------------------------------------------
#
# Everything this tool writes is YAML that any YAML 1.2 parser reads. What it
# reads back is a strict subset: block mappings, block lists of scalars or flow
# mappings, flow mappings, and scalars that are strings, integers, booleans or
# null. Anchors, tags, multi-line scalars and floats are refused rather than
# guessed at -- `min_os: 26.0` is a float to a YAML parser, and a version that
# silently became 26 would be worse than an error.


def parse_yaml(text, what):
    lines = []
    for number, raw in enumerate(text.split("\n"), 1):
        body = raw.rstrip(" \r")
        stripped = body.lstrip(" ")
        if stripped.startswith("\t") or "\t" in body[: len(body) - len(stripped)]:
            raise Invalid(f"{what}:{number}: tab in indentation")
        if not stripped or stripped.startswith("#"):
            continue
        if stripped == "---" and not lines:
            continue
        lines.append((number, len(body) - len(stripped), stripped))
    if not lines:
        raise Invalid(f"{what}: empty document")
    if lines[0][1] != 0:
        raise Invalid(f"{what}:{lines[0][0]}: document is indented")
    value, end = _block(lines, 0, 0, what)
    if end != len(lines):
        raise Invalid(f"{what}:{lines[end][0]}: unexpected indentation")
    return value


def _is_item(text):
    return text == "-" or text.startswith("- ")


def _block(lines, i, indent, what):
    if _is_item(lines[i][2]):
        return _block_list(lines, i, indent, what)
    return _block_mapping(lines, i, indent, what)


def _block_mapping(lines, i, indent, what):
    result = {}
    while i < len(lines):
        number, col, text = lines[i]
        if col < indent:
            break
        if col > indent:
            raise Invalid(f"{what}:{number}: unexpected indentation")
        if _is_item(text):
            raise Invalid(f"{what}:{number}: list item where a key was expected")
        match = KEY.match(text)
        if not match or text[match.end() : match.end() + 1] != ":":
            raise Invalid(f"{what}:{number}: expected 'key: value'")
        key = match.group(0)
        rest = text[match.end() + 1 :]
        if rest and not rest.startswith(" "):
            raise Invalid(f"{what}:{number}: expected a space after '{key}:'")
        if key in result:
            raise Invalid(f"{what}:{number}: duplicate key '{key}'")
        rest = rest.strip()
        i += 1
        if rest and not rest.startswith("#"):
            result[key] = _inline(rest, number, what)
        elif i < len(lines) and lines[i][1] > indent:
            result[key], i = _block(lines, i, lines[i][1], what)
        elif i < len(lines) and lines[i][1] == indent and _is_item(lines[i][2]):
            # The compact form: list items at the key's own indentation.
            result[key], i = _block_list(lines, i, indent, what)
        else:
            result[key] = None
    return result, i


def _block_list(lines, i, indent, what):
    items = []
    while i < len(lines):
        number, col, text = lines[i]
        if col < indent:
            break
        if col > indent:
            raise Invalid(f"{what}:{number}: unexpected indentation")
        if not _is_item(text):
            break
        rest = text[1:].strip()
        if not rest or rest.startswith("#"):
            raise Invalid(f"{what}:{number}: nested blocks in a list are not supported")
        if re.match(r"[A-Za-z_][A-Za-z0-9_-]*:( |$)", rest):
            raise Invalid(
                f"{what}:{number}: block mappings in a list are not supported; "
                "write the item as {key: value, ...}"
            )
        items.append(_inline(rest, number, what))
        i += 1
    return items, i


def _inline(text, number, what):
    value, pos = _value(text, 0, number, what, flow=False)
    tail = text[pos:].strip()
    if tail and not tail.startswith("#"):
        raise Invalid(f"{what}:{number}: unexpected '{tail}' after value")
    return value


_JSON = json.JSONDecoder()


def _skip(text, pos):
    while pos < len(text) and text[pos] == " ":
        pos += 1
    return pos


def _value(text, pos, number, what, flow):
    pos = _skip(text, pos)
    c = text[pos : pos + 1]
    if c == '"':
        try:
            value, end = _JSON.raw_decode(text, pos)
        except ValueError:
            raise Invalid(f"{what}:{number}: malformed double-quoted string") from None
        return value, end
    if c == "'":
        parts = []
        j = pos + 1
        while True:
            k = text.find("'", j)
            if k < 0:
                raise Invalid(f"{what}:{number}: unterminated single-quoted string")
            parts.append(text[j:k])
            if text[k + 1 : k + 2] == "'":
                parts.append("'")
                j = k + 2
                continue
            return "".join(parts), k + 1
    if c == "{":
        return _flow_mapping(text, pos, number, what)
    if c == "[":
        return _flow_list(text, pos, number, what)
    if not c:
        raise Invalid(f"{what}:{number}: missing value")
    if c in "&*!|>%@`,]}#":
        raise Invalid(f"{what}:{number}: unsupported YAML construct '{c}'")
    end = len(text)
    for stop in [" #"] + ([",", "]", "}"] if flow else []):
        k = text.find(stop, pos)
        if k >= 0:
            end = min(end, k)
    token = text[pos:end].strip()
    if ": " in token or token.endswith(":"):
        raise Invalid(f"{what}:{number}: ambiguous plain scalar '{token}'; quote it")
    return _plain(token, number, what), end


def _plain(token, number, what):
    if token in ("null", "Null", "NULL", "~"):
        return None
    if token in ("true", "True", "TRUE"):
        return True
    if token in ("false", "False", "FALSE"):
        return False
    if re.fullmatch(r"[-+]?[0-9]+", token):
        if re.fullmatch(r"[-+]?0[0-9]+", token):
            # 0755 is octal to YAML 1.1 and decimal to 1.2.
            raise Invalid(f"{what}:{number}: '{token}' has a leading zero; quote it")
        return int(token)
    if re.fullmatch(r"[-+]?(\.[0-9]+|[0-9]+\.[0-9]*)([eE][-+]?[0-9]+)?|[-+]?\.(inf|Inf|INF)|\.(nan|NaN|NAN)", token):
        raise Invalid(f"{what}:{number}: '{token}' would be a float; quote it")
    return token


def _flow_mapping(text, pos, number, what):
    result = {}
    pos = _skip(text, pos + 1)
    if text[pos : pos + 1] == "}":
        return result, pos + 1
    while True:
        pos = _skip(text, pos)
        match = KEY.match(text, pos)
        if not match or text[match.end() : match.end() + 1] != ":":
            raise Invalid(f"{what}:{number}: expected 'key: value' in flow mapping")
        key = match.group(0)
        if key in result:
            raise Invalid(f"{what}:{number}: duplicate key '{key}'")
        result[key], pos = _value(text, match.end() + 1, number, what, flow=True)
        pos = _skip(text, pos)
        c = text[pos : pos + 1]
        if c == ",":
            pos += 1
        elif c == "}":
            return result, pos + 1
        else:
            raise Invalid(f"{what}:{number}: expected ',' or '}}' in flow mapping")


def _flow_list(text, pos, number, what):
    items = []
    pos = _skip(text, pos + 1)
    if text[pos : pos + 1] == "]":
        return items, pos + 1
    while True:
        value, pos = _value(text, pos, number, what, flow=True)
        items.append(value)
        pos = _skip(text, pos)
        c = text[pos : pos + 1]
        if c == ",":
            pos += 1
        elif c == "]":
            return items, pos + 1
        else:
            raise Invalid(f"{what}:{number}: expected ',' or ']' in flow list")


def _scalar(value):
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=True)
    raise TypeError(value)


def _flow(mapping):
    return "{" + ", ".join(f"{k}: {_scalar(v)}" for k, v in mapping.items()) + "}"


def _emit(mapping, indent, out):
    pad = " " * indent
    for key, value in mapping.items():
        if isinstance(value, dict):
            if not value:
                out.append(f"{pad}{key}: {{}}")
            else:
                out.append(f"{pad}{key}:")
                _emit(value, indent + 2, out)
        elif isinstance(value, list):
            if not value:
                out.append(f"{pad}{key}: []")
            else:
                out.append(f"{pad}{key}:")
                for item in value:
                    rendered = _flow(item) if isinstance(item, dict) else _scalar(item)
                    out.append(f"{pad}  - {rendered}")
        else:
            out.append(f"{pad}{key}: {_scalar(value)}")


def dump_yaml(header, document):
    out = []
    _emit(document, 0, out)
    return header + "\n".join(out) + "\n"


# --- schema helpers ---------------------------------------------------------


def _mapping(value, what):
    if not isinstance(value, dict):
        raise Invalid(f"{what}: expected a mapping")
    return value


def _keys(mapping, allowed, what, required=()):
    unknown = [k for k in mapping if k not in allowed]
    if unknown:
        raise Invalid(f"{what}: unknown key '{unknown[0]}'")
    for key in required:
        if key not in mapping:
            raise Invalid(f"{what}: missing '{key}'")


def _str(value, what, optional=False):
    if value is None and optional:
        return None
    if not isinstance(value, str) or not value:
        raise Invalid(f"{what}: expected a non-empty string")
    return value


def _int(value, what, optional=False):
    if value is None and optional:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise Invalid(f"{what}: expected a non-negative integer")
    return value


def _hex(value, what, optional=False):
    if value is None and optional:
        return None
    if not isinstance(value, str) or not HEX64.match(value):
        raise Invalid(f"{what}: expected 64 lowercase hex digits")
    return value


def _string_map(value, what):
    mapping = _mapping(value, what)
    for key, item in mapping.items():
        _str(item, f"{what}.{key}")
    return {k: mapping[k] for k in sorted(mapping)}


def _sources(value, what):
    if value is None:
        return []
    if not isinstance(value, list):
        raise Invalid(f"{what}: expected a list")
    for index, url in enumerate(value):
        _str(url, f"{what}[{index}]")
        if not url.startswith(SOURCE_SCHEMES):
            raise Invalid(f"{what}[{index}]: '{url}' is not an https:// or file:// URL")
    return list(value)


def sha256_file(path):
    digest = hashlib.sha256()
    size = 0
    with open(path, "rb") as f:
        while True:
            block = f.read(1 << 20)
            if not block:
                break
            digest.update(block)
            size += len(block)
    return digest.hexdigest(), size


# --- paths ------------------------------------------------------------------


def split_path(path, what):
    """'/usr/lib/x' -> ['usr', 'lib', 'x'], refusing anything that is not a
    plain absolute path with safe components."""
    if not isinstance(path, str) or not path.startswith("/") or path == "/":
        raise Invalid(f"{what}: '{path}' is not an absolute path below /")
    parts = path[1:].split("/")
    for part in parts:
        if part in ("", ".", "..") or not NAME.match(part):
            raise Invalid(f"{what}: '{path}' has an unsafe component '{part}'")
    return parts


def parent_of(path):
    return path.rsplit("/", 1)[0] or "/"


def name_of(path):
    return path.rsplit("/", 1)[1]


def check_symlink_target(path, target, what):
    """Relative, and resolving inside the tree whatever the other links are.

    The target must be `(../)*name(/name)*`: every `..` comes first, so it only
    ever climbs through the link's own ancestors -- which are directories,
    because every entry's parent is -- and then descends. A descent through
    another link lands wherever that link resolves, which is checked the same
    way. So no chain of links leaves the tree, and nothing needs following.
    """
    if not isinstance(target, str) or not target:
        raise Invalid(f"{what}: symlink '{path}' has no target")
    if target.startswith("/"):
        raise Invalid(f"{what}: symlink '{path}' -> '{target}' is absolute")
    parts = target.split("/")
    ups = 0
    while ups < len(parts) and parts[ups] == "..":
        ups += 1
    names = parts[ups:]
    if not names:
        raise Invalid(f"{what}: symlink '{path}' -> '{target}' names no file")
    for part in names:
        if part in ("", ".", "..") or not NAME.match(part):
            raise Invalid(f"{what}: symlink '{path}' -> '{target}' is not (../)*name(/name)*")
    depth = path.count("/") - 1
    if ups > depth:
        raise Invalid(f"{what}: symlink '{path}' -> '{target}' leaves the tree")


# --- manifest ---------------------------------------------------------------


def _entry(path, kind, mode=None, size=None, sha256=None, target=None, digest=None):
    """An entry with its keys in the one canonical order for its type."""
    if kind == "directory":
        return {"path": path, "type": kind, "mode": mode, "digest": digest}
    if kind == "file":
        return {"path": path, "type": kind, "mode": mode, "size": size, "sha256": sha256}
    return {"path": path, "type": kind, "target": target}


def _record(entry, digests):
    name = name_of(entry["path"])
    if entry["type"] == "file":
        line = f"file {entry['mode']} {entry['sha256']} {name}"
    elif entry["type"] == "symlink":
        target = hashlib.sha256(entry["target"].encode("ascii")).hexdigest()
        line = f"symlink - {target} {name}"
    else:
        line = f"directory {entry['mode']} {digests[entry['path']]} {name}"
    return line.encode("ascii") + b"\0"


def merkle(entries):
    """(tree digest, {directory path: digest}) for entries in canonical order.

    A directory's digest is SHA-256 over one record per child, children in
    bytewise name order, each record `<type> <mode> <digest> <name>` + NUL. A
    file's digest is the SHA-256 of its content, a symlink's that of its
    target, and a symlink's mode is written '-'. The tree digest is the root
    directory's, whose own mode is not part of anything.
    """
    children = {"/": []}
    for entry in entries:
        children[parent_of(entry["path"])].append(entry)
        if entry["type"] == "directory":
            children[entry["path"]] = []
    digests = {}

    def directory(path):
        h = hashlib.sha256()
        for child in sorted(children[path], key=lambda e: name_of(e["path"])):
            h.update(_record(child, digests))
        return h.hexdigest()

    for entry in reversed(entries):
        if entry["type"] == "directory":
            digests[entry["path"]] = directory(entry["path"])
    return directory("/"), digests


def check_entries(entries, what):
    """Order, uniqueness, parents and per-type fields. Does not check digests."""
    directories = {"/"}
    siblings = {}
    previous = None
    for index, entry in enumerate(entries):
        where = f"{what}: entries[{index}]"
        _mapping(entry, where)
        kind = entry.get("type")
        if kind == "file":
            expected = ["path", "type", "mode", "size", "sha256"]
        elif kind == "symlink":
            expected = ["path", "type", "target"]
        elif kind == "directory":
            expected = ["path", "type", "mode", "digest"]
        else:
            raise Invalid(f"{where}: unknown type '{kind}'")
        if list(entry) != expected:
            raise Invalid(f"{where}: a {kind} has exactly the keys {', '.join(expected)}, in that order")
        path = entry["path"]
        parts = split_path(path, where)
        if previous is not None and parts <= previous:
            raise Invalid(f"{where}: '{path}' is out of order or repeated")
        previous = parts
        parent = parent_of(path)
        if parent not in directories:
            raise Invalid(f"{where}: parent of '{path}' is not a directory listed before it")
        folded = siblings.setdefault(parent, {})
        other = folded.get(parts[-1].lower())
        if other is not None:
            raise Invalid(f"{where}: '{path}' and '{other}' differ only in case")
        folded[parts[-1].lower()] = path
        if kind == "file":
            if entry["mode"] not in FILE_MODES:
                raise Invalid(f"{where}: file mode must be one of {', '.join(FILE_MODES)}")
            _int(entry["size"], f"{where}.size")
            _hex(entry["sha256"], f"{where}.sha256")
        elif kind == "directory":
            if entry["mode"] != DIR_MODE:
                raise Invalid(f"{where}: directory mode must be {DIR_MODE}")
            _hex(entry["digest"], f"{where}.digest")
            directories.add(path)
        else:
            check_symlink_target(path, entry["target"], where)


def manifest_document(identity, build, entries):
    tree, digests = merkle(entries)
    finished = []
    for entry in entries:
        if entry["type"] == "directory":
            entry = dict(entry, digest=digests[entry["path"]])
        finished.append(entry)
    document = {
        "format": FORMAT,
        "owner": OWNER,
        "identity": identity,
    }
    if build is not None:
        document["build"] = build
    document["tree"] = {"algorithm": TREE_ALGORITHM, "digest": tree}
    document["summary"] = {
        "files": sum(e["type"] == "file" for e in entries),
        "symlinks": sum(e["type"] == "symlink" for e in entries),
        "directories": sum(e["type"] == "directory" for e in entries),
        "bytes": sum(e["size"] for e in entries if e["type"] == "file"),
    }
    document["entries"] = finished
    return document


def _build_section(value, what):
    build = _mapping(value, what)
    _keys(build, ("llvm", "apple_sources"), what)
    result = {}
    if "llvm" in build:
        result["llvm"] = _str(build["llvm"], f"{what}.llvm")
    if "apple_sources" in build:
        sources = build["apple_sources"]
        if not isinstance(sources, list):
            raise Invalid(f"{what}.apple_sources: expected a list")
        clean = []
        for index, source in enumerate(sources):
            where = f"{what}.apple_sources[{index}]"
            _mapping(source, where)
            if list(source) != ["name", "rev", "hash"]:
                raise Invalid(f"{where}: expected exactly name, rev, hash")
            clean.append({k: _str(source[k], f"{where}.{k}") for k in ("name", "rev", "hash")})
        if [s["name"] for s in clean] != sorted({s["name"] for s in clean}):
            raise Invalid(f"{what}.apple_sources: names must be unique and sorted")
        result["apple_sources"] = clean
    return result


class Manifest:
    def __init__(self, document, text):
        self.document = document
        self.text = text
        self.entries = document["entries"]
        self.tree = document["tree"]["digest"]
        self.identity = document["identity"]
        self.by_path = {e["path"]: e for e in self.entries}


def load_manifest(path):
    what = os.path.basename(path)
    with open(path, "rb") as f:
        raw = f.read(MANIFEST_LIMIT + 1)
    if len(raw) > MANIFEST_LIMIT:
        raise Invalid(f"{what}: larger than {MANIFEST_LIMIT} bytes")
    try:
        text = raw.decode("ascii")
    except UnicodeDecodeError:
        raise Invalid(f"{what}: not ASCII") from None
    data = _mapping(parse_yaml(text, what), what)
    _keys(data, ("format", "owner", "identity", "build", "tree", "summary", "entries"), what,
          required=("format", "owner", "identity", "tree", "summary", "entries"))
    if data["format"] != FORMAT:
        raise Invalid(f"{what}: format {data['format']!r} is not {FORMAT}")
    if data["owner"] != OWNER:
        raise Invalid(f"{what}: owner must be '{OWNER}'")
    identity = _string_map(data["identity"], f"{what}.identity")
    for key in ("project", "arch"):
        if key not in identity:
            raise Invalid(f"{what}.identity: missing '{key}'")
    build = _build_section(data["build"], f"{what}.build") if "build" in data else None
    tree = _mapping(data["tree"], f"{what}.tree")
    _keys(tree, ("algorithm", "digest"), f"{what}.tree", required=("algorithm", "digest"))
    if tree["algorithm"] != TREE_ALGORITHM:
        raise Invalid(f"{what}.tree: algorithm '{tree['algorithm']}' is not {TREE_ALGORITHM}")
    _hex(tree["digest"], f"{what}.tree.digest")
    entries = data["entries"]
    if not isinstance(entries, list):
        raise Invalid(f"{what}.entries: expected a list")
    check_entries(entries, what)

    rebuilt = manifest_document(identity, build, entries)
    if rebuilt["tree"]["digest"] != tree["digest"]:
        raise Invalid(f"{what}: tree digest does not match its entries")
    for mine, theirs in zip(rebuilt["entries"], entries):
        if mine != theirs:
            raise Invalid(f"{what}: digest of directory '{theirs['path']}' does not match its contents")
    if rebuilt["summary"] != data["summary"]:
        raise Invalid(f"{what}: summary does not match its entries")
    # The manifest's own sha256 is only an identity if there is exactly one way
    # to write it down.
    if dump_yaml(MANIFEST_HEADER, rebuilt) != text:
        raise Invalid(f"{what}: not in canonical form (regenerate it with `mdrootfs manifest`)")
    return Manifest(rebuilt, text)


def scan_tree(root, normalize):
    """Entries for the tree at `root`, never following a symlink.

    `normalize` maps permissions onto the canonical set (for making a manifest
    from a read-only store path); otherwise modes are reported as found.
    Returns (entries, problems) where problems are (kind, path, detail).
    """
    entries = []
    problems = []

    def walk(host, guest):
        with os.scandir(host) as it:
            names = sorted(e.name for e in it)
        for name in names:
            path = f"{guest.rstrip('/')}/{name}"
            full = os.path.join(host, name)
            if not NAME.match(name):
                problems.append(("unexpected", path, "name is not printable ASCII"))
                continue
            st = os.lstat(full)
            if stat.S_ISDIR(st.st_mode):
                mode = DIR_MODE if normalize else "%04o" % stat.S_IMODE(st.st_mode)
                entries.append(_entry(path, "directory", mode=mode))
                walk(full, path)
            elif stat.S_ISREG(st.st_mode):
                if normalize:
                    mode = "0755" if st.st_mode & 0o111 else "0644"
                else:
                    mode = "%04o" % stat.S_IMODE(st.st_mode)
                sha, size = sha256_file(full)
                entries.append(_entry(path, "file", mode=mode, size=size, sha256=sha))
            elif stat.S_ISLNK(st.st_mode):
                entries.append(_entry(path, "symlink", target=os.readlink(full)))
            else:
                problems.append(("wrong-type", path, "not a file, directory or symlink"))

    walk(root, "/")
    return entries, problems


# --- spec -------------------------------------------------------------------


class Spec:
    def __init__(self, document, ignored):
        self.document = document
        self.ignored = ignored
        self.identity = document.get("identity")
        self.release = document["release"]
        self.artifact = document["artifact"]
        self.manifest = document["manifest"]
        self.policy = document["verification"]["policy"]


def spec_from(data, what):
    data = _mapping(data, what)
    ignored = [k for k in data if k not in ("format", "identity", "release", "artifact", "manifest", "verification")]
    for key in ("format", "artifact", "manifest"):
        if key not in data:
            raise Invalid(f"{what}: missing '{key}'")
    if data["format"] != FORMAT:
        raise Invalid(f"{what}: format {data['format']!r} is not {FORMAT}")

    verification = _mapping(data.get("verification") or {}, f"{what}.verification")
    _keys(verification, ("policy",), f"{what}.verification")
    policy = verification.get("policy", "strict")
    if policy not in POLICIES:
        raise Invalid(f"{what}.verification.policy: must be one of {', '.join(POLICIES)}")
    strict = policy == "strict"

    identity = None
    if data.get("identity") is not None:
        identity = _string_map(data["identity"], f"{what}.identity")

    release = _mapping(data.get("release") or {}, f"{what}.release")
    _keys(release, ("sequence", "tag", "commit", "repository"), f"{what}.release")
    release = {
        "sequence": _int(release.get("sequence"), f"{what}.release.sequence", optional=True),
        "tag": _str(release.get("tag"), f"{what}.release.tag", optional=True),
        "commit": _str(release.get("commit"), f"{what}.release.commit", optional=True),
        "repository": _str(release.get("repository"), f"{what}.release.repository", optional=True),
    }
    if release["commit"] is not None and not COMMIT.match(release["commit"]):
        raise Invalid(f"{what}.release.commit: expected a full 40-digit commit hash")

    a = _mapping(data["artifact"], f"{what}.artifact")
    _keys(a, ("name", "format", "size", "sha256", "sources"), f"{what}.artifact", required=("format",))
    if a["format"] != ARTIFACT_FORMAT:
        raise Invalid(f"{what}.artifact.format: only '{ARTIFACT_FORMAT}' is defined")
    artifact = {
        "name": _str(a.get("name"), f"{what}.artifact.name", optional=True),
        "format": ARTIFACT_FORMAT,
        "size": _int(a.get("size"), f"{what}.artifact.size", optional=True),
        "sha256": _hex(a.get("sha256"), f"{what}.artifact.sha256", optional=not strict),
        "sources": _sources(a.get("sources"), f"{what}.artifact.sources"),
    }

    m = _mapping(data["manifest"], f"{what}.manifest")
    _keys(m, ("name", "size", "sha256", "tree", "sources"), f"{what}.manifest")
    manifest = {
        "name": _str(m.get("name"), f"{what}.manifest.name", optional=True),
        "size": _int(m.get("size"), f"{what}.manifest.size", optional=True),
        "sha256": _hex(m.get("sha256"), f"{what}.manifest.sha256", optional=not strict),
        "tree": _hex(m.get("tree"), f"{what}.manifest.tree", optional=True),
        "sources": _sources(m.get("sources"), f"{what}.manifest.sources"),
    }

    document = {"format": FORMAT}
    if identity is not None:
        document["identity"] = identity
    document["release"] = release
    document["artifact"] = artifact
    document["manifest"] = manifest
    document["verification"] = {"policy": policy}
    return Spec(document, ignored)


def load_spec(path):
    what = os.path.basename(path)
    with open(path, "rb") as f:
        raw = f.read(SPEC_LIMIT + 1)
    if len(raw) > SPEC_LIMIT:
        raise Invalid(f"{what}: larger than {SPEC_LIMIT} bytes")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        raise Invalid(f"{what}: not UTF-8") from None
    return spec_from(parse_yaml(text, what), what)


# --- extraction -------------------------------------------------------------


def _tar_path(name):
    if "\0" in name:
        raise Invalid(f"tarball: entry name contains NUL")
    if name in (".", "./"):
        return "/"
    if name.startswith("./"):
        name = name[2:]
    name = name.rstrip("/")
    if not name or name.startswith("/"):
        raise Invalid(f"tarball: entry '{name}' is absolute or empty")
    split_path("/" + name, "tarball")
    return "/" + name


def extract(artifact, dest, manifest):
    """Unpack `artifact` into `dest` (which must not exist), refusing anything
    the manifest does not name.

    Hostile input is the assumption. Only files, directories and symlinks; no
    absolute names, no `..`, nothing named twice; every entry's parent is a
    directory this tarball already made, so nothing is ever written through a
    symlink; no file is written past the size the manifest gives it; nothing
    set-id. Content is not hashed here -- the tree is verified afterwards
    against the same manifest, by the same code that verifies a prefix.
    """
    os.mkdir(dest, 0o755)
    made = {"/"}
    modes = []
    seen = set()
    count = 0
    with tarfile.open(artifact, "r|gz") as tar:
        for member in tar:
            path = _tar_path(member.name)
            if path == "/":
                if not member.isdir():
                    raise Invalid("tarball: root entry is not a directory")
                continue
            if path in seen:
                raise Invalid(f"tarball: '{path}' appears twice")
            seen.add(path)
            entry = manifest.by_path.get(path)
            if entry is None:
                raise Invalid(f"tarball: '{path}' is not in the manifest")
            if parent_of(path) not in made:
                raise Invalid(f"tarball: '{path}' comes before its parent directory")
            if member.mode & 0o7000:
                raise Invalid(f"tarball: '{path}' is set-id or sticky")
            mode = member.mode & 0o777
            host = dest + path
            if member.isdir():
                if entry["type"] != "directory":
                    raise Invalid(f"tarball: '{path}' is a directory, manifest says {entry['type']}")
                os.mkdir(host, 0o700)
                modes.append((host, mode))
                made.add(path)
            elif member.isreg():
                if entry["type"] != "file":
                    raise Invalid(f"tarball: '{path}' is a file, manifest says {entry['type']}")
                if member.size != entry["size"]:
                    raise Invalid(f"tarball: '{path}' is {member.size} bytes, manifest says {entry['size']}")
                fd = os.open(host, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                with os.fdopen(fd, "wb") as out:
                    source = tar.extractfile(member)
                    remaining = member.size
                    while remaining:
                        block = source.read(min(remaining, 1 << 20))
                        if not block:
                            raise Invalid(f"tarball: '{path}' is truncated")
                        out.write(block)
                        remaining -= len(block)
                    os.fchmod(out.fileno(), mode)
            elif member.issym():
                if entry["type"] != "symlink":
                    raise Invalid(f"tarball: '{path}' is a symlink, manifest says {entry['type']}")
                check_symlink_target(path, member.linkname, "tarball")
                os.symlink(member.linkname, host)
            else:
                raise Invalid(f"tarball: '{path}' is not a file, directory or symlink")
            count += 1
    # Directories stayed owner-writable while their contents were made; now
    # they get what the tarball asked for, so the comparison sees that.
    for host, mode in reversed(modes):
        os.chmod(host, mode)
    return count


# --- tree comparison ----------------------------------------------------------

KINDS = ("missing", "modified", "wrong-type", "mode", "unexpected")


def _hash_nofollow(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as f:
        if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
            return None
        digest = hashlib.sha256()
        while True:
            block = f.read(1 << 20)
            if not block:
                return digest.hexdigest()
            digest.update(block)


def compare_tree(root, manifest, allow_extra):
    """Problems as (kind, path, detail), in manifest order.

    Nothing below a path that is not a real directory is looked at: had
    `/usr/lib` been replaced by a symlink to somewhere else, lstat-ing
    `/usr/lib/x` would follow it. Those entries are missing, not checked.
    """
    problems = []
    directories = {"/"}
    for entry in manifest.entries:
        path = entry["path"]
        if parent_of(path) not in directories:
            problems.append(("missing", path, "parent is not a directory"))
            continue
        host = root + path
        try:
            st = os.lstat(host)
        except FileNotFoundError:
            problems.append(("missing", path, ""))
            continue
        kind = entry["type"]
        if kind == "directory":
            if not stat.S_ISDIR(st.st_mode):
                problems.append(("wrong-type", path, "expected a directory"))
                continue
            directories.add(path)
            mode = "%04o" % stat.S_IMODE(st.st_mode)
            if mode != entry["mode"]:
                problems.append(("mode", path, f"{mode}, expected {entry['mode']}"))
        elif kind == "file":
            if not stat.S_ISREG(st.st_mode):
                problems.append(("wrong-type", path, "expected a regular file"))
                continue
            mode = "%04o" % stat.S_IMODE(st.st_mode)
            if st.st_size != entry["size"]:
                problems.append(("modified", path, f"{st.st_size} bytes, expected {entry['size']}"))
            elif _hash_nofollow(host) != entry["sha256"]:
                problems.append(("modified", path, "content differs"))
            if mode != entry["mode"]:
                problems.append(("mode", path, f"{mode}, expected {entry['mode']}"))
        else:
            if not stat.S_ISLNK(st.st_mode):
                problems.append(("wrong-type", path, "expected a symlink"))
                continue
            target = os.readlink(host)
            if target != entry["target"]:
                problems.append(("modified", path, f"-> {target}, expected -> {entry['target']}"))

    if not allow_extra:
        def walk(host, guest):
            with os.scandir(host) as it:
                names = sorted(e.name for e in it)
            for name in names:
                path = f"{guest.rstrip('/')}/{name}"
                if path not in manifest.by_path:
                    problems.append(("unexpected", path, ""))
                elif path in directories:
                    walk(os.path.join(host, name), path)

        walk(root, "/")
    return problems


# --- commands ---------------------------------------------------------------


def _pairs(values, what):
    result = {}
    for value in values or []:
        key, sep, item = value.partition("=")
        if not sep or not KEY.fullmatch(key) or not item:
            raise Usage(f"{what}: expected key=value, got '{value}'")
        if key in result:
            raise Usage(f"{what}: '{key}' given twice")
        result[key] = item
    return result


def _write(path, text):
    with open(path, "w", encoding="ascii", newline="\n") as f:
        f.write(text)


def cmd_manifest(args):
    root = os.path.abspath(args.tree)
    identity = _pairs(args.identity, "--identity")
    for key in ("project", "arch"):
        if key not in identity:
            raise Usage(f"--identity {key}=... is required")
    identity = {k: identity[k] for k in sorted(identity)}
    build = None
    if args.llvm or args.apple_source:
        build = {}
        if args.llvm:
            build["llvm"] = args.llvm
        if args.apple_source:
            sources = []
            for value in args.apple_source:
                parts = value.split("=", 2)
                if len(parts) != 3 or not all(parts):
                    raise Usage(f"--apple-source: expected name=rev=hash, got '{value}'")
                sources.append({"name": parts[0], "rev": parts[1], "hash": parts[2]})
            build["apple_sources"] = sorted(sources, key=lambda s: s["name"])

    entries, problems = scan_tree(root, normalize=True)
    if problems:
        raise Invalid("tree: " + "; ".join(f"{p}: {d}" for _, p, d in problems))
    document = manifest_document(identity, build, entries)
    check_entries(document["entries"], "tree")
    # Every link must land on something in the tree: a dangling one is a
    # packaging mistake, and the manifest is the place to catch it.
    real_root = os.path.realpath(root)
    for entry in entries:
        if entry["type"] == "symlink":
            resolved = os.path.realpath(root + entry["path"])
            if not (resolved + "/").startswith(real_root + "/") or not os.path.exists(resolved):
                raise Invalid(f"tree: symlink '{entry['path']}' -> '{entry['target']}' is dangling")
    _write(args.output, dump_yaml(MANIFEST_HEADER, document))
    s = document["summary"]
    print(f"manifest: {s['files']} files, {s['symlinks']} symlinks, {s['directories']} directories, "
          f"tree {document['tree']['digest']}")


def cmd_spec(args):
    manifest = load_manifest(args.manifest)
    manifest_sha, manifest_size = sha256_file(args.manifest)
    artifact_sha, artifact_size = sha256_file(args.artifact)
    document = {
        "format": FORMAT,
        "identity": manifest.identity,
        "release": {"sequence": args.sequence, "tag": None, "commit": None, "repository": None},
        "artifact": {
            "name": os.path.basename(args.artifact),
            "format": ARTIFACT_FORMAT,
            "size": artifact_size,
            "sha256": artifact_sha,
            "sources": [],
        },
        "manifest": {
            "name": os.path.basename(args.manifest),
            "size": manifest_size,
            "sha256": manifest_sha,
            "tree": manifest.tree,
            "sources": [],
        },
        "verification": {"policy": "strict"},
    }
    _write(args.output, dump_yaml(SPEC_HEADER, document))
    print(f"spec: artifact {artifact_sha}, manifest {manifest_sha}")


def cmd_stamp(args):
    spec = load_spec(args.spec)
    document = spec.document
    if spec.policy != "strict":
        raise Invalid("stamp: only a strict spec is released")
    if spec.release["tag"] is not None:
        raise Invalid(f"stamp: {args.spec} is already stamped ({spec.release['tag']})")
    if spec.release["sequence"] is None:
        raise Invalid("stamp: the spec has no release.sequence")
    if not COMMIT.match(args.commit):
        raise Usage("--commit: expected a full 40-digit commit hash")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository):
        raise Usage("--repository: expected OWNER/REPO")
    if not args.tag or "/" in args.tag:
        raise Usage("--tag: expected a tag name")
    if args.previous:
        previous = load_spec(args.previous)
        if previous.release["sequence"] is None or previous.release["sequence"] >= spec.release["sequence"]:
            raise Invalid(
                f"stamp: release.sequence {spec.release['sequence']} does not follow the previous "
                f"release's {previous.release['sequence']} -- bump lib/release.nix"
            )
    for name in ("artifact", "manifest"):
        if document[name]["name"] is None:
            raise Invalid(f"stamp: {name}.name is needed to form its URL")
    base = args.base_url or f"https://github.com/{args.repository}/releases/download/{args.tag}"
    document["release"] = {
        "sequence": spec.release["sequence"],
        "tag": args.tag,
        "commit": args.commit,
        "repository": args.repository,
    }
    document["artifact"]["sources"] = [f"{base.rstrip('/')}/{document['artifact']['name']}"]
    document["manifest"]["sources"] = [f"{base.rstrip('/')}/{document['manifest']['name']}"]
    _sources(document["artifact"]["sources"], "stamp")
    _write(args.output, dump_yaml(SPEC_HEADER, document))
    print(f"stamp: {args.tag} ({args.commit[:12]}), release {spec.release['sequence']}")


def cmd_bundle(args):
    # Stored, fixed timestamps and attributes, fixed order: the zip is as
    # reproducible as what is in it.
    with zipfile.ZipFile(args.output, "w", compression=zipfile.ZIP_STORED) as z:
        for arcname, path in ((BUNDLE_SPEC, args.spec), (BUNDLE_MANIFEST, args.manifest),
                              (BUNDLE_ARTIFACT, args.artifact)):
            info = zipfile.ZipInfo(arcname, date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = (stat.S_IFREG | 0o644) << 16
            info.compress_type = zipfile.ZIP_STORED
            with open(path, "rb") as f:
                z.writestr(info, f.read())
    print(f"bundle: {args.output}")


def open_bundle(path, into, spec):
    """Copy the three members of a bundle into `into`, refusing anything else."""
    os.mkdir(into)
    with zipfile.ZipFile(path) as z:
        infos = z.infolist()
        names = [i.filename for i in infos]
        if sorted(names) != sorted(BUNDLE_MEMBERS):
            raise Invalid(f"bundle: members must be exactly {', '.join(BUNDLE_MEMBERS)}; found {', '.join(names)}")
        limits = {BUNDLE_SPEC: SPEC_LIMIT, BUNDLE_MANIFEST: MANIFEST_LIMIT, BUNDLE_ARTIFACT: None}
        for info in infos:
            limit = limits[info.filename]
            if info.filename == BUNDLE_ARTIFACT and spec is not None and spec.artifact["size"] is not None:
                limit = spec.artifact["size"]
            written = 0
            with z.open(info) as source, open(os.path.join(into, info.filename), "xb") as out:
                while True:
                    block = source.read(1 << 20)
                    if not block:
                        break
                    written += len(block)
                    if limit is not None and written > limit:
                        raise Invalid(f"bundle: {info.filename} is larger than {limit} bytes")
                    out.write(block)
    return tuple(os.path.join(into, name) for name in BUNDLE_MEMBERS)


def check_file(path, size, sha256, what):
    actual_sha, actual_size = sha256_file(path)
    if size is not None and actual_size != size:
        raise Invalid(f"{what}: {actual_size} bytes, spec says {size}")
    if sha256 is None:
        return actual_sha, actual_size, False
    if actual_sha != sha256:
        raise Invalid(f"{what}: sha256 {actual_sha}, spec says {sha256}")
    return actual_sha, actual_size, True


def _report(problems, total, what):
    counts = {k: 0 for k in KINDS}
    for kind, path, detail in problems:
        counts[kind] += 1
        print(f"  {kind:<10} {path}" + (f"  ({detail})" if detail else ""))
    print(f"{what}: {total} entries checked, " + ", ".join(f"{counts[k]} {k}" for k in KINDS))
    return not problems


def cmd_verify(args):
    if not (args.spec or args.manifest or args.artifact or args.bundle):
        raise Usage("verify: give at least one of --spec, --manifest, --artifact, --bundle")
    if args.extract_to and os.path.lexists(args.extract_to):
        raise Usage(f"--extract-to: {args.extract_to} already exists")
    ok = True
    with tempfile.TemporaryDirectory(prefix="mdrootfs-") as tmp:
        spec_path, manifest_path, artifact_path = args.spec, args.manifest, args.artifact
        spec = load_spec(spec_path) if spec_path else None

        if args.bundle:
            b_spec, b_manifest, b_artifact = open_bundle(args.bundle, os.path.join(tmp, "bundle"), spec)
            if spec is None:
                spec_path = b_spec
                spec = load_spec(b_spec)
                print("spec:      from the bundle -- integrity only; nothing outside it vouches for it")
            else:
                print("spec:      from the command line; the bundle's own spec is ignored")
            manifest_path = manifest_path or b_manifest
            artifact_path = artifact_path or b_artifact

        if spec is not None:
            for key in spec.ignored:
                print(f"spec:      ignoring '{key}' (not part of the minidarwin format)")
            release = spec.release
            if release["tag"]:
                print(f"spec:      release {release['sequence']}, {release['tag']} "
                      f"({(release['commit'] or '?')[:12]}) from {release['repository']}")
            elif release["sequence"] is not None:
                print(f"spec:      release {release['sequence']}, unpublished")
            if spec.policy == "insecure":
                print("spec:      *** verification policy is INSECURE ***", file=sys.stderr)
                print("           Missing hashes are not checked. Whatever is verified below is", file=sys.stderr)
                print("           checked against files that nothing authenticates.", file=sys.stderr)
            if (artifact_path or args.tree) and not manifest_path:
                raise Usage("verify: a spec is checked against a manifest; give --manifest")

        if artifact_path and spec is not None:
            sha, size, checked = check_file(artifact_path, spec.artifact["size"], spec.artifact["sha256"], "artifact")
            print(f"artifact:  {'sha256 ok' if checked else 'NOT CHECKED'} {sha} ({size} bytes)")

        manifest = None
        if manifest_path:
            if spec is not None:
                sha, _, checked = check_file(manifest_path, spec.manifest["size"], spec.manifest["sha256"], "manifest")
                print(f"manifest:  {'sha256 ok' if checked else 'NOT CHECKED'} {sha}")
            manifest = load_manifest(manifest_path)
            s = manifest.document["summary"]
            print(f"manifest:  canonical; tree {manifest.tree}; {s['files']} files, "
                  f"{s['symlinks']} symlinks, {s['directories']} directories, {s['bytes']} bytes")
            if spec is not None:
                if spec.manifest["tree"] is not None and spec.manifest["tree"] != manifest.tree:
                    raise Invalid(f"manifest: tree {manifest.tree}, spec says {spec.manifest['tree']}")
                if spec.identity is not None and spec.identity != manifest.identity:
                    raise Invalid(f"manifest: identity {manifest.identity} differs from the spec's {spec.identity}")
            elif artifact_path or args.tree:
                print("manifest:  no spec -- nothing vouches for this manifest")

        if artifact_path:
            if manifest is None:
                raise Usage("verify: an artifact is checked against a manifest; give --manifest")
            dest = args.extract_to or os.path.join(tmp, "root")
            count = extract(artifact_path, dest, manifest)
            print(f"extract:   {count} entries, every one named by the manifest")
            ok &= _report(compare_tree(dest, manifest, allow_extra=False), len(manifest.entries), "artifact tree")

        if args.tree:
            if manifest is None:
                raise Usage("verify: --tree is checked against a manifest; give --manifest")
            ok &= _report(compare_tree(os.path.abspath(args.tree), manifest, args.allow_extra),
                          len(manifest.entries), "tree")

    print("OK" if ok else "FAILED")
    return 0 if ok else 1


def main(argv=None):
    parser = argparse.ArgumentParser(prog="mdrootfs", description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("manifest", help="write the manifest of a tree")
    p.add_argument("tree")
    p.add_argument("-o", "--output", required=True)
    p.add_argument("--identity", action="append", metavar="KEY=VALUE")
    p.add_argument("--llvm", metavar="VERSION")
    p.add_argument("--apple-source", action="append", metavar="NAME=REV=HASH")
    p.set_defaults(run=cmd_manifest)

    p = sub.add_parser("spec", help="write the spec pinning an artifact and its manifest")
    p.add_argument("--manifest", required=True)
    p.add_argument("--artifact", required=True)
    p.add_argument("--sequence", required=True, type=int)
    p.add_argument("-o", "--output", required=True)
    p.set_defaults(run=cmd_spec)

    p = sub.add_parser("stamp", help="add release identity and download URLs to a spec")
    p.add_argument("spec")
    p.add_argument("-o", "--output", required=True)
    p.add_argument("--repository", required=True, metavar="OWNER/REPO")
    p.add_argument("--tag", required=True)
    p.add_argument("--commit", required=True)
    p.add_argument("--base-url", help="default: the GitHub release download URL for --tag")
    p.add_argument("--previous", metavar="SPEC", help="the last release's spec; its sequence must be lower")
    p.set_defaults(run=cmd_stamp)

    p = sub.add_parser("bundle", help="zip a spec, manifest and artifact together")
    p.add_argument("--spec", required=True)
    p.add_argument("--manifest", required=True)
    p.add_argument("--artifact", required=True)
    p.add_argument("-o", "--output", required=True)
    p.set_defaults(run=cmd_bundle)

    p = sub.add_parser("verify", help="check any combination of spec, manifest, artifact, bundle, tree")
    p.add_argument("--spec")
    p.add_argument("--manifest")
    p.add_argument("--artifact")
    p.add_argument("--bundle")
    p.add_argument("--tree", help="a directory to compare against the manifest (e.g. a prefix's root)")
    p.add_argument("--allow-extra", action="store_true", help="with --tree: files the manifest does not name are fine")
    p.add_argument("--extract-to", metavar="DIR", help="keep the verified extraction here (must not exist)")
    p.set_defaults(run=cmd_verify)

    args = parser.parse_args(argv)
    try:
        return args.run(args) or 0
    except Usage as e:
        print(f"mdrootfs: {e}", file=sys.stderr)
        return 2
    except Invalid as e:
        print(f"mdrootfs: {e}", file=sys.stderr)
        print("FAILED")
        return 1
    except OSError as e:
        print(f"mdrootfs: {e.filename or ''}: {e.strerror or e}", file=sys.stderr)
        print("FAILED")
        return 1


if __name__ == "__main__":
    sys.exit(main())
