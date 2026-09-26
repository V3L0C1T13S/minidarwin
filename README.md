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
nix build .#curl                  # /usr/bin/curl and static libcurl (stage 6)
nix build .#openssl098            # libcrypto/libssl 0.9.8 and Apple's openssl tool (stage 6)
nix build .#bash .#zsh           # Apple shells at /bin/bash, /bin/sh and /bin/zsh
nix build .#perl                 # Apple's Perl 5.34.1 and its standard library
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

No `/usr/lib/dyld` yet (`libmach_o.a` builds; dyld link not started). Userland includes `bash`, `zsh`, `perl`, the `shell_cmds`, `file_cmds`, `text_cmds`, `adv_cmds`, `basic_cmds`, `patch_cmds` and `misc_cmds` tools, the basic `system_cmds` ones, `awk`, and ncurses' tools, with libedit, libncurses, libutil, libmd, the legacy OpenSSL 0.9.8 libraries and the terminfo database. There is no `vi`, `less`/`more` or `bc`. `wc`, `df`, `last`, `w`/`uptime` and `apply` are written against libxo or libsbuf, which Apple has not released. Imports from absent libraries are declared per tool, like the libsystem members' (`system_info` for user and group names, `system_m` for `awk`'s and `calendar`'s math, ...). No `launchd` - last open source was 2013 and depends on unreleased `libxpc`.

## Updating sources

```bash
scripts/update-sources.sh --check          # what would change
scripts/update-sources.sh xnu Libc         # update specific projects
scripts/update-sources.sh                  # update all (review diff)
```

Keep the set on one OS release of XNU. In particular `libsyscall` must match the `xnu` it came from or syscall numbers will disagree with `sys/syscall.h`.

## License and Scope Notice

MiniDarwin's MIT license applies only to the project's original build expressions, scripts, and documentation. It does not apply to third-party source code, headers, libraries, executables, or other software fetched, built, packaged, or distributed by those expressions and scripts. Those components retain their respective licenses and notices, which govern their use and redistribution. The MIT license for MiniDarwin's build files does not grant rights to those components.
