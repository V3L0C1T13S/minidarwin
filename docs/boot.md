# Boot development

MiniDarwin targets x86_64 QEMU first. The Apple source set remains pinned at
XNU 12377.121.6 and dyld 1378. The standalone dyld executable and real XNU release kernel build from source.
The assembled disk boots XNU, mounts its ext4 root partition, and runs
`/sbin/launchd` through `/usr/lib/dyld`. launchd's boot job runs `uname -a`
through `/bin/sh`, and `bootTest` checks that in QEMU. There is no login shell
or console session yet.

## Outputs

| Output | Contents |
| --- | --- |
| `libdyld` | `/usr/lib/system/libdyld.dylib`, the public dyld API and TLS helpers |
| `cross.x86_64.dyld` | Self-contained `/usr/lib/dyld` executable, with no dynamic dependencies |
| `cross.x86_64.dyldObjects` | Compiled standalone dyld sources in `dyld.a`; requires its static runtime and final link |
| `xnuClang` | LLVM 21 frontend with MiniDarwin's XNU allocation layout builtins |
| `kernel` / `cross.x86_64.kernel` | Linked XNU release kernel, with no unresolved symbols |
| `kernelCollection` | Kernel-only `MH_FILESET` collection |
| `storageKernelCollection` | Kernel plus pthread, ACPI, APIC, PCI, virtio-block, and ext4 extensions |
| `bootRootfs` | Runtime tree with standalone dyld and initialized libSystem |
| `bootRootPartition` | Source-built ext4 filesystem containing the runtime tree |
| `bootImage` | GPT disk with EFI loader, storage collection, and ext4 root partition |
| `qemuBoot` | QEMU runner that boots the assembled disk (`shellBootImage`) to an interactive `/bin/sh` on this terminal; Ctrl-A X quits |
| `rootMountTest` | Mounts a fixture, then checks the expected missing PID 1 failure |
| `bootTest` | Boots `bootImage` to launchd running `uname -a` through `/bin/sh` |
| `kernelBootImage` | GPT/FAT disk containing the EFI loader and kernel collection |
| `qemuKernel` | QEMU runner using `kernelBootImage` |
| `kernelStartupTest` | QEMU crypto initialization and refusal to boot without firmware entropy |
| `efiLoader` | Source-built PureDarwin XNU EFI loader at `EFI/BOOT/BOOTX64.EFI` |
| `efiBootImage` | GPT raw disk with a FAT32 EFI System Partition and the loader |
| `bootDiskTest` | Disk integrity, payload, repeatability, and QEMU firmware-to-loader checks |
| `qemuEfi` | QEMU TCG runner with bundled firmware and temporary writable variables |

`libdyld` is a library, not `/usr/lib/dyld`. The latter must be a self-contained
`MH_DYLINKER` executable with no `LC_LOAD_DYLIB` dependencies: it runs before
libSystem is available. The executable build checks this contract, its entry point, code signature,
and absence of undefined symbols. Its generated prebuilt-loader version hashes the target
compiler's record layouts, without invoking Xcode or discovering a host SDK.

## Build and run

```sh
nix build .#libdyld .#cross.x86_64.libdyld
nix build .#cross.x86_64.dyld
nix build .#efiBootImage .#bootDiskTest
nix run .#qemuEfi
nix build .#kernel .#kernelBootImage
nix run .#qemuKernel
nix build .#bootImage
nix run .#qemuBoot   # drops you into a shell; Ctrl-A X quits QEMU
nix build .#checks.aarch64-darwin.bootTest   # or x86_64-darwin
# Or supply another assembled image:
nix run .#qemuEfi -- /absolute/path/to/disk.img
```

The default image contains only the loader. It boots into the loader and reports
a missing kernel. The check supplies an intentionally malformed kernel, observes
the loader reading its exact contents and rejecting its Mach-O format, then
stops QEMU. This verifies the firmware and FAT loading path, not an XNU boot.
The runner selects an Intel Haswell CPUID model and stepping accepted by XNU.
It supplies an EFI RNG through virtio-rng backed by the host random device;
the loader refuses to hand off a kernel when EFI RNG is unavailable.
Its TCG clock support reads the EFI loader’s calibrated `TSCFrequency`, avoiding
physical Intel ratio MSRs that TCG does not supply.
The runner uses software emulation on either supported Darwin host and does not
change the supplied disk image.

