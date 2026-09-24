# minidarwin

Pure, reproducible Nix bootstrap of a minimal Darwin userland from Apple's released sources, starting from a bare Clang. No Xcode, no `/Library/Developer`, no `apple-sdk` from nixpkgs. Every header and object comes from a content-addressed tarball pinned in [`lib/sources.nix`](lib/sources.nix).

## Requirements

- Nix with flakes enabled
- `aarch64-darwin` or `x86_64-darwin` (build host must be Darwin; targets cross-compile)
- macOS 26 SDK release (`xnu-12377` / `minOS = "26.0"`)

## Usage

```bash
# XNU/Darwin specific headers
nix build .#sdk
nix flake check                    # sdkTest + runtimesTest + libsystemTest + cxxLinkTest

# Libraries
nix build .#libsyscall             # libsystem_kernel.dylib
nix build .#libcxx                 # libc++.a (on compiler-rt + libunwind + libc++abi)
nix build .#libSystem              # umbrella libSystem.B.dylib (10 re-exported members)
nix build .#libmachO               # dyld's Mach-O reader (stage 5)
nix build .#libcxxDylib .#libcxxabiDylib
nix build .#sdkStage4              # sysroot where plain `-lc++` links (RTTI included)
nix build .#ncurses .#libedit     # libncurses.5.4.dylib, libedit.3.dylib (stage 6)
nix build .#terminfo               # /usr/share/terminfo (stage 6)
nix build .#shellCmds             # date, env, find, id, mktemp, test, xargs, ash, ... (stage 6)
nix build .#libutil .#fileCmds    # libutil.dylib; ls, cp, mv, rm, touch, readlink, ... (stage 6)
nix build .#libmd .#textCmds      # libmd.dylib; cat, grep, sed, sort, head, tail, md5, ... (stage 6)
nix build .#advCmds .#basicCmds    # ps, stty, tty, locale, ...; mesg, write (stage 6)
nix build .#systemCmds            # sync, sysctl, getconf, dmesg, zic, ... (stage 6)
nix build .#patchCmds .#miscCmds .#awk  # diff, cmp, patch; cal, tsort, units; awk (stage 6)
nix build .#bash .#zsh           # Apple shells at /bin/bash, /bin/sh and /bin/zsh
nix build .#ncursesTools          # clear, tput, tset/reset, infocmp, tic, toe (stage 6)
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
  .#cross.x86_64.cxxLinkTest
```

`packages`/`checks` are the native target. `legacyPackages.<system>.cross.<arch>` is the full retargeted set.

### Verification

```bash
nix build .#libSystem --rebuild
nix build .#rootfs --rebuild
nix-build --check -A libsyscall   # after a full nix-build -A libsyscall
```

All files are reproducible, and can be verified 1:1 from the build workflow too.

## What you get

