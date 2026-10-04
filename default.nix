# minidarwin - pure Nix bootstrap of Darwin rootfs from Apple sources.
{ pkgs
, targetArch ? (if pkgs.stdenv.hostPlatform.isAarch64 then "aarch64" else "x86_64")
  # Deployment target. Must match the source release pinned in lib/sources.nix.
, minOS ? "26.0"
}:

let
  inherit (pkgs) lib;


  # Entire prebuilt input to target world: clang, lld, binutils.
  llvmPackages = pkgs.llvmPackages_21;
in

# Cross builds work because target artifacts are never executed.
assert lib.assertMsg (targetArch == "aarch64" || targetArch == "x86_64")
  "minidarwin: targetArch must be \"aarch64\" or \"x86_64\", got \"${targetArch}\"";

lib.makeScope pkgs.newScope (self: with self; {

  #### inputs #################################################################

  inherit llvmPackages targetArch minOS;

  sources = import ./lib/sources.nix { inherit (pkgs) fetchFromGitHub fetchurl; };

  buildSupport = ./lib/build-support.sh;

  # The unwrapped compiler we start from -- no cc-wrapper, no SDK.
  bootstrapClang = llvmPackages.clang-unwrapped;

  # Same revision as bootstrapClang - builtins/headers versioned against compiler.
  llvmSource = llvmPackages.llvm.monorepoSrc;
  llvmVersion = llvmPackages.llvm.version;

  mkToolchain = callPackage ./lib/toolchain.nix { };

  mkDarwinPackage = callPackage ./lib/mk-darwin-package.nix { };

  #### stage 0: host tools ####################################################

  mig = callPackage ./pkgs/mig.nix { };

  #### stage 1: the SDK #######################################################

  sdkHeaders = callPackage ./pkgs/sdk-headers.nix { };

  # Sysroot-relative System.framework/PrivateHeaders (xnu's SFPINCFRAME): what
  # the libsystem members' xcconfigs put first in SYSTEM_HEADER_SEARCH_PATHS.
  systemFrameworkHeaders = sdkHeaders.systemFrameworkHeaders;

  # Has headers but no libraries - links are -nostdlib.
  toolchainStage1 = mkToolchain {
    name = "minidarwin-toolchain-stage1";
    sysroot = sdkHeaders;
    freestanding = true;
  };

  sdkTest = callPackage ./pkgs/sdk-test.nix { toolchain = toolchainStage1; };

  #### stage 2: the kernel interface ##########################################

  libsyscall = callPackage ./pkgs/libsystem/libsyscall.nix {
    toolchain = toolchainStage1;
  };

  #### stage 3: the LLVM runtimes ##############################################

  compilerRtBuiltins = callPackage ./pkgs/llvm-runtimes/compiler-rt-builtins.nix {
    toolchain = toolchainStage1;
  };

  # Same builtins with default visibility for dylib.
  compilerRtBuiltinsVisible = callPackage ./pkgs/llvm-runtimes/compiler-rt-builtins.nix {
    toolchain = toolchainStage1;
    hiddenVisibility = false;
  };

  libunwind = callPackage ./pkgs/llvm-runtimes/libunwind.nix {
    toolchain = toolchainStage1;
  };

  libcxxHeaders = callPackage ./pkgs/llvm-runtimes/libcxx-headers.nix {
    toolchain = toolchainStage1;
  };

  libcxxabi = callPackage ./pkgs/llvm-runtimes/libcxxabi.nix {
    toolchain = toolchainStage1;
  };

  libcxx = callPackage ./pkgs/llvm-runtimes/libcxx.nix {
    toolchain = toolchainStage1;
  };

  clangResourceDir = callPackage ./pkgs/llvm-runtimes/resource-dir.nix { };
  sdkStage2 = callPackage ./pkgs/sdk-stage2.nix { };

  # Stage 2: our builtins/libc++ - still freestanding (no libSystem yet).
  toolchainStage2 = mkToolchain {
    name = "minidarwin-toolchain-stage2";
    sysroot = sdkStage2;
    resourceDir = clangResourceDir;
    freestanding = true;
  };

  runtimesTest = callPackage ./pkgs/llvm-runtimes/runtimes-test.nix {
    toolchain = toolchainStage2;
  };

  #### stage 4: libSystem #####################################################

  # Two-pass link to break libsystem cycle (see umbrella-link.nix).
  umbrellaLink = callPackage ./pkgs/libsystem/umbrella-link.nix { };

  # null → pass 1 (-undefined dynamic_lookup); tree → pass 2 (-undefined error).
  mkLibsystem = libsystemStage1:
    let
      component = path: args: callPackage path ({
        toolchain = toolchainStage2;
        inherit libsystemStage1;
      } // args);
    in
    {
      compilerRtDylib = component ./pkgs/libsystem/runtime-dylib.nix {
        name = "compiler_rt";
        runtime = compilerRtBuiltinsVisible;
        archive = "lib/darwin/libclang_rt.osx.a";
        libs = [
          "system_kernel" "system_platform" "system_pthread" "system_malloc"
          "system_c" "unwind" "dyld" "dispatch"
        ];
        # Representative symbols per family (128-bit, half-float, atomics, etc.).
        symbols = [
          "___divti3" "___udivti3" "___fixdfti" "___floatuntidf"
          "___gnu_f2h_ieee" "___truncdfhf2"
          "___atomic_load_8" "___atomic_store_8" "___atomic_compare_exchange_8"
          "___gcc_personality_v0" "___clear_cache"
        ] ++ lib.optional (targetArch == "aarch64") "__aarch64_ldadd8_acq_rel"
        ++ lib.optional (targetArch != "aarch64") "___floatundixf";
        # dyld (stage 5) holes; x86_64 adds system_m long-double.
        allowUndefined = {
          "_dlsym" = "dyld";
          # LLVM weak-imports this optional API and has its own fallback.
          # The public dyld release does not export it.
          "__availability_version_check" = "availability runtime";
        } // lib.optionalAttrs (targetArch != "aarch64") {
          "_scalbnl" = "system_m";
          "_logbl" = "system_m";
          "_fmaxl" = "system_m";
        };
      };
      unwindDylib = component ./pkgs/libsystem/runtime-dylib.nix {
        name = "unwind";
        runtime = libunwind;
        archive = "usr/lib/libunwind.a";
        libs = [ "system_kernel" "system_platform" "system_pthread" "system_malloc" "system_c" "dyld" ];
        # dyld holes (unwind sections, image removal, dladdr).
        allowUndefined = {
          "__dyld_find_unwind_sections" = "dyld";
          "__dyld_register_func_for_remove_image" = "dyld";
          "_dladdr" = "dyld";
        };
        symbols = [
          "__Unwind_RaiseException" "__Unwind_Resume" "__Unwind_DeleteException"
          "__Unwind_GetIP" "__Unwind_SetIP" "__Unwind_GetLanguageSpecificData"
          "__Unwind_Backtrace"
        ];
      };
      libsystemBlocks = component ./pkgs/libsystem/libsystem-blocks.nix { };
      libsystemCollections = component ./pkgs/libsystem/libsystem-collections.nix { };
      libsystemC = component ./pkgs/libsystem/libsystem-c.nix { };
      libsystemPlatform = component ./pkgs/libsystem/libsystem-platform.nix { };
      libsystemPthread = component ./pkgs/libsystem/libsystem-pthread.nix { };
      libmacho = component ./pkgs/libsystem/libmacho.nix { };
      libsystemMalloc = component ./pkgs/libsystem/libsystem-malloc.nix { };
    };

  # Pass 1: -undefined dynamic_lookup, no siblings (exports final).
  libsystemPass1 = mkLibsystem null;

  # Build dispatch against the pass-1 members before the second pass links.
  libdispatch = callPackage ./pkgs/libdispatch/libdispatch.nix {
    toolchain = toolchainStage2;
  };

  # Pass-1 members merged for pass 2's -L. Some requiredlibs still absent (see absent-members.nix).
  libsystemTree1 = callPackage ./pkgs/libsystem/libsystem-tree.nix {
    name = "minidarwin-libsystem-pass1";
    members = with libsystemPass1; [
      compilerRtDylib
      unwindDylib
      libmacho
      libsystemBlocks
      libsystemC
      libsystemCollections
      libsystemPlatform
      libsystemPthread
      libsystemMalloc
    ] ++ [ libsyscall libdispatch ];
  };

  # Pass 2: relink against pass-1 tree with exact -lsystem_* deps, -undefined error.
  libsystemPass2 = mkLibsystem libsystemTree1;

  libsystemTree2 = callPackage ./pkgs/libsystem/libsystem-tree.nix {
    name = "minidarwin-libsystem-pass2";
    members = with libsystemPass2; [
      compilerRtDylib
      unwindDylib
      libmacho
      libsystemBlocks
      libsystemC
      libsystemCollections
      libsystemPlatform
      libsystemPthread
      libsystemMalloc
    ] ++ [ libsyscall libdispatch ];
  };

  # Umbrella: /usr/lib/libSystem.B.dylib re-exporting every pass-2 member.
  libSystem = callPackage ./pkgs/libsystem/libsystem-umbrella.nix {
    toolchain = toolchainStage2;
    members = libsystemTree2;
  };

  # First sysroot with libraries - links without -nostdlib.
  sdkStage3 = callPackage ./pkgs/sdk-stage3.nix { };

  # First non-freestanding toolchain: ordinary -lSystem links.
  toolchainStage3 = mkToolchain {
    name = "minidarwin-toolchain-stage3";
    sysroot = sdkStage3;
    resourceDir = clangResourceDir;
  };

  libsystemTest = callPackage ./pkgs/libsystem/libsystem-test.nix {
    toolchain = toolchainStage3;
  };
  libdispatchTest = callPackage ./pkgs/libdispatch/libdispatch-test.nix {
    toolchain = toolchainStage3;
  };

  # Top-level C++ dylibs (need libSystem for malloc/pthread).
  libcxxabiDylib = callPackage ./pkgs/llvm-runtimes/libcxxabi-dylib.nix {
    toolchain = toolchainStage3;
  };

  libcxxDylib = callPackage ./pkgs/llvm-runtimes/libcxx-dylib.nix {
    toolchain = toolchainStage3;
  };

  # copyfile(3) and removefile(3), used by file_cmds and shipped in the SDK.
  copyfile = callPackage ./pkgs/copyfile.nix {
    toolchain = toolchainStage3;
  };
  removefile = callPackage ./pkgs/removefile.nix {
    toolchain = toolchainStage3;
  };

  # First sysroot that links C++: -lc++ resolves libc++.dylib, whose reexport of
  # libc++abi.dylib supplies ___dynamic_cast and the __cxxabiv1 vtables.
  sdkStage4 = callPackage ./pkgs/sdk-stage4.nix { };

  toolchainStage4 = mkToolchain {
    name = "minidarwin-toolchain-stage4";
    sysroot = sdkStage4;
    resourceDir = clangResourceDir;
  };

  cxxLinkTest = callPackage ./pkgs/llvm-runtimes/cxx-link-test.nix {
    toolchain = toolchainStage4;
  };

  #### stage 6: userland ######################################################

  # Host tool output: the sources the `sh` target generates before compiling.
  shGenerated = callPackage ./pkgs/shell-cmds/sh-generated.nix { };

  # libncurses.5.4.dylib and libedit.3.dylib: what sh links for line editing.
  ncursesGenerated = callPackage ./pkgs/ncurses/ncurses-generated.nix { };
  ncursesTic = callPackage ./pkgs/ncurses/tic.nix { };
  terminfo = callPackage ./pkgs/ncurses/terminfo.nix { };
  # /etc/ssl/cert.pem, from the macOS root store (curl's CA bundle).
  certPem = callPackage ./pkgs/security-certificates/cert-pem.nix { };
  # clear, tput, tset, ... (ncurses.xcodeproj's executables).
  ncursesTools = callPackage ./pkgs/ncurses/ncurses-tools.nix {
    toolchain = toolchainStage3;
  };
  ncurses = callPackage ./pkgs/ncurses/ncurses.nix {
    toolchain = toolchainStage3;
  };
  ncursesPanel = callPackage ./pkgs/ncurses/panel.nix {
    toolchain = toolchainStage3;
  };
  top = callPackage ./pkgs/top/top.nix {
    toolchain = toolchainStage3;
  };
  topTest = callPackage ./pkgs/top/top-test.nix { };
  libedit = callPackage ./pkgs/libedit/libedit.nix {
    toolchain = toolchainStage3;
  };

  # libutil.dylib: what ls links for humanize_number.
  libutil = callPackage ./pkgs/libutil/libutil.nix {
    toolchain = toolchainStage3;
  };

  libsbuf = callPackage ./pkgs/compat/sbuf/libsbuf.nix {
    toolchain = toolchainStage3;
  };

  # libmd.dylib: what md5 and install link for their digests; and the
  # CommonCrypto header its own headers (and sort) include.
  commonCryptoHeaders = callPackage ./pkgs/libmd/commoncrypto-headers.nix { };
  libmd = callPackage ./pkgs/libmd/libmd.nix {
    toolchain = toolchainStage3;
  };

  # The *_cmds projects' tools, built per target (pkgs/cmds/mk-cmds.nix).
  mkCmds = callPackage ./pkgs/cmds/mk-cmds.nix { };

  # The shell_cmds tools -- the first executables, C-only against libSystem.
  shellCmds = callPackage ./pkgs/shell-cmds/shell-cmds.nix {
    toolchain = toolchainStage4; # users is C++
  };

  # The file_cmds tools: ls, cp, rm, touch, ...
  fileCmds = callPackage ./pkgs/file-cmds/file-cmds.nix {
    toolchain = toolchainStage3;
  };

  # The text_cmds tools: cat, grep, sed, sort, ...
  textCmds = callPackage ./pkgs/text-cmds/text-cmds.nix {
    toolchain = toolchainStage3;
  };

  # The adv_cmds tools: ps, stty, tty, locale, ...
  advCmds = callPackage ./pkgs/adv-cmds/adv-cmds.nix {
    toolchain = toolchainStage4; # locale is C++
  };

  # The basic_cmds tools: mesg, write.
  basicCmds = callPackage ./pkgs/basic-cmds/basic-cmds.nix {
    toolchain = toolchainStage3;
  };

  # The system_cmds tools a plain userland has: arch, sync, sysctl, getconf, ...
  systemCmds = callPackage ./pkgs/system-cmds/system-cmds.nix {
    toolchain = toolchainStage3;
  };
  archTest = callPackage ./pkgs/system-cmds/arch-test.nix { };

  # cmp, diff, diff3, diffstat, patch, sdiff.
  patchCmds = callPackage ./pkgs/patch-cmds/patch-cmds.nix {
    toolchain = toolchainStage3;
  };

  # cal/ncal, calendar, tsort, units.
  miscCmds = callPackage ./pkgs/misc-cmds/misc-cmds.nix {
    toolchain = toolchainStage3;
  };

  # /usr/bin/awk.
  awk = callPackage ./pkgs/awk/awk.nix {
    toolchain = toolchainStage3;
  };

  # Apple's file(1), including its magic rules.
  file = callPackage ./pkgs/file/file.nix {
    toolchain = toolchainStage3;
  };

  curl = callPackage ./pkgs/curl/curl.nix {
    toolchain = toolchainStage3;
  };

  zlib = callPackage ./pkgs/zlib/zlib.nix {
    toolchain = toolchainStage3;
  };

  bzip2 = callPackage ./pkgs/bzip2/bzip2.nix {
    toolchain = toolchainStage3;
    inherit copyfile;
  };

  zip = callPackage ./pkgs/zip/zip.nix {
    toolchain = toolchainStage3;
  };

  libxml2 = callPackage ./pkgs/libxml2/libxml2.nix {
    toolchain = toolchainStage4;
    inherit icu;
  };

  icuBuildRoot = callPackage ./pkgs/icu/build-root.nix { };
  icu = callPackage ./pkgs/icu/icu.nix {
    toolchain = toolchainStage4;
    inherit icuBuildRoot;
  };
  libxml2Test = callPackage ./pkgs/libxml2/libxml2-test.nix {
    toolchain = toolchainStage3;
  };

  libxo = callPackage ./pkgs/libxo/libxo.nix {
    toolchain = toolchainStage3;
  };
  libxoTest = callPackage ./pkgs/libxo/libxo-test.nix {
    toolchain = toolchainStage3;
  };

  quickjsBuildRoot = callPackage ./pkgs/quickjs/build-root.nix { };
  quickjs = callPackage ./pkgs/quickjs/quickjs.nix {
    toolchain = toolchainStage3;
  };
  quickjsTest = callPackage ./pkgs/quickjs/quickjs-test.nix { };

  libressl = callPackage ./pkgs/libressl/libressl.nix {
    toolchain = toolchainStage3;
  };

  openssl098 = callPackage ./pkgs/openssl098/openssl098.nix {
    toolchain = toolchainStage3;
  };

  # Apple's nano editor, installed as /usr/bin/pico with a nano alias.
  nano = callPackage ./pkgs/nano/nano.nix {
    toolchain = toolchainStage3;
  };

  bash = callPackage ./pkgs/bash/bash.nix {
    toolchain = toolchainStage3;
  };
  darwinPerl = callPackage ./pkgs/perl/perl.nix {
    toolchain = toolchainStage3;
  };
  zsh = callPackage ./pkgs/zsh/zsh.nix {
    toolchain = toolchainStage3;
  };

  authHeaders = callPackage ./pkgs/auth/headers.nix { };
  su = callPackage ./pkgs/su/su.nix {
    toolchain = toolchainStage3;
  };
  sudo = callPackage ./pkgs/sudo/sudo.nix {
    toolchain = toolchainStage3;
  };
  authTest = callPackage ./pkgs/auth/auth-test.nix { };

  # Independent pkg installer; bootstrap builds the same core in host world.
  installer = callPackage ./pkgs/installer/installer.nix {
    toolchain = toolchainStage3;
  };
  installerBootstrap = pkgs.callPackage ./pkgs/installer/bootstrap.nix {
    inherit quickjsBuildRoot;
  };
  installerTest = callPackage ./pkgs/installer/installer-test.nix { };

  # Independent C++ init; host build is used only for isolated behavior tests.
  launchd = callPackage ./pkgs/launchd/launchd.nix {
    toolchain = toolchainStage4;
  };
  launchdBootstrap = pkgs.callPackage ./pkgs/launchd/bootstrap.nix { };
  launchdTest = callPackage ./pkgs/launchd/launchd-test.nix { };

  #### stage 7: the rootfs ####################################################

  # Assembled rootfs (early - later stages add inputs here).
  rootfs = callPackage ./pkgs/rootfs.nix {
    toolchain = toolchainStage3;
  };

  # What a release publishes: tarball, manifest, spec, bundle (docs/rootfs-spec.md).
  release = import ./lib/release.nix;
  mdrootfsScript = ./scripts/mdrootfs.py;
  mdrootfs = callPackage ./pkgs/release/mdrootfs.nix { };
  rootfsRelease = callPackage ./pkgs/release/rootfs-release.nix { };
  releaseTest = callPackage ./pkgs/release/release-test.nix { };

  #### stage 5: the dynamic linker ############################################

  # dyld's Mach-O reader (static archive, not installed).
  libmachO = callPackage ./pkgs/dyld/libmach-o.nix {
    toolchain = toolchainStage2;
  };

  libdyld = callPackage ./pkgs/dyld/libdyld.nix {
    toolchain = toolchainStage2;
  };
  runtimeInfo = callPackage ./pkgs/libsystem/runtime-info.nix {
    toolchain = toolchainStage2;
  };
  libsystemM = callPackage ./pkgs/libsystem/libsystem-m.nix {
    toolchain = toolchainStage2;
  };
  runtimeNotify = callPackage ./pkgs/libsystem/runtime-notify.nix {
    toolchain = toolchainStage2;
  };
  runtimeAsl = callPackage ./pkgs/libsystem/runtime-asl.nix {
    toolchain = toolchainStage2;
  };
  runtimeCryptoTest = callPackage ./pkgs/libsystem/runtime-crypto-test.nix { };
  runtimeCrypto = callPackage ./pkgs/libsystem/runtime-crypto.nix {
    toolchain = toolchainStage2;
  };
  # absent-members.nix entries the runtime tree supplies. runtimeCrypto,
  # runtimeNotify and runtimeAsl are narrow providers, not the closed-source
  # libraries; runtimeAsl is only the BSD syslog half of system_asl.
  runtimeMembers = [ "dyld" "corecrypto" "system_info" "system_m" "system_notify" "system_asl" ];
  libsystemRuntimeTree = callPackage ./pkgs/libsystem/libsystem-tree.nix {
    name = "minidarwin-libsystem-runtime";
    members = [ libsystemTree2 libdyld runtimeCrypto runtimeInfo libsystemM runtimeNotify runtimeAsl ];
  };
  libSystemRuntime = libSystem.override {
    members = libsystemRuntimeTree;
    initialize = true;
    provided = runtimeMembers;
  };
  bootRootfs = rootfs.override {
    libSystem = libSystemRuntime;
    libsystemTree2 = libsystemRuntimeTree;
    runtimeDyld = dyld;
    # Every hole labelled with these is now defined by the runtime tree...
    resolvedAbsences = [ "dyld" "corecrypto" "system_info" "system_m" "system_notify" ];
    # ...and of system_asl, only the syslog functions are.
    resolvedSymbols = [ "_syslog$DARWIN_EXTSN" "_openlog" "_closelog" ];
  };
  dyldObjects = callPackage ./pkgs/dyld/dyld-objects.nix {
    toolchain = toolchainStage2;
  };
  dyldRuntimeArchives = callPackage ./pkgs/dyld/runtime-archives.nix {
    toolchain = toolchainStage2;
  };
  dyld = callPackage ./pkgs/dyld/dyld.nix {
    toolchain = toolchainStage2;
  };
  dyldDigestsTest = callPackage ./pkgs/dyld/digests-test.nix { };

  kernel = callPackage ./pkgs/xnu/kernel.nix { };
  kernelObjects = callPackage ./pkgs/xnu/kernel-objects.nix {
    toolchain = (callPackage ./lib/toolchain.nix {
      llvmPackages = llvmPackages // { clang-unwrapped = xnuClang; };
    }) {
      name = "minidarwin-kernel-toolchain";
      sysroot = sdkHeaders;
      resourceDir = clangResourceDir;
      freestanding = true;
    };
  };
  xnuClang = callPackage ./pkgs/xnu/clang.nix { };
  xnuClangObjects = callPackage ./pkgs/xnu/frontend-objects.nix { };
  iig = callPackage ./pkgs/xnu/iig.nix { };
  efiLoader = callPackage ./pkgs/xnu/efi-loader.nix { };
  kcTools = callPackage ./pkgs/xnu/kc-tools.nix { };
  platformDrivers = callPackage ./pkgs/xnu/platform-drivers.nix { };
  storageDrivers = platformDrivers.override { includeStorage = true; };
  kernelCollection = callPackage ./pkgs/xnu/kernel-collection.nix { };
  platformKernelCollection = kernelCollection.override {
    kexts = map (name: "${platformDrivers}/System/Library/Extensions/${name}.kext")
      [ "IOACPIFamily" "PDACPIPlatform" "IOPCIFamily" "AppleAPIC" "AppleI386PCI" ];
  };
  storageKernelCollection = kernelCollection.override {
    kexts = map (name: "${storageDrivers}/System/Library/Extensions/${name}.kext")
      [ "pthread" "IOACPIFamily" "PDACPIPlatform" "IOPCIFamily" "AppleAPIC" "AppleI386PCI"
        "IOStorageFamily" "IOVirtIOFamily" "IOVirtIOBlock" "ext4" "Ext4FileSystemDriver" ];
  };
  storageBootImage = mkBootDisk {
    name = "minidarwin-storage-boot-disk";
    kernel = "${storageKernelCollection}/kernel";
  };
  rootMountTest = callPackage ./pkgs/xnu/root-mount-test.nix { };
  bootTest = callPackage ./pkgs/xnu/boot-test.nix { };
  rootMountFixture = callPackage ./pkgs/xnu/root-probe.nix { };
  rootMountProbeImage = mkBootDisk {
    name = "minidarwin-root-mount-probe-disk";
    kernel = "${storageKernelCollection}/kernel";
    rootPartition = "${rootMountFixture}/root.ext4";
    bootArgs = "-v serial=3 keepsyms=1 rd=disk0s2";
  };
  qemuRootMountProbe = qemuEfi.override {
    efiBootImage = rootMountProbeImage;
    virtioBlock = true;
  };
  bootRootPartition = callPackage ./pkgs/xnu/root-image.nix { };
  bootImage = mkBootDisk {
    name = "minidarwin-boot-disk";
    kernel = "${storageKernelCollection}/kernel";
    rootPartition = "${bootRootPartition}/root.ext4";
    bootArgs = "-v serial=3 keepsyms=1 rd=disk0s2";
  };
  # Same root as bootImage, but PID 1's job is a console shell, not the proof.
  shellRootPartition = callPackage ./pkgs/xnu/root-image.nix { interactive = true; };
  shellBootImage = mkBootDisk {
    name = "minidarwin-shell-boot-disk";
    kernel = "${storageKernelCollection}/kernel";
    rootPartition = "${shellRootPartition}/root.ext4";
    bootArgs = "-v serial=3 keepsyms=1 rd=disk0s2";
  };
  qemuBoot = qemuEfi.override {
    efiBootImage = shellBootImage;
    interactive = true;
    virtioBlock = true;
  };
  platformBootImage = mkBootDisk {
    name = "minidarwin-platform-boot-disk";
    kernel = "${platformKernelCollection}/kernel";
  };
  qemuPlatform = qemuEfi.override { efiBootImage = platformBootImage; };
  mkBootDisk = callPackage ./pkgs/xnu/boot-disk.nix { };
  # Firmware disk only; a complete XNU/root-filesystem image is still pending.
  efiBootImage = mkBootDisk { };
  kernelBootImage = mkBootDisk {
    name = "minidarwin-kernel-boot-disk";
    kernel = "${kernelCollection}/kernel";
  };
  qemuEfi = callPackage ./pkgs/xnu/qemu-efi.nix { };
  qemuKernel = qemuEfi.override { efiBootImage = kernelBootImage; };
  trustCacheTest = callPackage ./pkgs/xnu/trust-cache-test.nix { };
  kernelStartupTest = callPackage ./pkgs/xnu/kernel-startup-test.nix { };
  kernelCryptoTest = callPackage ./pkgs/xnu/crypto-test.nix { };
  bootDiskTest = callPackage ./pkgs/xnu/boot-disk-test.nix { };
})
