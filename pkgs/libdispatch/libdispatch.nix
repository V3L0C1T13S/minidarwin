# Apple's core libdispatch, linked against pass-1 libSystem members so it can
# join the pass-2 umbrella without creating a dependency cycle.
{ lib
, mkDarwinPackage
, sources
, toolchain
, libsystemPass1
, libsyscall
, mig
, targetArch
}:

let
  version = lib.removePrefix "libdispatch-" sources.libdispatch.rev;
  members = [ libsyscall ] ++ (with libsystemPass1; [
    compilerRtDylib
    unwindDylib
    libmacho
    libsystemBlocks
    libsystemC
    libsystemCollections
    libsystemPlatform
    libsystemPthread
    libsystemMalloc
  ]);
  sourcesToCompile = [
    "allocator.c"
    "apply.c"
    "benchmark.c"
    "data.c"
    "init.c"
    "introspection.c"
    "io.c"
    "mach.c"
    "object.c"
    "once.c"
    "queue.c"
    "semaphore.c"
    "source.c"
    "time.c"
    "transform.c"
    "voucher.c"
    "shims.c"
    "event/event.c"
    "event/event_kevent.c"
    "shims/lock.c"
    "shims/yield.c"
    "firehose/firehose_buffer.c"
  ];
in

mkDarwinPackage {
  pname = "libdispatch";
  inherit version toolchain;
  src = sources.libdispatch;
  nativeBuildInputs = [ mig ];

  passthru.libsystemName = "dispatch";
  passthru.allowUndefined = { };

  buildPhase = ''
    runHook preBuild

    export MD_SRCROOT=$PWD
    mkdir -p obj
    chmod u+w config/config.h
    # The ObjC runtime is not part of MiniDarwin. Keep the source's Darwin
    # feature table, but select its C-only implementation.
    substituteInPlace config/config.h \
      --replace-fail '#define HAVE_OBJC 1' '/* #undef HAVE_OBJC */' \
      --replace-fail '#define HAVE_PTHREAD_MACHDEP_H 1' '/* #undef HAVE_PTHREAD_MACHDEP_H */'
    substituteInPlace src/mach.c \
      --replace-fail 'relpri = _pthread_priority_relpri(dmsg->dmsg_priority);' \
                     '(void)_pthread_qos_class_decode(dmsg->dmsg_priority, &relpri, NULL);'
    substituteInPlace src/queue.c \
      --replace-fail '_pthread_priority_has_qos(pp)' \
                     '(_pthread_qos_class_decode(pp, NULL, NULL) != QOS_CLASS_UNSPECIFIED)'
    substituteInPlace src/source.c \
      --replace-fail '#ifdef DBG_BSD_MEMSTAT' \
                     '#if defined(DBG_BSD_MEMSTAT) && defined(EVFILT_MEMORYSTATUS)'

    cat > migcc <<MIGCC
    #!/bin/sh
    exec $CC "\$@"
    MIGCC
    chmod +x migcc
    export MIGCC=$PWD/migcc
    mig -novouchers -arch ${if targetArch == "aarch64" then "armv7" else "i386"} \
      -I$MINIDARWIN_SYSROOT/usr/include \
      -header $PWD/src/protocol.h -sheader $PWD/src/protocolServer.h \
      -user $PWD/src/protocolUser.c -server $PWD/src/protocolServer.c \
      $PWD/src/protocol.defs
    for spec in firehose firehose_reply; do
      mig -novouchers -arch ${if targetArch == "aarch64" then "armv7" else "i386"} \
        -I$MINIDARWIN_SYSROOT/usr/include -I$PWD/src/firehose \
        -header $PWD/src/firehose/$spec.h \
        -sheader $PWD/src/firehose/''${spec}Server.h \
        -user $PWD/src/firehose/''${spec}User.c \
        -server $PWD/src/firehose/''${spec}Server.c \
        $PWD/src/firehose/$spec.defs
    done

    flags=(
      -std=gnu11 -Os -fblocks -fno-common -fvisibility=hidden
      -DDISPATCH_USE_DTRACE=0 -DDISPATCH_SEND_ACTIVITY_IN_MSGV=0
      -DHAVE_DYLD_IS_MEMORY_IMMUTABLE=0
      -DPTHREAD_WQ_QUANTUM_EXPIRY_NARROW=0
      -DOS_ATOMIC_CONFIG_MEMORY_ORDER_DEPENDENCY=1
      -include mach/mach_time_private.h -include sys/kdebug_private.h
      -include sys/proc_info_private.h
      -Wno-availability -I$PWD -I$PWD/src -I$PWD/src/firehose -I$PWD/private
    )
    md_compile $PWD/obj "$CC" "''${flags[@]}" -- \
      ${lib.concatMapStringsSep " " (f: "$PWD/src/${f}") sourcesToCompile} \
      $PWD/src/protocolUser.c $PWD/src/protocolServer.c \
      $PWD/src/firehose/firehoseUser.c \
      $PWD/src/firehose/firehose_replyServer.c \
      ${./workgroup-unavailable.c}
    md_compile $PWD/obj "$CXX" -Os -fblocks -fno-exceptions \
      -fvisibility=hidden -DDISPATCH_USE_DTRACE=0 \
      -DDISPATCH_SEND_ACTIVITY_IN_MSGV=0 -DHAVE_DYLD_IS_MEMORY_IMMUTABLE=0 \
      -DPTHREAD_WQ_QUANTUM_EXPIRY_NARROW=0 \
      -DOS_ATOMIC_CONFIG_MEMORY_ORDER_DEPENDENCY=1 \
      -include mach/mach_time_private.h -include sys/kdebug_private.h \
      -include sys/proc_info_private.h \
      -Wno-availability \
      -I$PWD -I$PWD/src -I$PWD/src/firehose -I$PWD/private -- $PWD/src/block.cpp

    # Link against the first pass directly: sdkStage3 and libSystem depend on
    # the second pass, which in turn needs dispatch.
    libdirs=( ${lib.escapeShellArgs (map (p: "-L${p}/usr/lib/system") members)} )
    MD_CURRENT_VERSION=${version} \
      md_dylib libdispatch.dylib /usr/lib/system/libdispatch.dylib obj \
        -Wl,-umbrella,System -Wl,-dead_strip -Wl,-undefined,error \
        "''${libdirs[@]}" \
        -lsystem_kernel -lsystem_platform -lsystem_pthread \
        -lsystem_malloc -lsystem_c -lsystem_blocks \
        -lcompiler_rt -lunwind -lmacho

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 libdispatch.dylib $out/usr/lib/system/libdispatch.dylib
    md_verify_pure $out/usr/lib/system/libdispatch.dylib
    md_verify_signed $out/usr/lib/system/libdispatch.dylib
    md_verify_symbols $out/usr/lib/system/libdispatch.dylib \
      _dispatch_once_f _dispatch_async_f _dispatch_group_create \
      _dispatch_semaphore_create _dispatch_io_create

    runHook postInstall
  '';

  meta.description = "Apple core libdispatch for MiniDarwin";
}