| Output | Contents |
|---|---|
| `sdk` | ~1,720 headers - xnu, Libc, Libm, libpthread, libplatform, libmalloc, libdispatch, etc. - laid out like Apple's internal SDK: `usr/include` is xnu's `SPINCFRAME` rendering, and `System.framework/PrivateHeaders` holds the `SFPINCFRAME` renderings the libsystem members search first. |
| `libsyscall` | `libsystem_kernel.dylib` - 1,561 exports, 639 objects, ad-hoc signed |
| `libcxx` / `libunwind` / `libcxxabi` | LLVM runtimes as static archives (283 builtins objects + 1,677 libc++ headers) |
| `libSystem` | Umbrella `libSystem.B.dylib` re-exporting 10 members under `/usr/lib/system` |
| `libcxxDylib` / `libcxxabiDylib` | `/usr/lib/libc++.1.dylib` + `libc++abi.dylib` |
| `sdkStage4` / `toolchainStage4` | The C++-linkable sysroot: stage 3 plus those two dylibs, so `-lc++` alone resolves `___dynamic_cast` and the `__cxxabiv1` type_info vtables. What `nix develop` gives you. |
| `ncurses` / `libedit` | Stage 6: `/usr/lib/libncurses.5.4.dylib` and `/usr/lib/libedit.3.dylib` (plus their compatibility symlinks and libedit's man pages), from Apple's `ncurses` and `libedit` projects. What `ash` links for line editing. |
| `terminfo` | Stage 6: `/usr/share/terminfo`, compiled from ncurses' `terminfo.src` by a `tic` built for the build machine, as ncurses' `run_tic.sh` does. All 2,684 entries are byte-identical to macOS 26's (aliases are separate files rather than hardlinks). |
| `shellCmds` | Stage 6: every `shell_cmds` tool but `apply`, `su` and `w` -- `date`, `env`, `expr`, `find`, `id`, `kill`, `mktemp`, `printf`, `sleep`, `test`, `xargs`, ... -- at their real paths with their man pages, plus the `All` aggregate's hardlinks as symlinks (`[`, `groups`, `whoami`, `od`) and its `alias` script with the POSIX regular builtins (`cd`, `command`, `read`, `umask`, ...) linked to it. The Almquist shell is `/usr/local/bin/ash` (the `sh` target's own name and path; macOS's `/bin/sh` comes from `bash`), linked against libedit; `users` is C++. `nohup` is built without launchd's unreleased `<vproc.h>` (it does not detach from the console's bootstrap namespace). |
| `libutil` / `fileCmds` | Stage 6: `/usr/lib/libutil.dylib` (+ `libutil1.0.dylib`, man pages in `/usr/local/share/man/man3`) and every `file_cmds` tool but `df`, `ipcs`, `gzip` and `mtree`: `ls`, `cp`, `mv`, `rm`, `rmdir`, `touch`, `chmod`, `chown`, `dd`, `install`, `pax`, `stat`, ..., plus the aggregates' names as symlinks (`readlink`, `chgrp`, `link`, `unlink`, `sum`, `uncompress`) and `shar`. libutil is built without `tzlink.c` (needs `<xpc/xpc.h>`) and `wipefs.cpp`/`ExtentManager.cpp` (need IOKit headers). `cp` cannot copy a regular file's contents until copyfile is built, and `rm -P` needs removefile. |
| `libmd` / `textCmds` | Stage 6: `/usr/lib/libmd.dylib` and every `text_cmds` tool but `wc` and `jq`: `cat`, `cut`, `ed`, `grep` (+ `egrep`, `fgrep`, `zgrep`, ...), `head`, `sed`, `sort`, `tail`, `tr`, `uniq`, `md5` (+ `sha256sum`, ...), `base64`, ... `grep` is built without compressed input (liblzma was never released; zlib and bzip2 are not built). libmd's digests, and `sort -R`'s, are CommonCrypto's, whose header comes from its last release (CommonCrypto is closed source since). |
| `advCmds` / `basicCmds` | Stage 6: `ps`, `stty`, `tty`, `locale` (C++), `tabs`, `finger`, `whois`, `gencat`, `lsvfs`, `cap_mkdb`; `mesg`, `write`. `ps` and `write` are installed without their set-id bits, which the rootfs format cannot express. |
| `systemCmds` | Stage 6: the `system_cmds` tools a plain userland has: `sync`, `sysctl`, `getconf`, `dmesg`, `hostinfo`, `vm_stat`, `mkfile`, `nologin`, `wait4path`, `zdump`, `zic`, `ac`, `accton`, `sa`, `pwd_mkdb`. |
| `patchCmds` / `miscCmds` / `awk` | Stage 6: `cmp`, `diff`, `diff3`, `diffstat`, `patch`, `sdiff`; `cal`, `ncal`, `calendar`, `tsort`, `units`; the one true `awk`. |
| `bash` / `zsh` | Apple's Bash 3.2 at `/bin/bash` (also `/bin/sh`) and Zsh 5.9 at `/bin/zsh`, with their man pages and startup files. Zsh's modules are linked into its executable for the minimal rootfs. |
| `ncursesTools` | Stage 6: ncurses' own executables -- `clear`, `tput`, `tset` (+ `reset`), `infocmp`, `tic` (+ `captoinfo`, `infotocap`), `toe` -- linked against libncurses. |
| `rootfs` | The assembled tree at real paths with whole-tree checks (load commands resolve, no undeclared undefined symbols). Nothing runs yet - no `/usr/lib/dyld`. |
| `rootfsRelease` | `rootfs` packed for distribution: a reproducible `.tar.gz`, a `manifest.yaml` (type, mode and SHA-256 of every path, plus a Merkle tree digest), a `spec.yaml` pinning both, and a `.bundle.zip` of all three. |

`sdkTest` asserts the include path is exactly clang's builtins, the sysroot's `usr/include` and its `System/Library/Frameworks`, that strict-POSIX code compiles against `usr/include`, and that `System.framework/PrivateHeaders` (and only it) gives the libsystem members xnu's private declarations. `runtimesTest` links C++ against the archives and checks 151 remaining undefs are all C. `libsystemTest` links a C program against `-lSystem` only. `cxxLinkTest` links a C++ program that downcasts, cross-casts through a virtual base, uses `typeid` and throws, against nothing but `-lc++`.

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

Not every `Libsystem/requiredlibs` entry is buildable from released source. Seven are absent by design (see [`pkgs/libsystem/absent-members.nix`](pkgs/libsystem/absent-members.nix) for reasons):

`dispatch`, `system_m` (no arm64 in Libm-2026), `system_info`, `system_notify`, `system_darwin`, `copyfile`, `removefile` - plus closed-source `system_trace`, `xpc`, `corecrypto`, etc.

Each member's `allowUndefined` lists exactly which symbols it expects from absent libs - no blanket `dynamic_lookup`. `rootfs` checks that every undefined import is declared and every declaration is still needed.

No `/usr/lib/dyld` yet (`libmach_o.a` builds; dyld link not started). Userland includes `bash`, `zsh`, the `shell_cmds`, `file_cmds`, `text_cmds`, `adv_cmds`, `basic_cmds`, `patch_cmds` and `misc_cmds` tools, the basic `system_cmds` ones, `awk`, and ncurses' tools, with libedit, libncurses, libutil, libmd and the terminfo database. There is no `vi`, `less`/`more`, `bc` or `file`, which are projects of their own. `wc`, `df`, `last`, `w`/`uptime` and `apply` are written against libxo or libsbuf, which Apple has not released. Imports from absent libraries are declared per tool, like the libsystem members' (`system_info` for user and group names, `system_m` for `awk`'s and `calendar`'s math, ...). No `launchd` - last open source was 2013 and depends on unreleased `libxpc`.

## Updating sources

```bash
scripts/update-sources.sh --check          # what would change
scripts/update-sources.sh xnu Libc         # update specific projects
scripts/update-sources.sh                  # update all (review diff)
```

Keep the set on one OS release of XNU. In particular `libsyscall` must match the `xnu` it came from or syscall numbers will disagree with `sys/syscall.h`.

## License and Scope Notice

MiniDarwin's MIT license applies only to the project's original build expressions, scripts, and documentation. It does not apply to third-party source code, headers, libraries, executables, or other software fetched, built, packaged, or distributed by those expressions and scripts. Those components retain their respective licenses and notices, which govern their use and redistribution. The MIT license for MiniDarwin's build files does not grant rights to those components.
