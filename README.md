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
| `sdk` | ~1,720 headers - xnu, Libc, Libm, libpthread, libplatform, libmalloc, libdispatch, etc. |
| `libsyscall` | `libsystem_kernel.dylib` - 1,561 exports, 639 objects, ad-hoc signed |
| `libcxx` / `libunwind` / `libcxxabi` | LLVM runtimes as static archives (283 builtins objects + 1,677 libc++ headers) |
| `libSystem` | Umbrella `libSystem.B.dylib` re-exporting 10 members under `/usr/lib/system` |
| `libcxxDylib` / `libcxxabiDylib` | `/usr/lib/libc++.1.dylib` + `libc++abi.dylib` |
| `sdkStage4` / `toolchainStage4` | The C++-linkable sysroot: stage 3 plus those two dylibs, so `-lc++` alone resolves `___dynamic_cast` and the `__cxxabiv1` type_info vtables. What `nix develop` gives you. |
| `shellCmds` | Stage 6: `/bin/echo`, `/bin/pwd`, `/usr/bin/uname`, `/usr/bin/who` from `shell_cmds`, plus their man pages. Linked against `libSystem` only. `who` imports five utmpx functions that `libsystem_c` cannot provide yet (`utmpx-darwin.c` needs ASL) and `getpwuid` (`system_info`), both declared. |
| `rootfs` | 13 dylibs and 4 executables assembled at real paths with whole-tree checks (load commands resolve, no undeclared undefined symbols). Nothing runs yet - no `/usr/lib/dyld`. |
| `rootfsRelease` | `rootfs` packed for distribution: a reproducible `.tar.gz`, a `manifest.yaml` (type, mode and SHA-256 of every path, plus a Merkle tree digest), a `spec.yaml` pinning both, and a `.bundle.zip` of all three. |

`sdkTest` asserts a 2-entry include path (clang builtins + sysroot). `runtimesTest` links C++ against the archives and checks 151 remaining undefs are all C. `libsystemTest` links a C program against `-lSystem` only. `cxxLinkTest` links a C++ program that downcasts, cross-casts through a virtual base, uses `typeid` and throws, against nothing but `-lc++`.

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

No `/usr/lib/dyld` yet (`libmach_o.a` builds; dyld link not started). Userland is four `shell_cmds` tools (`echo`, `pwd`, `uname`, `who`); no shell, no `bash`. No `launchd` - last open source was 2013 and depends on unreleased `libxpc`.

## Updating sources

```bash
scripts/update-sources.sh --check          # what would change
scripts/update-sources.sh xnu Libc         # update specific projects
scripts/update-sources.sh                  # update all (review diff)
```

Keep the set on one OS release of XNU. In particular `libsyscall` must match the `xnu` it came from or syscall numbers will disagree with `sys/syscall.h`.
