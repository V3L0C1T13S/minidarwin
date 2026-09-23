# Rootfs releases: spec, manifest, verification

A minidarwin release is meant to be used as someone else's base system.
This document defines what a release contains, the two formats that describe
it, and what "verified" means. `scripts/mdrootfs.py` is the reference
implementation. It needs only the Python 3.8+ standard library, so a release
can be checked on a machine that has neither Nix nor this checkout.

## What a release is

`nix build .#rootfsRelease` (or `.#cross.x86_64.rootfsRelease`) produces:

| file | what it is |
| --- | --- |
| `minidarwin-rootfs-<arch>-r<N>.tar.gz` | the **artifact**: the rootfs, packed reproducibly |
| `minidarwin-rootfs-<arch>-r<N>.manifest.yaml` | the **manifest**: every path in the tree, with its type, mode and hash |
| `minidarwin-rootfs-<arch>-r<N>.spec.yaml` | the **spec**: the hashes of those two files, plus identity |
| `minidarwin-rootfs-<arch>-r<N>.bundle.zip` | the **bundle**: those three files under fixed names, for passing around as one file |

`N` is `sequence` in `lib/release.nix`. Every one of these files is
reproducible byte for byte. A tagged release publishes them with one change:
the spec is **stamped** with the tag, commit, repository and download URLs.
Stamping adds fields and changes no hash, so `nix build .#rootfsRelease` on the
tagged commit reproduces every hash the published spec pins. The bundle keeps
the unstamped spec, so the bundle is reproducible too.

A release also carries `SHA256SUMS`, which lists every published file for
anyone who wants `sha256sum -c`. It also carries the attestation bundles, as
`*.intoto.jsonl`. Both are made by the workflow, not by Nix.

