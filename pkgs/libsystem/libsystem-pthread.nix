# Stage 4: libsystem_pthread.dylib - POSIX threads and workqueue.
# Cycle via libsystem_c ↔ libsystem_pthread broken by two-pass link (see umbrella-link.nix).
{ lib
, mkDarwinPackage
, sources
, toolchain
, systemFrameworkHeaders
, targetArch
, umbrellaLink
, libsystemStage1 ? null
}:

let
  # dyld introspection for JIT write-protect allowlist; arm64-only (_PTHREAD_CONFIG_JIT_WRITE_PROTECT is TARGET_CPU_ARM64).
  allowUndefined = lib.optionalAttrs (targetArch == "aarch64") {
    "__dyld_register_for_bulk_image_loads" = "dyld";
  };

  linkFlags = umbrellaLink {
    stage1 = libsystemStage1;
    # DYLIB_LDFLAGS_COMMON from xcodescripts/pthread.xcconfig; stage 5 libs (dyld/macho) filtered via absent.
    libs = [ "system_kernel" "system_platform" "dyld" ];
    upward = [ "macho" ]; # getsectiondata for workqueue callbacks
    inherit allowUndefined;
  };

  # BASE_PREPROCESSOR_MACROS + OTHER_CFLAGS from xcodescripts/pthread.xcconfig.
  cflags = [
    "-std=gnu11"
    "-Os"
    "-fno-common"
    "-fno-stack-protector"
    "-fno-stack-check"
    "-fno-builtin" # prevents clang turning definitions into self-calls
    "-momit-leaf-frame-pointer"
    "-D__LIBC__"
    "-D__POSIX_LIB__"
    "-D__DARWIN_UNIX03=1"
    "-D__DARWIN_64_BIT_INO_T=1"
    "-D__DARWIN_NON_CANCELABLE=1"
    "-D__DARWIN_VERS_1050=1"
    "-D_FORTIFY_SOURCE=0"
    "-D__PTHREAD_BUILDING_PTHREAD__=1" # expose internal struct layouts
    "-D__PTHREAD_EXPOSE_INTERNALS__"
    "-DOS_ATOMIC_CONFIG_MEMORY_ORDER_DEPENDENCY=1"
    "-Wno-int-conversion"
    "-Wno-sign-compare"
    "-Wno-sign-conversion"
    "-Wno-unused-parameter"
    "-Wno-unknown-warning-option"
    "-Wno-atomic-implicit-seq-cst"
  ];

  codeFiles = import ./libpthread-sources.nix;

  version = lib.removePrefix "libpthread-" sources.libpthread.rev;

  # Independent of libsystemStage1, so both passes share this one derivation.
  objects = mkDarwinPackage {
    pname = "libsystem_pthread-objects";
    inherit version toolchain;

    src = sources.libpthread;
    buildPhase = ''
      runHook preBuild

      export MD_SRCROOT=$PWD
      obj=$PWD/o
      mkdir -p $obj

      # _os_xbs_chrooted is defined in libsyscall but undeclared in this tree; inject declaration via imports_internal.h.
      substituteInPlace src/imports_internal.h --replace-fail \
        'extern boolean_t swtch_pri(int);' \
        'extern boolean_t swtch_pri(int);

  /* minidarwin: defined in libsyscall (_libkernel_init.c), exported from
     libsystem_kernel, declared only in Apple'"'"'s internal SDK. */
  #include <stdbool.h>
  extern bool _os_xbs_chrooted;'

      incflags=( -I$PWD/src/resolver -I$PWD/private -I$PWD/include -I$PWD # source headers ahead of sysroot
                 -iwithsysroot ${systemFrameworkHeaders} ) # SYSTEM_HEADER_SEARCH_PATHS

      sources=()
      for f in ${lib.concatStringsSep " " codeFiles}; do
        sources+=( "$PWD/$f" )
      done

      md_log "libpthread: ''${#sources[@]} objects"
      md_compile $obj "$CC" ${lib.escapeShellArgs cflags} \
        "''${incflags[@]}" -- "''${sources[@]}"

      runHook postBuild
    '';

    installPhase = "cp -R $obj $out";
  };
in

mkDarwinPackage {
  pname = "libsystem_pthread-pass${if libsystemStage1 == null then "1" else "2"}";
  inherit version toolchain;
  dontUnpack = true;

  passthru.libsystemName = "system_pthread";
  passthru.allowUndefined = allowUndefined; # checked by rootfs.nix
  passthru.objects = objects;

  buildPhase = ''
    runHook preBuild

    mapfile -t aliasFlags < <(md_alias_flags ${sources.libpthread}/xcodescripts/pthread.aliases) # provides $NOCANCEL/$UNIX2003 aliases

    md_dylib libsystem_pthread.dylib \
      /usr/lib/system/libsystem_pthread.dylib ${objects} \
      "''${aliasFlags[@]}" \
      ${lib.escapeShellArgs linkFlags}

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 libsystem_pthread.dylib \
      $out/usr/lib/system/libsystem_pthread.dylib

    md_verify_pure   $out/usr/lib/system/libsystem_pthread.dylib
    md_verify_signed $out/usr/lib/system/libsystem_pthread.dylib

    md_verify_symbols $out/usr/lib/system/libsystem_pthread.dylib \
      _pthread_create _pthread_join _pthread_detach _pthread_exit \
      _pthread_self _pthread_equal \
      _pthread_mutex_init _pthread_mutex_lock _pthread_mutex_unlock \
      _pthread_cond_init _pthread_cond_wait _pthread_cond_signal \
      _pthread_rwlock_rdlock _pthread_rwlock_wrlock _pthread_rwlock_unlock \
      _pthread_key_create _pthread_getspecific _pthread_setspecific \
      _pthread_once _pthread_atfork \
      _pthread_workqueue_setdispatch_np _pthread_get_stacksize_np

    runHook postInstall
  '';

  meta.description = "libpthread -- POSIX threads and the workqueue interface";
}
