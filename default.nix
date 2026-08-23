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

  sources = import ./lib/sources.nix { inherit (pkgs) fetchFromGitHub; };

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
        # dyld (stage 5) + dispatch holes; x86_64 adds system_m long-double.
        allowUndefined = {
          "_dlsym" = "dyld";
          "__availability_version_check" = "dyld";
          "_dispatch_once_f" = "dispatch";
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
    ] ++ [ libsyscall ];
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
    ] ++ [ libsyscall ];
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

  # Top-level C++ dylibs (need libSystem for malloc/pthread).
  libcxxabiDylib = callPackage ./pkgs/llvm-runtimes/libcxxabi-dylib.nix {
    toolchain = toolchainStage3;
  };

  libcxxDylib = callPackage ./pkgs/llvm-runtimes/libcxx-dylib.nix {
    toolchain = toolchainStage3;
  };

  #### stage 7: the rootfs ####################################################

  # Assembled rootfs (early - later stages add inputs here).
  rootfs = callPackage ./pkgs/rootfs.nix {
    toolchain = toolchainStage3;
  };

  #### stage 5: the dynamic linker ############################################

  # dyld's Mach-O reader (static archive, not installed).
  libmachO = callPackage ./pkgs/dyld/libmach-o.nix {
    toolchain = toolchainStage2;
  };
})