Each published file also carries a [GitHub artifact
attestation](https://docs.github.com/en/actions/concepts/security/artifact-attestations),
which records the workflow, commit and run that produced it. The attestation
answers a separate question from the hashes. The spec says "this is exactly the
image expected". The attestation says "this is where the published image came
from". Nothing here needs the attestation to verify a release, so everything
works offline.

## Trust chain

```
consumer release (e.g. TrueDarwin vX)
    └── embedded, stamped spec ─────────── pins ──┐
                                                  ▼
            artifact sha256 + size        manifest sha256 + size + tree digest
                    │                                │
            rootfs.tar.gz ── hardened extraction ──▶ tree ── compared with ── manifest
                                                                   │
                                            self-healing: the entries that differ
```

The spec is the root of trust, and nothing verifies the spec itself. It has
to reach the consumer by a route the consumer already trusts, for example
compiled into its release. **Never trust a spec just because it was fetched
over HTTPS.** Do not fetch a "latest" spec automatically.

## The spec

```yaml
# minidarwin rootfs spec. Format: docs/rootfs-spec.md
format: 1
identity:
  arch: "aarch64"
  libsystem: "Libsystem-1356"
  min_os: "26.0"
  project: "minidarwin"
  xnu: "xnu-12377.121.6"
release:
  sequence: 1
  tag: "v1"
  commit: "0123456789abcdef0123456789abcdef01234567"
  repository: "V3L0C1T13S/minidarwin"
artifact:
  name: "minidarwin-rootfs-aarch64-r1.tar.gz"
  format: "tar+gzip"
  size: 1252431
  sha256: "526debbe..."
  sources:
    - "https://github.com/V3L0C1T13S/minidarwin/releases/download/v1/minidarwin-rootfs-aarch64-r1.tar.gz"
manifest:
  name: "minidarwin-rootfs-aarch64-r1.manifest.yaml"
  size: 4030
  sha256: "3b8b9977..."
  tree: "25cfbb7c..."
  sources:
    - "https://github.com/V3L0C1T13S/minidarwin/releases/download/v1/minidarwin-rootfs-aarch64-r1.manifest.yaml"
verification:
  policy: "strict"
```

| field | required | meaning |
| --- | --- | --- |
| `format` | yes | `1`. |
| `identity` | no | String map. If present, it must equal the manifest's `identity`. |
| `release.sequence` | no | A non-negative integer that only ever increases between releases. Use it for rollback protection: a consumer that has accepted release N should not accept an older one as an *automatic* update. |
| `release.tag`, `.commit`, `.repository` | no | Set by stamping. `commit` is a full 40-digit hash. |
| `artifact.format` | yes | `"tar+gzip"`. This is the only format defined. |
| `artifact.sha256` | strict: yes | Lowercase hex SHA-256 of the artifact file. |
| `artifact.size` | no | The size in bytes. If present, it is checked, and it also bounds how much is read. |
| `artifact.name` | no | The file name. It is a hint: the file is identified by its hash. |
| `artifact.sources` | no | A list of `https://` or `file://` URLs. These are only places to fetch from. They identify nothing, and any of them may be a mirror. |
| `manifest.sha256` | strict: yes | SHA-256 of the manifest file's bytes. |
| `manifest.tree` | no | The manifest's tree digest. It is redundant under a strict policy, where `manifest.sha256` already pins the manifest. |
| `manifest.size`, `.name`, `.sources` | no | Same meaning as the `artifact` fields. |
| `verification.policy` | no | `strict` (the default) or `insecure`. |

The policies:

* **`strict`**: both `sha256` fields are required, and every check must pass.
  The official releases are strict.
* **`insecure`**: a `sha256` may be `null`. Any hash that is present is still
  checked, and a missing one is reported as `NOT CHECKED`. Consumers must say so
  loudly, and every time. If you verify a tree against a manifest that somebody
  handed you, you know its integrity but not its authenticity.

Keys inside `artifact`, `manifest`, `release` and `verification` are closed:
an unknown key there is an error, because a verifier that skipped a field it
did not understand could skip a check. Unknown **top-level** keys are ignored,
with a notice. They belong to the consumer. For example, Rosemary's
`system_files: {policy: repair}` can sit in the same file.

A hand-written spec may use any YAML the reference parser accepts (see
[YAML](#yaml)). Only the manifest has to be canonical.

## The manifest

```yaml
# minidarwin rootfs manifest. Format: docs/rootfs-spec.md
format: 1
owner: "minidarwin"
identity:
  arch: "aarch64"
  ...
build:
  llvm: "21.1.8"
  apple_sources:
    - {name: "Libc", rev: "Libc-1752.120.2", hash: "sha256-Vqvw..."}
    ...
tree:
  algorithm: "sha256-merkle-v1"
  digest: "25cfbb7c..."
summary:
  files: 13
  symlinks: 12
  directories: 3
  bytes: 3284480
entries:
  - {path: "/usr", type: "directory", mode: "0755", digest: "7b05be7d..."}
  - {path: "/usr/lib", type: "directory", mode: "0755", digest: "98b43ee6..."}
  - {path: "/usr/lib/libSystem.B.dylib", type: "file", mode: "0755", size: 4368, sha256: "d4d5574a..."}
  - {path: "/usr/lib/libSystem.dylib", type: "symlink", target: "libSystem.B.dylib"}
  ...
```

* **`owner`** is always `minidarwin`. Every path listed is minidarwin's. A
  consumer that layers its own files into the same tree records its own
  ownership separately, so the healers for the two layers never fight over a
  file.
* **`identity`** must contain `project` and `arch`. `arch` is `aarch64` or
  `x86_64` (the Nix `targetArch`, not the Mach-O `arm64`).
* **`build`** is optional provenance. It lists the LLVM version, and every
  pinned Apple source with the Nix hash that pins it. This is the whole OS
  train, including sources the tree does not use yet.
* **`summary`** is derived from `entries` and checked against them.

### Entries

There is one entry per path below `/`. The root has no entry. There are
exactly three types, and each has exactly these keys, in this order:

| type | keys |
| --- | --- |
| `directory` | `path`, `type`, `mode`, `digest` |
| `file` | `path`, `type`, `mode`, `size`, `sha256` |
| `symlink` | `path`, `type`, `target` |

The tree is described by content, type, permissions and symlink targets.
Anything else is deliberately left out:

* **Not described:** owners, groups, timestamps, xattrs, ACLs and flags. A
  Mach-O code signature is part of the file's content, so it is covered.
* **`mode`** is a quoted four-digit octal string. Files are `"0644"` or
  `"0755"`, and directories are always `"0755"`. Nothing is set-id or sticky.
  The reference verifier compares modes exactly. A consumer that installs the
  tree read-only on purpose should compare only the executable bit.
* **`path`** is absolute. Each component is printable ASCII (0x20-0x7e)
  without `/`, and is not `.` or `..`. Unicode is not allowed in format 1,
  because normalization is exactly where two filesystems disagree about
  whether two names are the same name. Two siblings may not differ only in case.
  macOS is case-insensitive, and many Darwin applications assume the same.
* **Order** is depth-first preorder, siblings in bytewise name order. This is
  the same as sorting the paths by their list of components. Every entry's
  parent is `/` or a directory entry that comes before it. Hard links, devices,
  fifos and sockets do not exist in the format.
* **`target`** is relative and has the shape `(../)*name(/name)*`, with at most
  as many leading `..` as the link's own depth. Every `..` comes first, so a
  link can only climb through its own ancestors, which are real directories,
  and then descend. A descent that passes through another link ends up wherever
  that link resolves, and that link is checked the same way. So no chain of
  links can leave the tree, and a checker never has to follow one.
  `mdrootfs manifest` additionally refuses to write a dangling link.

### Tree digest (`sha256-merkle-v1`)

Each node has a digest:

* a **file**: SHA-256 of its content (the entry's `sha256`)
* a **symlink**: SHA-256 of its target's bytes
* a **directory**: SHA-256 over one record per child, children in bytewise
  name order. Each record is:

  ```
  <type> SP <mode> SP <hex digest> SP <name> NUL
  ```

  `<type>` is `file`, `symlink` or `directory`, and a symlink's `<mode>` is `-`.

The directory entries' `digest` fields are those digests. The tree digest is
the root directory's digest. The root's own mode is not part of it.

This gives the unpacked filesystem one identity, independent of how it was
compressed or packed. It also lets you check one subtree alone: if a
directory's recomputed digest matches, everything under it is intact.

**Test vector.** Take this tree:

- `/usr/lib/libA.dylib`: mode 0755, content `cf fa ed fe` followed by ` not really a mach-o\n`
- `/usr/lib/data.txt`: mode 0644, content `data\n`
- `/usr/lib/libB.dylib`: a symlink to `libA.dylib`
- `/usr/share/doc/readme`: mode 0644, empty

Its tree digest is
`1cb4990e4557b548759f593c103a1a05e0d4558f9c5fb0e3b53969165ae88852`. It is the
fixture in `scripts/test_mdrootfs.py`. You can compute it with nothing but
`printf` and `shasum`:

```sh
h() { shasum -a 256 | cut -d' ' -f1; }
A=$(printf '\xcf\xfa\xed\xfe not really a mach-o\n' | h); D=$(printf 'data\n' | h)
E=$(printf '' | h); T=$(printf 'libA.dylib' | h)
doc=$(printf 'file 0644 %s readme\0' $E | h)
share=$(printf 'directory 0755 %s doc\0' $doc | h)
lib=$(printf 'file 0644 %s data.txt\0file 0755 %s libA.dylib\0symlink - %s libB.dylib\0' $D $A $T | h)
usr=$(printf 'directory 0755 %s lib\0directory 0755 %s share\0' $lib $share | h)
printf 'directory 0755 %s usr\0' $usr | h
```

### Canonical form

A manifest's SHA-256 identifies it only if there is exactly one way to write it
down. So the reference verifier re-renders the parsed manifest and requires the
result to be byte-identical to the input. The canonical form is exactly what
`mdrootfs manifest` writes:

* the header comment line
* two-space indentation, and one entry per line as a flow mapping
* keys in the order shown above, with `identity` sorted by key
* every string double-quoted with JSON escaping, and integers bare
* LF line endings and a final newline

A second implementation can parse the manifest with any YAML 1.2 parser,
recompute the tree digest, and rely on `manifest.sha256` from a strict spec for
canonicity. It does not need to re-render anything.

## The artifact

The artifact is a gzip-compressed GNU-format tar of the tree:

* names sorted, and relative, starting with `./`
* uid and gid 0 with no names, and every mtime set to 1
* canonical modes
* no hard links

It is made with GNU tar and `gzip -9n` from a pinned nixpkgs. The pinning is
why the tarball is reproducible, not only its contents.

Extraction assumes hostile input, because a consumer may be handed any archive
at all. The reference extractor (`mdrootfs verify --artifact`) is guided by
the manifest, and refuses:

* absolute names and `..`, and any entry named twice
* anything the manifest does not name, or names as a different type
* anything other than a file, directory or symlink
* an entry whose parent directory the archive has not already made (so nothing
  is ever written through a symlink)
* a file of a different size from the one the manifest gives (so no
  decompression bomb gets past the first header)
* set-id and sticky bits
* a symlink target outside the `(../)*name(/name)*` shape

Content is not hashed during extraction. Afterwards, the tree is compared with
the manifest by the same code that checks a prefix.

## Verifying a tree

`mdrootfs verify --manifest M --tree DIR` compares a directory with a manifest
and reports each difference as one of these:

| kind | meaning |
| --- | --- |
| `missing` | The path does not exist, or its parent is no longer a real directory. |
| `modified` | The file's size or content differs, or the symlink's target differs. |
| `wrong-type` | The path is not the type the manifest says. For example, a symlink has become a file. |
| `mode` | The permissions differ. |
| `unexpected` | The path is not in the manifest. This is not reported with `--allow-extra`, which is what a prefix full of user files needs. |

The comparison never follows a symlink. Suppose `/usr/lib` has been replaced by
a link to a perfect copy somewhere else. `/usr/lib` is then `wrong-type`, and
everything under it is `missing`. It is not "verified".

That list is what self-healing needs. Every path it names can be restored from
the verified, unpacked base. No other path needs touching.

## Commands

```sh
# Build a release locally, and check the published one against it.
nix build .#rootfsRelease
nix run .#mdrootfs -- verify --spec published.spec.yaml \
    --manifest result/*.manifest.yaml --artifact result/*.tar.gz

# Check a download without Nix.
python3 scripts/mdrootfs.py verify --spec S.spec.yaml --manifest S.manifest.yaml --artifact S.tar.gz
python3 scripts/mdrootfs.py verify --bundle B.bundle.zip                 # integrity only
python3 scripts/mdrootfs.py verify --bundle B.bundle.zip --spec trusted.spec.yaml

# Keep the verified tree, then check it again later, e.g. as a prefix's root.
python3 scripts/mdrootfs.py verify ... --extract-to base/
python3 scripts/mdrootfs.py verify --manifest M --tree prefix/root --allow-extra

# Where the published files came from.
gh attestation verify minidarwin-rootfs-aarch64-r1.tar.gz -R V3L0C1T13S/minidarwin
```

When a bundle is verified together with `--spec`, the spec on the command line
is the one that counts, and the spec inside the bundle is ignored. A consumer
uses this when a user hands it a bundle of the official image.

Exit status: `0` means verified, `1` means verification failed, and `2` means
the command line was wrong.

## Releasing

1. Bump `sequence` in `lib/release.nix`, and commit.
2. Tag the commit `v*`, and push the tag.

The workflow builds and checks both architectures, and runs `--rebuild` on the
release derivation to prove it is deterministic. It then verifies each release
on Linux with the stock Python, which is the path a consumer takes. It stamps
each spec using the previous release's spec as `--previous`. **The workflow
fails if the sequence did not go up.** Finally, it attests every file and
publishes them.

To update a consumer, copy the stamped `*.spec.yaml` files from the release
into the consumer's tree. The consumer's release now names exactly one minidarwin
image per architecture.

## YAML

Everything minidarwin writes is YAML that any YAML 1.2 parser reads. The
reference parser accepts only a strict subset:

* block mappings
* block lists, whose items are scalars or flow mappings
* flow mappings, and flow lists of scalars
* double-quoted (JSON-escaped), single-quoted and plain scalars
* integers, `true`, `false` and `null`
* comments and a leading `---`

It refuses anchors, tags and multi-line scalars. It also refuses two things
that other parsers would silently read as something else:

* **Floats.** `min_os: 26.0` would silently become the number 26.
* **Integers with a leading zero.** `0755` is octal in YAML 1.1 and decimal in
  YAML 1.2.

Quote those values.
