# mdpkg

`mdpkg` installs flat `.pkg` files into an offline directory tree, typically a
writable copy of the MiniDarwin rootfs. It uses libxml2, zlib and
LibreSSL/OpenSSL, not CoreFoundation or Apple's Installer, and it never
installs into the running system.

```
mdpkg inspect --pkg FILE
mdpkg install --pkg FILE --root DIRECTORY [--script-runner EXECUTABLE]
```

There are two builds of the same sources:

- `nix build .#installer` is `/usr/bin/mdpkg` in the rootfs, built with the
  MiniDarwin toolchain against MiniDarwin's own libraries.
- `nix build .#installerBootstrap` (or `nix run .#mdpkg`) is a host build that
  also provides `libexec/mdpkg-sandbox-runner`. MiniDarwin has no dyld yet,
  so this is the build that can actually populate a root today.

## What is supported

- **Container:** XAR version 1, members stored raw or zlib-compressed. The
  TOC checksum and every member's archived and extracted checksums (SHA-1,
  MD5, SHA-256 or SHA-512) are verified. Signatures are not checked:
  checksums detect corruption, they do not establish who made the package.
- **Packages:** a bare component package, or a product archive whose
  Distribution statically selects embedded components (`#name.pkg`
  references, percent-encoded or not). `hostArchitectures` is shown by
  `inspect` and not enforced: the root's architecture is not the host's.
- **Payloads:** raw or gzip CPIO in odc, newc or crc format, holding regular
  files, directories and symlinks.
- **Scripts:** `preflight`, `preinstall`, `postinstall` and `postflight`,
  run through a script runner (below).

Refused, before the root is touched: other compressions (pbzx, bzip2),
Distribution JavaScript (`<script>`, `installation-check`, `volume-check`,
non-literal `selected`/`enabled`/`active`, ...), external package
references, hardlinks, device nodes, FIFOs, set-id bits, AppleDouble files,
DTDs in any XML, and unknown PackageInfo or Distribution elements.

Bundle upgrade and relocation data (`bundle-version`, `relocate`, ...) is
accepted and ignored: it only matters when the bundle is already installed,
and mdpkg refuses reinstalls. There is no uninstall or upgrade.

## Paths

Payload paths are relative to the root plus the component's
`install-location`. They follow symlinks already in the root, as Apple's
installer does: on MiniDarwin, `/etc` is a link to `private/etc`, so a
package's `/etc/x` is written to `/private/etc/x`. A link that would lead out
of the root (by `..`, an absolute target or a chain of links) is an error,
whether it is in the root or in the payload.

Existing directories are kept as they are. Any other existing file at a
payload path is a collision and fails the install, as does a package whose
receipt is already present. `/private/var/db/receipts`, `/private/var/db/mdpkg`
and `/.mdpkg-scripts` are reserved.

Files and new directories get the packaged mode and modification time. Run as
root, mdpkg also applies the packaged owner and group; otherwise files belong
to the installing user and the requested owner is only recorded.

## Transactions

`--root` must be a real directory (not a symlink, not `/`, not in the Nix
store) whose parent is writable. mdpkg

1. takes an exclusive lock on `ROOT.mdpkg-lock` (the file is left behind);
2. validates the whole package and checks for collisions;
3. copies the root into `ROOT.mdpkg-transaction/new` -- APFS clones where
   possible, never hard links -- refusing entries with file flags or
   extended attributes that the copy would lose;
4. runs scripts, extracts payloads and writes receipts in the copy, and puts
   base directories' modes and times back;
5. swaps the copy in with two renames, then deletes the original.

Any failure before step 5 leaves the root untouched. A run interrupted inside
step 5 is resolved by the next `mdpkg install` on that root: it rolls back if
only the first rename happened, and completes otherwise. Between the renames
the root does not exist, so nothing may be using it: this is for offline
roots, not live systems.

## Script runners

Packages with scripts need `--script-runner`; there is no fallback that runs
scripts directly. A runner is invoked as

```
RUNNER SCRIPT WORKDIR PACKAGE TARGET STAGED_ROOT
```

in `WORKDIR` (inside the staged root), with `COMMAND_LINE_INSTALL=1`,
`PACKAGE_PATH`, `DSTVOLUME` (= `STAGED_ROOT`), `DSTROOT` (= `TARGET`),
`INSTALLER_TEMP` and `TMPDIR` set. It must run the script as
`SCRIPT PACKAGE TARGET STAGED_ROOT`, the arguments Apple's installer passes
when installing to another volume, and exit non-zero if the script does. A
runner is trusted: it is responsible for isolation.

`mdpkg-sandbox-runner` (bootstrap build, macOS only) runs the script with a
fixed bash and a `PATH` of coreutils, sed, grep and findutils, under
`sandbox-exec`: writes only beneath the staged root and to `/dev/null`, no
network, and no executables but that shell and those tools. Scripts must be
`sh` or `bash` scripts. The host stays readable, so this confines what a
script can change, not what it can see, and it is not a MiniDarwin runtime:
MiniDarwin binaries cannot run there. `sandbox-exec` cannot nest inside Nix's
build sandbox, so script-bearing packages are installed outside of Nix builds.

## Receipts

Per installed component:

- `/private/var/db/receipts/ID.plist`: `PackageIdentifier`, `PackageVersion`,
  `PackageFileName`, `InstallPrefixPath`, `InstallProcessName` (`mdpkg`) and
  `InstallDate` (`SOURCE_DATE_EPOCH` if set), as Apple writes them;
  `pkgutil --volume ROOT` reads them.
- `/private/var/db/receipts/ID.bom`: the package's BOM, unchanged.
- `/private/var/db/mdpkg/ID.inventory.plist`: every payload entry as
  installed (path, packaged path where a symlink redirected it, type, mode,
  requested uid/gid, symlink target, SHA-256), and every entry the package's
  scripts created, modified or removed.

These are extra files in a writable copy of the rootfs; they do not change the
release manifest (see `docs/rootfs-spec.md`).

## Tests

`nix flake check` runs `scripts/test_mdpkg.py` against the bootstrap build:
fixture packages built from the format descriptions (not with Apple's tools)
covering each supported and refused feature, hostile paths and links, limits,
checksums, collisions, locking, rollback and recovery. The target build is
checked for its load commands and purity but not run.

`scripts/test_mdpkg_mc.py` is the end-to-end proof, run by hand on macOS since
it needs `sandbox-exec`. It extracts the x86_64 release bundle, installs the
pinned Midnight Commander 4.8.7 package (Rudix, with a postinstall script), and
checks all 392 payload entries against the CPIO and BOM, the configuration
files the unmodified postinstall creates, the receipts (with `lsbom` and
`pkgutil` as read-only oracles), that no base file changed and the root
still passes `mdrootfs verify --tree --allow-extra`, and that a
script writing outside the root is stopped by the sandbox.

```bash
python3 scripts/test_mdpkg_mc.py \
  --release "$(nix build .#cross.x86_64.rootfsRelease --print-out-paths --no-link)" \
  --installer "$(nix build .#installerBootstrap --print-out-paths --no-link)/bin/mdpkg" \
  --runner "$(nix build .#installerBootstrap --print-out-paths --no-link)/libexec/mdpkg-sandbox-runner" \
  --pkg "$(nix build .#sources.midnightCommanderPkg --print-out-paths --no-link)"
```

It prints where it left the installed root and `report.json`. MC is installed,
not run: it is an x86_64 binary that needs dyld, libiconv, CoreFoundation and
CoreServices, none of which MiniDarwin has yet.
