# Stage 4: libmacho.dylib (cctools) - section lookup, swapping, NXGetArchInfo.
# Only cctools code used; rest replaced by LLVM toolchain.
{ lib
, mkDarwinPackage
, sources
, toolchain
, umbrellaLink
, targetArch
, libsystemStage1 ? null
}:

let
  # dyld image introspection (stage 5).
  allowUndefined = {
    "__dyld_get_image_header" = "dyld";
    "__dyld_get_image_name" = "dyld";
    "__dyld_get_image_vmaddr_slide" = "dyld";
    "__dyld_image_count" = "dyld";
  };

  linkFlags = umbrellaLink {
    stage1 = libsystemStage1;
    # LIBMACHO_DYLIBS minus dyld (stage 5); +system_platform for strcmp (see libsystem-platform.nix).
    libs = [ "system_platform" ];
    upward = [ "compiler_rt" "system_malloc" "system_c" "system_kernel" ]
      ++ lib.optional (targetArch != "aarch64") "system_pthread"; # x86_64 only
    inherit allowUndefined;
  };

  cflags = [
    "-Os"
    "-fno-common"
    "-fapplication-extension" # APPLICATION_EXTENSION_API_ONLY=YES
  ];

  # Sources of "macho dynamic" target (ofileList is stale - includes missing m68k/sparc/ppc).
  codeFiles = [
    "libmacho/arch.c"
    "libmacho/get_end.c"
    "libmacho/getsecbyname.c"
    "libmacho/getsegbyname.c"
    "libmacho/i386_swap.c"
    "libmacho/slot_name.c"
    "libmacho/swap.c"
  ];
in

mkDarwinPackage {
  pname = "libmacho-pass${if libsystemStage1 == null then "1" else "2"}";
  version = lib.removePrefix "cctools-" sources.cctools.rev;

  src = sources.cctools;
  inherit toolchain;

  passthru.libsystemName = "macho";
  passthru.allowUndefined = allowUndefined; # checked by rootfs.nix

  buildPhase = ''
    runHook preBuild

    export MD_SRCROOT=$PWD
    obj=$PWD/o
    mkdir -p $obj

    sources=()
    for f in ${lib.concatStringsSep " " codeFiles}; do
      sources+=( "$PWD/$f" )
    done

    md_log "libmacho: ''${#sources[@]} objects"
    md_compile $obj "$CC" ${lib.escapeShellArgs cflags} \
      -I$PWD/include -- "''${sources[@]}"

    md_dylib libmacho.dylib /usr/lib/system/libmacho.dylib $obj \
      -Wl,-application_extension \
      ${lib.escapeShellArgs linkFlags}

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 libmacho.dylib $out/usr/lib/system/libmacho.dylib

    md_verify_pure   $out/usr/lib/system/libmacho.dylib
    md_verify_signed $out/usr/lib/system/libmacho.dylib

    md_verify_symbols $out/usr/lib/system/libmacho.dylib \
      _getsectbyname _getsectdatafromheader_64 _getsegbyname \
      _getsectiondata _getsegmentdata \
      _get_end _get_etext _get_edata \
      _NXGetArchInfoFromName _NXGetArchInfoFromCpuType \
      _swap_mach_header_64 _swap_load_command

    runHook postInstall
  '';

  meta.description = "cctools libmacho -- Mach-O section lookup and swapping";
}
