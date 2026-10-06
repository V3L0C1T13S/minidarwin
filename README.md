# minidarwin

Pure, reproducible Nix bootstrap of a minimal Darwin userland from Apple's released sources, starting from bare Clang.

## Requirements

- Nix with flakes enabled
- `aarch64-darwin` or `x86_64-darwin` (build host must be Darwin; targets cross-compile)
- macOS 26 SDK release (`xnu-12377` / `minOS = "26.0"`)

## Usage

```bash
# XNU/Darwin specific headers
nix build .#sdk
nix flake check                    # SDK, runtime, libSystem, dispatch, C++ and release checks

# Libraries
nix build .#libsyscall             # libsystem_kernel.dylib
nix build .#libcxx                 # libc++.a (on compiler-rt + libunwind + libc++abi)
nix build .#libdispatch            # Apple's core libdispatch.dylib
nix build .#libSystem              # umbrella libSystem.B.dylib (includes dispatch)
nix build .#libmachO               # dyld's Mach-O reader (stage 5)
nix build .#libdyld                # public dyld API library (stage 5)
nix build .#cross.x86_64.dyld       # self-contained x86_64 dynamic linker
nix build .#efiBootImage .#bootDiskTest # EFI disk and firmware/loader checks
nix run .#qemuEfi                  # boot the EFI loader with QEMU TCG
nix build .#kernel .#kernelBootImage # real x86_64 XNU and its EFI disk
nix run .#qemuKernel               # kernel startup development with QEMU TCG
nix run .#qemuBoot                 # full userland startup, into a shell (Ctrl-A X quits)
nix build .#libcxxDylib .#libcxxabiDylib
nix build .#sdkStage4              # sysroot where plain `-lc++` links (RTTI included)
nix build .#ncurses .#libedit     # libncurses.5.4.dylib, libedit.3.dylib (stage 6)
nix build .#terminfo               # /usr/share/terminfo (stage 6)
nix build .#shellCmds             # date, env, find, id, mktemp, test, xargs, ash, ... (stage 6)
nix build .#libutil .#fileCmds    # libutil.dylib; ls, cp, mv, rm, touch, readlink, ... (stage 6)
nix build .#libmd .#textCmds      # libmd.dylib; cat, grep, sed, sort, head, tail, md5, ... (stage 6)
nix build .#advCmds .#basicCmds    # ps, stty, tty, locale, ...; mesg, write (stage 6)
nix build .#top                   # Apple process monitor and man page (stage 6)
nix build .#systemCmds            # arch, machine, sync, sysctl, getconf, ... (stage 6)
nix build .#patchCmds .#miscCmds .#awk  # diff, cmp, patch; cal, tsort, units; awk (stage 6)
nix build .#libressl              # primary TLS libraries and /usr/bin/openssl (stage 6)
nix build .#curl                  # /usr/bin/curl and static libcurl, linked to LibreSSL (stage 6)
nix build .#bzip2                 # libbz2, bzip2, bunzip2 and bzcat (stage 6)
nix build .#zip                   # zip, unzip and related utilities (stage 6)
nix build .#icu .#libxml2         # ICU 76 Unicode data/libraries; libxml2 with ICU support (stage 6)
nix build .#quickjs               # qjs, qjsc and the static JavaScript embedding library (stage 6)
nix build .#openssl098            # OpenSSL 0.9.8 under /compat/OS X/10.7 (stage 6)
nix build .#certPem               # /etc/ssl/cert.pem from security_certificates' roots (stage 6)
nix build .#bash .#zsh           # Apple shells at /bin/bash, /bin/sh and /bin/zsh
nix build .#perl                 # Apple's Perl 5.34.1 and its standard library
nix build .#ncursesTools          # clear, tput, tset/reset, infocmp, tic, toe (stage 6)
nix build .#su .#sudo            # su, sudo/sudoedit and visudo, with PAM configuration (stage 6)
nix build .#launchd .#launchdTest   # C++ init/supervisor and isolated host tests
nix build .#open .#openTest         # /usr/bin/open and its on-demand default daemon, opend
nix build .#rootfs                 # assembled tree at real paths (/usr/lib/system, etc.)
nix build .#rootfsRelease          # that tree as a release: tarball, manifest, spec, bundle
```

Direct `nix-build` also works: `nix-build -A sdk`, `nix-build -A libSystem` (`default.nix` is usable outside flakes).

Format with `nix fmt` (uses `nixpkgs-fmt`). `default.nix` and `pkgs/sdk-headers.nix` are not fmt-clean by design - format new files individually.

### Development shell

```bash
nix develop                        # CC/CXX = hermetic toolchain, $MINIDARWIN_SYSROOT set
nix develop .#cross-x86_64         # same, targeting x86_64

# Inside the shell:
$CC -isysroot $MINIDARWIN_SYSROOT hello.c -lSystem -o hello
```

`CC`, `CXX`, `MINIDARWIN_SYSROOT`, `MINIDARWIN_ARCH`, `MINIDARWIN_TRIPLE` are exported.

### Cross compilation

Nothing target-side is ever executed during a build, so either arch builds from either host:

