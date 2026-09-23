# Stage 4: libsystem_malloc.dylib - malloc/free, magazine/nanov2/xzone/PGM zones, introspection.
# Almost every umbrella member depends on it; it depends on libsystem_c (snprintf) and libsystem_blocks (callbacks) via upward links.
# (UPLINK_LDFLAGS crosslink noted for removal since radar 13046853.)
{ lib
, mkDarwinPackage
, sources
, toolchain
, systemFrameworkHeaders
, umbrellaLink
, python3
, libsystemStage1 ? null
}:

let
  # Symbols from absent libs: corecrypto (SHA-256 in corruption diagnostics), dyld (restricted/SDK/immutable checks).
  allowUndefined = {
    "_cc_clear" = "corecrypto";
    "_ccdigest_init" = "corecrypto";
    "_ccdigest_update" = "corecrypto";
    "_ccsha256_di" = "corecrypto";
    "_NSVersionOfLinkTimeLibrary" = "dyld";
    "__dyld_get_image_header" = "dyld";
    "__dyld_get_image_slide" = "dyld";
    "__dyld_is_memory_immutable" = "dyld";
    "_dyld_get_active_platform" = "dyld";
    "_dyld_get_program_sdk_version_token" = "dyld";
    "_dyld_process_is_restricted" = "dyld";
    "_dyld_program_sdk_at_least" = "dyld";
  };

  linkFlags = umbrellaLink {
    stage1 = libsystemStage1;
    libs = [ "compiler_rt" "system_platform" "system_kernel" "system_pthread" "dyld" "corecrypto" ]; # OTHER_LDFLAGS minus -ldyld/-lcorecrypto/-lfeatureflags (closed/stage 5)
    upward = [ "system_c" "system_blocks" ];
    inherit allowUndefined;
  };

  cflags = [
    "-Os"
    "-fno-common"
    "-momit-leaf-frame-pointer"
    "-DNDEBUG"
    "-D_FORTIFY_SOURCE=0"
    "-DOS_ATOMIC_CONFIG_MEMORY_ORDER_DEPENDENCY=1"
    "-DOS_VARIANT_RESOLVED=1" # no-resolver build: both arms of nanov2_malloc.c in one lib (Apple builds per-variant + .symbol_resolver)
    "-DOS_VARIANT_NOTRESOLVED=1"
    "-DOSATOMIC_USE_INLINED=1" # inlined (consumer, opposite of libplatform)
    "-DOS_UNFAIR_LOCK_INLINE=1"
    "-Wno-format-invalid-specifier" # simple_printf %y
    "-Wno-format-extra-args"
    "-Wno-unknown-warning-option"
    "-Wno-atomic-implicit-seq-cst"
  ];

  allSources = import ./libmalloc-sources.nix;
  codeFiles = builtins.filter (p: !lib.hasSuffix ".d" p) allSources;
in

mkDarwinPackage {
  pname = "libsystem_malloc-pass${if libsystemStage1 == null then "1" else "2"}";
  version = lib.removePrefix "libmalloc-" sources.libmalloc.rev;

  src = sources.libmalloc;
  inherit toolchain;

  nativeBuildInputs = [ python3 ];

  passthru.libsystemName = "system_malloc";
  passthru.allowUndefined = allowUndefined; # checked by rootfs.nix

  buildPhase = ''
    runHook preBuild

    export MD_SRCROOT=$PWD
    obj=$PWD/o
    derived=$PWD/derived/dtrace
    mkdir -p $obj $derived

    # featureflags: <os/feature_private.h> unreleased; guard with __has_include and disable CONFIG_FEATUREFLAGS_SIMPLE fallback.
    substituteInPlace src/internal.h --replace-fail \
      '#if !TARGET_OS_DRIVERKIT && !MALLOC_TARGET_EXCLAVES
# include <os/feature_private.h>' \
      '#if !TARGET_OS_DRIVERKIT && !MALLOC_TARGET_EXCLAVES && __has_include(<os/feature_private.h>)
# include <os/feature_private.h>'

    substituteInPlace src/platform.h --replace-fail \
      '#if !TARGET_OS_DRIVERKIT && (!TARGET_OS_OSX || MALLOC_TARGET_64BIT)
#define CONFIG_FEATUREFLAGS_SIMPLE 1' \
      '#if !TARGET_OS_DRIVERKIT && (!TARGET_OS_OSX || MALLOC_TARGET_64BIT) && __has_include(<os/feature_private.h>)
#define CONFIG_FEATUREFLAGS_SIMPLE 1'

    # nano v1 layout is x86_64-only; narrow guard so arm64 doesn't hit #error (v1 vestigial, nanov2 is the arm64 allocator).
    substituteInPlace src/nano_zone.h --replace-fail \
      '#if CONFIG_NANOZONE' \
      '#if CONFIG_NANOZONE && defined(__x86_64__) /* minidarwin: v1 layout is x86_64-only */'

    # DTrace: generate magmallocProvider.h via stub (no host dtrace); mirrors DARWINTEST no-op macros from .d file.
    python3 ${../../scripts/dtrace-provider-stub.py} \
      $PWD/src/magmallocProvider.d $derived/magmallocProvider.h

    incflags=( -I$derived -I$PWD/include -I$PWD/private -I$PWD/resolver -I$PWD/src
               -iwithsysroot ${systemFrameworkHeaders} ) # SYSTEM_HEADER_SEARCH_PATHS

    sources=()
    for f in ${lib.concatStringsSep " " codeFiles}; do
      sources+=( "$PWD/$f" )
    done

    md_log "libmalloc: ''${#sources[@]} objects"
    md_compile $obj "$CC" ${lib.escapeShellArgs cflags} \
      "''${incflags[@]}" -- "''${sources[@]}"

    # INTERPOSE_LDFLAGS (-interposable_list) skipped: ld64.lld doesn't implement it; only affects DYLD_INSERT_LIBRARIES interposing.
    md_dylib libsystem_malloc.dylib \
      /usr/lib/system/libsystem_malloc.dylib $obj \
      ${lib.escapeShellArgs linkFlags}

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 libsystem_malloc.dylib \
      $out/usr/lib/system/libsystem_malloc.dylib

    md_verify_pure   $out/usr/lib/system/libsystem_malloc.dylib
    md_verify_signed $out/usr/lib/system/libsystem_malloc.dylib

    md_verify_symbols $out/usr/lib/system/libsystem_malloc.dylib \
      _malloc _calloc _realloc _free _valloc _aligned_alloc _posix_memalign \
      _malloc_size _malloc_good_size \
      _malloc_default_zone _malloc_create_zone _malloc_destroy_zone \
      _malloc_zone_malloc _malloc_zone_free _malloc_zone_from_ptr \
      _malloc_get_all_zones _malloc_zone_statistics \
      _malloc_printf _malloc_zone_check

    runHook postInstall
  '';

  meta.description = "libmalloc -- malloc and the zone allocators";
}
