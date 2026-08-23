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
nix flake check                    # sdkTest + runtimesTest + libsystemTest

# Libraries
nix build .#libsyscall             # libsystem_kernel.dylib
nix build .#libcxx                 # libc++.a (on compiler-rt + libunwind + libc++abi)
nix build .#libSystem              # umbrella libSystem.B.dylib (10 re-exported members)
nix build .#libmachO               # dyld's Mach-O reader (stage 5)
nix build .#libcxxDylib .#libcxxabiDylib
nix build .#rootfs                 # assembled tree at real paths (/usr/lib/system, etc.)
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
nix build .#cross.x86_64.sdkTest .#cross.x86_64.runtimesTest .#cross.x86_64.libsystemTest
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
| `rootfs` | 13 dylibs assembled at real paths with whole-tree checks (load commands resolve, no undeclared undefined symbols). Nothing runs yet - no `/usr/lib/dyld`. |

`sdkTest` asserts a 2-entry include path (clang builtins + sysroot). `runtimesTest` links C++ against the archives and checks 151 remaining undefs are all C. `libsystemTest` links a C program against `-lSystem` only.

## Limitations

Not every `Libsystem/requiredlibs` entry is buildable from released source. Seven are absent by design (see [`pkgs/libsystem/absent-members.nix`](pkgs/libsystem/absent-members.nix) for reasons):

`dispatch`, `system_m` (no arm64 in Libm-2026), `system_info`, `system_notify`, `system_darwin`, `copyfile`, `removefile` - plus closed-source `system_trace`, `xpc`, `corecrypto`, etc.

Each member's `allowUndefined` lists exactly which symbols it expects from absent libs - no blanket `dynamic_lookup`. `rootfs` checks that every undefined import is declared and every declaration is still needed.

No `/usr/lib/dyld` yet (`libmach_o.a` builds; dyld link not started). No userland (`shell_cmds`, `bash`, etc.). No `launchd` - last open source was 2013 and depends on unreleased `libxpc`.

## Updating sources

```bash
scripts/update-sources.sh --check          # what would change
scripts/update-sources.sh xnu Libc         # update specific projects
scripts/update-sources.sh                  # update all (review diff)
```

Keep the set on one OS release of XNU. In particular `libsyscall` must match the `xnu` it came from or syscall numbers will disagree with `sys/syscall.h`.