```bash
nix build .#rootfs                 # native (host arch)
nix build .#cross.x86_64.rootfs
nix build .#cross.aarch64.rootfs
nix build .#cross.x86_64.sdkTest .#cross.x86_64.runtimesTest .#cross.x86_64.libsystemTest \
  .#cross.x86_64.libdispatchTest .#cross.x86_64.cxxLinkTest
```

`packages`/`checks` are the native target. `legacyPackages.<system>.cross.<arch>` is the full retargeted set.

### Verification

```bash
nix build .#libSystem --rebuild
nix build .#rootfs --rebuild
nix-build --check -A libsyscall   # after a full nix-build -A libsyscall
```

All files are reproducible, and can be verified 1:1 from the build workflow too.

### Installing packages

`mdpkg` installs flat `.pkg` files into a writable copy of the rootfs.
You can install software with it, like so:

```bash
nix run .#mdpkg -- inspect -pkg package.pkg
nix run .#mdpkg -- install -pkg package.pkg -target ./my-root
```

Packages with install scripts need `-script-runner`; the host build ships a
`sandbox-exec` one. See [pkgs/installer/README.md](pkgs/installer/README.md)
for what is supported, how installs are made transactional, and receipts.

QuickJS supplies `qjs`, `qjsc`, a static embedding library and headers for
future Distribution JavaScript support. The rootfs includes the package;
`mdpkg` still rejects Distribution JavaScript. See
[pkgs/quickjs/README.md](pkgs/quickjs/README.md) for build checks and embedding.

### Launchd

The rootfs includes an independent C++ launchd and launchctl for core process supervision.
See [supported job keys and lifecycle behavior](pkgs/launchd/README.md). The one
job the rootfs enables is `org.minidarwin.opend`, which launchd starts on demand
when a client connects to its socket.

### open

`/usr/bin/open` takes Apple's options and hands a request to whatever daemon
serves `/private/var/run/org.minidarwin.open.sock`, under the
[open protocol](docs/open-protocol.md). The default daemon, `/usr/libexec/opend`,
resolves items through mailcap-style handler tables and `.app` bundles' XML
`Info.plist` files as the calling user; an environment such as a compatibility
layer can disable it and serve the same socket instead. See
[pkgs/open](pkgs/open/README.md).

### CI

After the Linux verifier tests pass, GitHub Actions runs two parallel jobs on
separate ARM64 macOS VMs (`macos-15`). One builds the native aarch64 target; the
other cross-compiles x86_64 through `.#cross.x86_64.*`. Both run all build checks,
package a release, and rebuild the rootfs and release to check determinism.
Nix caches are separated by host and target architecture. Tagged releases wait
for both targets before Linux verification and publication.

## Releases and verification

Tagged releases publish `rootfsRelease` for both architectures, with a GitHub
artifact attestation for every file. Every hash in a published spec can be
reproduced with `nix build .#rootfsRelease` on the tagged commit. Releases are
meant to be consumed as a verified base system. The formats, the trust chain and
the verification rules are in [`docs/rootfs-spec.md`](docs/rootfs-spec.md).

```bash
# Check a download. Standard-library Python only, no Nix needed:
python3 scripts/mdrootfs.py verify --spec X.spec.yaml --manifest X.manifest.yaml --artifact X.tar.gz
python3 scripts/mdrootfs.py verify --bundle X.bundle.zip --spec trusted.spec.yaml
# Diff a live tree (e.g. a prefix) against the manifest -- missing / modified / wrong-type / mode:
python3 scripts/mdrootfs.py verify --manifest X.manifest.yaml --tree prefix/root --allow-extra
# Or through the flake:
nix run .#mdrootfs -- verify --bundle X.bundle.zip
```

To cut a release, bump `sequence` in [`lib/release.nix`](lib/release.nix) and
push a `v*` tag. The workflow refuses a sequence that does not exceed the last
release's.

## Limitations

Not every `Libsystem/requiredlibs` entry is buildable from released source (see [`pkgs/libsystem/absent-members.nix`](pkgs/libsystem/absent-members.nix) for reasons):

`system_m` (no arm64 in Libm-2026), `system_info`, `system_notify`, `system_darwin`, `copyfile`, `removefile` - plus closed-source `system_trace`, `xpc`, `corecrypto`, etc. Core dispatch is built and shipped; workgroup and eventlink support awaits XNU's unreleased work interval instance API.

Each member's `allowUndefined` lists exactly which symbols it expects from absent libs - no blanket `dynamic_lookup`. `rootfs` checks that every undefined import is declared and every declaration is still needed.

`systemCmds` includes Apple's `arch` and its `machine` alias with both man
pages. On ARM64, `arch -x86_64 command` accepts the Intel architecture and
submits CPU/subtype preferences to the kernel through `posix_spawn` with
`POSIX_SPAWN_SETEXEC`, as on macOS. MiniDarwin does not supply Rosetta 2;
the kernel decides whether the requested binary can run. The macOS ARM64
affinity reset is retained. Plist preferences retain their CoreFoundation
and `system_coreservices` imports, declared absent until those libraries
are built. `archTest` checks launch imports and verifies that Apple's ARM64
CPU predicate accepts Intel without executing target programs.

