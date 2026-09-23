# Stage 4: libsystem_platform.dylib - locks, atomics, setjmp, ucontext, string, cachecontrol, _simple.
# No .xcodeproj; sources from perarch.xcconfig (arch subdir + generic per component, e.g. cachecontrol/arm64+generic).
# 8 static archives (-all_load) collapsed to one object dir (archives not installed).
{ lib
, mkDarwinPackage
, sources
, toolchain
, systemFrameworkHeaders
, umbrellaLink
, targetArch
, libsystemStage1 ? null
}:

let
  # ARCH_FAMILY from xcodeconfig/perarch.xcconfig.
  archFamily = if targetArch == "aarch64" then "arm64" else "x86_64";

  linkFlags = umbrellaLink {
    stage1 = libsystemStage1;
    libs = [ "system_kernel" ]; # OTHER_LDFLAGS; no -ldyld (xcconfig clears it for simulator slice)
  };

  # OTHER_CFLAGS + GCC_PREPROCESSOR_DEFINITIONS from libplatform.xcconfig.
  commonCFlags = [
    "-Os"
    "-fno-stack-protector"
    "-fdollars-in-identifiers"
    "-fno-common"
    "-momit-leaf-frame-pointer"
    "-D_FORTIFY_SOURCE=0"
    "-DCONFIG_MTE=${if targetArch == "aarch64" then "1" else "0"}" # MTE_DEFINITIONS[macosx][arm64]
    "-DOSATOMIC_USE_INLINED=0"
    "-DOSATOMIC_DEPRECATED=0"
    "-Wno-deprecated-declarations" # for deprecated OSSpinLock shims
    "-Wno-unknown-warning-option"
    "-Wno-atomic-implicit-seq-cst"
    "-Wno-int-conversion" # uintptr_t -> void* in atomics/init.c
  ];

  # OSSPINLOCK_USE_INLINED controls whether OSAtomic.h declares or inlines OSSpinLock; libos defines out-of-line (0), others inline (1).
  defaultSpinlock = [ "-DOSSPINLOCK_USE_INLINED=1" "-DOS_UNFAIR_LOCK_INLINE=0" ];
  osSpinlock = [ "-DOSSPINLOCK_USE_INLINED=0" "-DOSSPINLOCK_DEPRECATED=0" "-DOS_UNFAIR_LOCK_INLINE=0" ];
in

mkDarwinPackage {
  pname = "libsystem_platform-pass${if libsystemStage1 == null then "1" else "2"}";
  version = lib.removePrefix "libplatform-" sources.libplatform.rev;

  src = sources.libplatform;
  inherit toolchain;

  passthru.libsystemName = "system_platform";

  buildPhase = ''
    runHook preBuild

    export MD_SRCROOT=$PWD
    obj=$PWD/o
    mkdir -p $obj

    # AppleFeatures.h is unreleased and unused here (2 files include it, no macro used).
    for f in src/init.c src/os/security_config.c; do
      substituteInPlace $f \
        --replace-fail '#include <AppleFeatures/AppleFeatures.h>' \
          '/* minidarwin: AppleFeatures.h is unreleased and unused here. */'
    done

    # bzero.c hidden memset just calls _platform_memset; dropped because _memset alias below provides same symbol (duplicate otherwise).
    memsetShim=$(printf '__attribute__((visibility("hidden")))\nvoid *\nmemset(void *b, int c, size_t len)\n{\n\treturn _platform_memset(b, c, len);\n}')
    substituteInPlace src/string/generic/bzero.c \
      --replace-fail "$memsetShim" \
      '/* minidarwin: superseded by the _memset alias; see libsystem-platform.nix. */'

    incflags=( -I$PWD/private -I$PWD/include -I$PWD/internal -I$PWD/src/os/resolver
               -iwithsysroot ${systemFrameworkHeaders} ) # SYSTEM_HEADER_SEARCH_PATHS

    # All components: generic + arch subdir per component; exclavekit omitted (separate SDK, collides with os/lock.c).
    mapfile -t sources < <(md_glob \
      $PWD/src/*.c \
      $PWD/src/atomics/*.c        $PWD/src/atomics/common/*.c \
      $PWD/src/atomics/${archFamily}/*.c   $PWD/src/atomics/${archFamily}/*.s \
      $PWD/src/cachecontrol/generic/*.c \
      $PWD/src/cachecontrol/${archFamily}/*.c $PWD/src/cachecontrol/${archFamily}/*.s \
      $PWD/src/setjmp/generic/*.c \
      $PWD/src/setjmp/${archFamily}/*.c    $PWD/src/setjmp/${archFamily}/*.s \
      $PWD/src/simple/*.c \
      $PWD/src/string/generic/*.c \
      $PWD/src/string/${archFamily}/*.c    $PWD/src/string/${archFamily}/*.s \
      $PWD/src/timingsafe/${archFamily}/*.c \
      $PWD/src/ucontext/generic/*.c \
      $PWD/src/ucontext/${archFamily}/*.c  $PWD/src/ucontext/${archFamily}/*.s)

    mapfile -t osSources < <(md_glob $PWD/src/os/*.c) # libos needs separate spinlock flags

    md_log "libplatform: ''${#sources[@]} + ''${#osSources[@]} objects"

    md_compile $obj "$CC" ${lib.escapeShellArgs (commonCFlags ++ defaultSpinlock)} \
      "''${incflags[@]}" -- "''${sources[@]}"
    md_compile $obj "$CC" ${lib.escapeShellArgs (commonCFlags ++ osSpinlock)} \
      "''${incflags[@]}" -- "''${osSources[@]}"

    mapfile -t aliasFlags < <(md_alias_flags $PWD/xcodeconfig/libplatform.aliases) # eliding/transactional locks -> spin, bzero -> ___bzero

    # Libc's alias.list (22 symbols like __platform_memmove→_memcpy) belongs to libsystem_c but ld64.lld can't alias imported symbols.
    # Applied here where targets are local; umbrella re-exports both members so libSystem clients see same names.
    mapfile -t -O ''${#aliasFlags[@]} aliasFlags \
      < <(md_alias_flags ${sources.Libc}/xcodescripts/alias.list)

    # _flsl alias of _flsll (same address on LP64); needed by qsort/psort.
    aliasFlags+=( -Wl,-alias,_flsll,_flsl )

    md_dylib libsystem_platform.dylib \
      /usr/lib/system/libsystem_platform.dylib $obj \
      "''${aliasFlags[@]}" \
      ${lib.escapeShellArgs linkFlags}

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 libsystem_platform.dylib \
      $out/usr/lib/system/libsystem_platform.dylib

    md_verify_pure   $out/usr/lib/system/libsystem_platform.dylib
    md_verify_signed $out/usr/lib/system/libsystem_platform.dylib

    # One symbol per component - missing source dir fails here, not two libs later.
    md_verify_symbols $out/usr/lib/system/libsystem_platform.dylib \
      _os_unfair_lock_lock _os_unfair_lock_unlock __os_once \
      _OSAtomicCompareAndSwap32 _OSAtomicFifoEnqueue \
      _sys_cache_control _sys_icache_invalidate _sys_dcache_flush \
      __setjmp __longjmp _sigsetjmp _siglongjmp \
      __platform_memmove __platform_strlen __platform_bzero ___bzero \
      _getcontext _setcontext _makecontext _swapcontext \
      __simple_asl_log __simple_vsnprintf \
      __os_alloc_once __os_semaphore_create \
      _timingsafe_enable_if_supported

    runHook postInstall
  '';

  meta.description = "libplatform -- locks, atomics, setjmp, ucontext, string";
}