## Assembly interface

The scope exposes `mkBootDisk` as a factory:

```nix
scope.mkBootDisk {
  kernel = "${kernelPackage}/System/Library/Kernels/kernel";
  rootPartition = "${bootRootPartition}/root.ext4";
  bootArgs = "-v serial=3 keepsyms=1";
}
```

The payload arguments name files. `rootPartition` is installed as the second
GPT partition, aligned to 1 MiB. It must be a filesystem supported by the
kernel and its drivers. A rootfs directory or release tarball does not become
a mountable filesystem merely by copying it into the disk. The assembler puts
the kernel and boot arguments under `EFI/BOOT`, and an optional ramdisk at the
partition root. It fixes FAT timestamps and serial numbers, derives GPT GUIDs
from the partition contents, writes both GPT headers and tables, and checks
their CRCs in `bootDiskTest`.

The pinned loader currently disables its ramdisk loading and device-tree
handoff code. Optional ramdisk payloads are stored in the partition but are
not handed to XNU yet. Enabling and validating that path remains required
for ramdisk boot. The current disk instead boots from its virtio-block ext4
partition, which needs no ramdisk handoff.

## Remaining work

XNU's allocation builtins classify eight-byte granules as pointers, data,
overlap, or dual-use values. MiniDarwin implements the frontend support rather
than replacing allocation signatures with empty strings. Tests cover C and C++
layouts, field and typedef annotations, packed records, unions, arrays, and
template instantiation. This implementation is restricted to x86_64; it does
not implement ARM pointer authentication semantics.

The public XNU drop omits TrustCache headers and requires AMFI and Image4
interfaces during startup. `pkgs/xnu/support/TrustCache/API.h` describes
MiniDarwin's source-level contract, based on Apple's previously published
types. It is not binary compatibility for an Apple AMFI kext. The module parser
and query implementation reject malformed or unsorted entries, duplicate UUIDs,
and disallowed cache types; `trustCacheTest` checks these paths. The x86_64 kernel uses this static trust-cache runtime directly, retaining
XNU locking and raw-module validation. Signed Image4 loads always return
unsupported; no manifest is promoted to a trusted module. Entitlement queries
denied by the absent AMFI provider grant no privileges. Image4 authentication
and Apple AMFI compatibility remain unimplemented.
The final kernel links pinned libdispatch firehose code, LLVM compiler runtime
profiling sources, and the TrustCache implementation. Kernel C++ destructors
remain in `__mod_term_func`; they do not use a libc exit registry. Additional cipher and public-key providers still need implementation. The
platform and storage extensions build from the pinned PureDarwin sources; the
pthread kernel extension uses the pinned Apple libpthread sources. Their
imports and all 15,554 pointer/call relocations are checked independently.

Standalone dyld links static Libc, platform, pthread and syscall variants,
LLVM’s string and hash implementation, its own allocator bridge, and LibreSSL
digests. Known-answer tests exercise SHA-1, SHA-256 and SHA-384 through the loader
interface, including split updates and context clearing. Its policy query grants
no optional loader privileges. XNU executes the loader for launchd and its jobs, and libSystem initializes
in each process.
The Apple Sandbox MAC policy is absent from the open XNU drop; the object build
explicitly excludes those private preflight calls. Filesystem access remains
subject to the kernel's permission checks. The public library omits the Apple
launchd ownership protocol, which MiniDarwin's independent supervisor does not
implement. Neither output establishes Apple Sandbox or AMFI compatibility.

The real-kernel QEMU trace reaches the Darwin 25.5.0 banner, VM and scheduler
initialization, registered crypto providers, ACPI/PCI matching, virtio-block
partition discovery, devfs nodes, and successful mounting of `disk0s2`. The
root-mount fixture deliberately contains no launchd; its check requires the
mount marker followed by PID 1's expected ENOENT at `/sbin/launchd`. This proves
storage and filesystem startup without claiming userland execution.