LibreSSL Portable 4.3.2 supplies the primary `libcrypto`/`libssl` and `openssl` tool. Curl links LibreSSL. Apple's OpenSSL 0.9.8 build remains available as `.#openssl098`, but its complete install and dylib install names live under `/compat/OS X/10.7`; primary binaries do not link it. Apple does not publish the LibreSSL source used by macOS, so MiniDarwin pins the portable upstream release.

Apple's `top` is built from `top-144`, with ncurses' `libpanel`, and installed
at `/usr/bin/top` with its man page. Its CoreFoundation and IOKit APIs use
headers from pinned Apple sources; the frameworks themselves are not built.
Their exact imports are declared absent, alongside `system_info`'s user lookup.
The full sampling and interactive code is retained. The executable is installed
as 0755, without Apple's setuid bit, which the rootfs format does not support.
`topTest` checks the target architecture, sampling/display imports and library
dependencies without executing the target.

`su` comes from `shell_cmds-329`; `sudo`, `sudoedit` and `visudo` come from
[Apple's sudo-114.100.11 source](https://github.com/apple-oss-distributions/sudo/tree/sudo-114.100.11)
(sudo 1.9.17p2). The rootfs includes their man pages, Apple's sudoers file and
PAM configurations. Both retain PAM authentication; `su` retains BSM audit
calls and optional EndpointSecurity notifications through dyld. `sudo` uses
its static sudoers policy, with Apple's library validation and SIP checks;
MDM and EndpointSecurity integration are disabled because their private
headers are not released. OpenPAM and OpenBSM headers are pinned separately;
their libraries, PAM modules, account lookup and rootless implementations
remain absent, with exact imports declared per executable. `authTest`
checks authentication, policy and execution code without running targets.

These are buildable artifacts, not working privilege escalation in the
current rootfs: dyld and the authentication services are still missing.
Executables ship as 0755 without setuid, and the release format normalizes
sudoers to 0644 rather than the 0440 expected by sudo. Ownership and these
permissions would also need provisioning before operational use; the build
does not alter permissions on the host.

`libmach_o.a`, `libdyld.dylib`, and the self-contained x86_64 `/usr/lib/dyld` now build. The standalone loader has no dynamic dependencies or unresolved symbols, and loads launchd and its jobs under the new kernel. The real XNU release kernel also builds and reaches its version banner in QEMU. `kernelBootImage` assembles a source-built EFI loader and kernel collection; the storage collection includes source-built platform, pthread, virtio-block and ext4 drivers and mounts a root partition in QEMU. `bootImage` assembles the runtime rootfs with dyld and initialized libSystem, and boots in QEMU to launchd running `uname -a` through `/bin/sh` (checked by `bootTest`); `nix run .#qemuBoot` boots the same root to an interactive shell, with Ctrl-A X to quit. See [boot development](docs/boot.md) for outputs and validation boundaries. Userland includes `bash`, `zsh`, `perl`, the `shell_cmds`, `file_cmds`, `text_cmds`, `adv_cmds`, `basic_cmds`, `patch_cmds` and `misc_cmds` tools, the basic `system_cmds` ones, `awk`, `top`, and ncurses' tools, with libedit, libncurses, libutil, libmd, LibreSSL, isolated legacy OpenSSL 0.9.8 and the terminfo database. There is no `vi`, `less`/`more` or `bc`. `wc`, `df`, `last` and `w`/`uptime` use Juniper libxo. `apply` and `w`/`uptime` link the FreeBSD-derived `libsbuf` sources in `pkgs/compat/sbuf`; `usbuf.h` is an alias for the full sbuf header. Imports from absent libraries are declared per tool, like the libsystem members' (`system_info` for user and group names, `system_m` for `awk`'s and `calendar`'s math, ...). The independent C++ `launchd` implements core supervision; Apple’s Mach bootstrap and XPC interfaces remain absent.

`fileCmds` includes `compress`/`uncompress`, `pax` (also installed as
`tar`), and `gzip`/`gunzip`/`gzcat`/`zcat` with the gzip helper scripts.
Gzip supports gzip, bzip2, compress, pack and lzip input; XZ decoding is
disabled because liblzma is not available in the tree. The `zmore`/`zless`
helpers require a pager, which is not yet included.

## Updating sources

```bash
scripts/update-sources.sh --check          # what would change
scripts/update-sources.sh xnu Libc         # update specific projects
scripts/update-sources.sh                  # update all (review diff)
```

Keep the set on one OS release of XNU. In particular `libsyscall` must match the `xnu` it came from or syscall numbers will disagree with `sys/syscall.h`.

## License and Scope Notice

MiniDarwin's MIT license applies only to the project's original build expressions, scripts, C++ implementation, and documentation. It does not apply to third-party source code, headers, libraries, executables, or other software fetched, built, packaged, or distributed by those expressions and scripts. Those components retain their respective licenses and notices, which govern their use and redistribution. The MIT license for MiniDarwin's build files does not grant rights to those components.
