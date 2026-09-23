# Stage 2: libsystem_kernel.dylib (xnu Libsyscall) - bottom of userspace.
# Syscall stubs (create-syscalls.pl) + mig RPC stubs + hand-written wrappers; file list from xcodeproj; -nostdlib.
{ lib
, mkDarwinPackage
, sources
, toolchain
, systemFrameworkHeaders
, mig
, perl
, targetArch
}:

let
  machoArch = toolchain.machoArch;
  migArch = if targetArch == "aarch64" then "armv7" else "i386";

  allSources = import ./libsyscall-sources.nix;
  defsFiles = builtins.filter (p: lib.hasSuffix ".defs" p) allSources;
  codeFiles = builtins.filter (p: !lib.hasSuffix ".defs" p) allSources;

  # OTHER_CFLAGS + GCC_PREPROCESSOR_DEFINITIONS from Libsyscall.xcconfig.
  xcconfigCFlags = [
    "-std=gnu11"
    "-fdollars-in-identifiers"
    "-fno-common"
    "-fno-stack-protector"
    "-fno-stack-check"
    "-fno-builtin-calloc"
    "-momit-leaf-frame-pointer"
    "-DLIBSYSCALL_INTERFACE"
    "-D__DARWIN_VERS_1050=1"
    "-DNO_SYSCALL_LEGACY"
    "-DCF_OPEN_SOURCE"
    "-DCF_EXCLUDE_CSTD_HEADERS"
    "-D_FORTIFY_SOURCE=0"
    "-Wno-int-conversion"          # needed for mach/error_codes.c (int-conversion is error since clang 16)
    "-Wno-shorten-64-to-32"
  ];
in

mkDarwinPackage {
  pname = "libsystem_kernel";
  version = lib.removePrefix "xnu-" sources.xnu.rev;

  src = sources.xnu;
  inherit toolchain;

  nativeBuildInputs = [ mig perl ];

  ARCHS = machoArch;

  buildPhase = ''
    runHook preBuild

    export MD_SRCROOT=$PWD
    src=$PWD/libsyscall

    # err_iokit.sub needs unreleased IOKit USB/FireWire headers; guard on __has_include so embedded fallback is used.
    substituteInPlace $src/mach/err_iokit.sub --replace-quiet       '#if !(TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR)'       '#if !(TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR) && __has_include(<IOKit/usb/USB.h>) && __has_include(<IOKit/firewire/IOFireWireLib.h>)'

    obj=$PWD/obj
    mkdir -p $obj/sys $obj/mig $obj/o $obj/xnuinc
    ln -sfn $MD_SRCROOT/osfmk/${machoArch} $obj/xnuinc/${machoArch}
    ln -sfn $MD_SRCROOT/osfmk/kern         $obj/xnuinc/kern

    # Syscall stubs from syscalls.master (one .s per call).
    perl $src/xcodescripts/create-syscalls.pl \
      $PWD/bsd/kern/syscalls.master \
      $src/custom \
      $src/Platforms \
      MacOSX \
      $obj/sys

    if [ ! -s $obj/sys/stubs.list ]; then
      echo "create-syscalls.pl produced no stubs" >&2
      exit 1
    fi
    md_log "generated $(wc -l < $obj/sys/stubs.list) syscall stubs"

    # mig stubs (needs preprocessor from our toolchain).
    cat > $obj/migcc <<MIGCC
    #!/bin/sh
    exec $CC "\$@"
    MIGCC
    chmod +x $obj/migcc
    export MIGCC=$obj/migcc

    for defs in ${lib.concatStringsSep " " defsFiles}; do
      name=$(basename "$defs" .defs)
      # OTHER_MIGFLAGS without -DLIBSYSCALL_INTERFACE so stubs define _kernelrpc_*.
      mig -novouchers -arch ${migArch} -cc "$MIGCC" \
        -DKOBJECT_SERVER \
        -I$PWD/osfmk \
        -user   "$obj/mig/''${name}User.c" \
        -header "$obj/mig/''${name}.h" \
        -server /dev/null \
        "$src/$defs"
    done

    # HEADER_SEARCH_PATHS from Libsyscall.xcconfig + mig outputs + internal headers.
    incflags=(
      -I$src/mach
      -I$src/os
      -I$src/wrappers
      -I$src/wrappers/string
      -I$src/wrappers/libproc
      -I$src/wrappers/libproc/spawn
      # posix_spawn.c and spawn_private.h include <spawn.h>/<spawn_private.h>
      # as angled includes but live next to them.
      -I$src/wrappers/spawn
      -I$obj/mig
      -I$obj/sys
      # Needs <arm64/machine_machdep.h> and <kern/arithmetic_128.h> from kernel tree; expose only those subdirs to avoid shadowing SDK <mach/*.h>.
      -I$obj/xnuinc
      -I$MINIDARWIN_SYSROOT/usr/local/internal_hdr/include
      # SYSTEM_HEADER_SEARCH_PATHS (Libsyscall.xcconfig).
      -iwithsysroot ${systemFrameworkHeaders}
    )

    cflags=(
      ${lib.escapeShellArgs xcconfigCFlags}
      -Os
      # No -g: N_OSO stabs embed absolute build paths, breaking reproducibility.
      "''${incflags[@]}"
    )

    sources=()
    for f in ${lib.concatStringsSep " " codeFiles}; do
      sources+=( "$src/$f" )
    done
    # Generated stubs: stubs.list holds absolute paths, one per line.
    while IFS= read -r s; do sources+=( "$s" ); done < $obj/sys/stubs.list
    for u in $obj/mig/*User.c; do sources+=( "$u" ); done

    md_log "compiling ''${#sources[@]} objects"
    md_compile $obj/o "$CC" "''${cflags[@]}" -- "''${sources[@]}"

    # -umbrella System marks umbrella membership; no deps to link.
    md_dylib libsystem_kernel.dylib \
      /usr/lib/system/libsystem_kernel.dylib \
      $obj/o \
      -Wl,-umbrella,System

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 libsystem_kernel.dylib $out/usr/lib/system/libsystem_kernel.dylib

    md_verify_pure  $out/usr/lib/system/libsystem_kernel.dylib
    md_verify_signed $out/usr/lib/system/libsystem_kernel.dylib
    md_verify_symbols $out/usr/lib/system/libsystem_kernel.dylib \
      _write _read _mmap _open _close _mach_task_self_ _mach_msg \
      _task_info _vm_allocate _mach_absolute_time _syscall

    runHook postInstall
  '';

  meta.description = "xnu Libsyscall -- the kernel interface library";
}