`bootImage` contains the full runtime tree and a launchd boot job that runs
`/usr/bin/uname -a` through `/bin/sh`, then prints a completion marker only when
that command succeeds. This marker is the userland acceptance boundary. The
libSystem initializer calls the source-built kernel, platform, pthread, libc,
malloc, dyld and dispatch initializers and installs their fork callbacks. A narrow CoreCrypto interface supplies the
six digest and RNG APIs imported by malloc and libc, using LibreSSL digests and
XNU getentropy. It does not implement other Apple CoreCrypto interfaces.

dyld binds every import at launch, so each `-Wl,-U` hole in launchd's load
closure (launchd links libxml2 and ICU) must be defined in the runtime tree or
launchd exits with "symbol not found in flat namespace". The runtime tree
therefore adds, beyond the stage 4 members:

- `libsystem_info` (`runtimeInfo`): Libinfo's `Libinfo` target from its
  generated source list, with the file, search and cache backends, NIS client
  and Sun RPC. DirectoryService, DarwinDirectory and mDNS are compiled out
  (their defines are closed-source services); `od_debug.c`,
  `configuration_profile.c`, `mdns_module.c` and `res_query.c` are not
  compiled. `<rpcsvc/yp.h>` comes from Librpcsvc's `yp.x` through host
  `rpcgen`. os_log diagnostics compile to nothing.
- `libsystem_m` (`libsystemM`): Libm-2026's x86_64 halves, `Libm.a` and
  `libmathCommon.o`, each `ld -r`'d with Apple's exports and alias lists, plus
  `__exp10` and `__sincos_stret`, which compilers emit for newer targets.
- `libsystem_notify` (`runtimeNotify`): the notify API reporting no notifyd.
  libnotify's client needs xpc and bootstrap. Libc and Libinfo then
  revalidate on each use.
- `libsystem_asl` (`runtimeAsl`): only BSD syslog, from Libc's
  `gen/oldsyslog.c`. ASL and utmpx stay absent and declared.

`bootRootfs` lists the providers it resolves (`resolvedAbsences`, or
`resolvedSymbols` for system_asl's syslog half). Its whole-tree check fails if
any of them is not actually defined.
LLVM's Apple ABI allocation shims supply the typed weak definitions expected
by this dyld release.

A raw `MH_EXECUTE` kernel cannot initialize this release's collection allocation
metadata. The disk uses `MH_FILESET`, assembled by pinned `kc-tools`, with the
required source-built extensions. Collection conversion removes the obsolete
raw-kernel ad-hoc signature command; the collection is explicitly unsigned.

`kernelCryptoTest` checks SHA-1/256/384/512, HMAC, the XNU digest/HMAC function-table
callbacks, and HMAC_DRBG against Python's standard crypto implementation and
64 published NIST known-answer groups. Eight vectors also exercise the kmem RNG
handle, including invalid-input and unbiased bounded-output checks. The running
kernel registers these modules before early-boot allocation randomization.
The global PRNG serializes CPU requests and consumes XNU's health-tested entropy
callback outside its spinlock; allocation contexts acquire no locks and use no
FP registers. Missing entropy and DRBG errors fail closed. AES-128/192/256 ECB and CBC use the pinned LibreSSL software core and pass
FIPS-197 and NIST SP 800-38A known-answer vectors, including in-place and split
CBC operation. This lookup-table AES backend is not constant-time. Other cipher
modes and RSA remain unimplemented in this provider.

`bootTest` is the complete boot check. XNU mounts the assembled root
filesystem and executes `/sbin/launchd` through `/usr/lib/dyld`. libSystem
initializes, and the boot job's `/bin/sh` runs `/usr/bin/uname -a` to the
console, followed by the completion marker. The check fails on a panic, a
missing symbol, or any diagnostic from launchd. As PID 1, launchd has its stdio
on `/dev/console`, and jobs may name `/dev/console` for their output. It takes
about two minutes under TCG.

## Provenance

`lib/sources.nix` pins the PureDarwin loader, kernel collection assembler, and IIG tool, plus GNU-EFI. The
loader and IIG have their own BSD licenses; GNU-EFI carries its own licenses,
copied into the loader output. Apple source licenses remain separate from
MiniDarwin's MIT license. Target artifacts use the source-built SDK and open
LLVM tools. Host-only build generators use nixpkgs' pinned build environment.
