# Stage 4: libsystem_collections.dylib - Libc collections (intrusive hash map/set).
# Separate target from libsystem_c; headers install to /usr/local/include/os.
{ lib
, mkDarwinPackage
, sources
, toolchain
, umbrellaLink
, libsystemStage1 ? null
}:

let
  linkFlags = umbrellaLink {
    stage1 = libsystemStage1;
    # OTHER_LDFLAGS from collections.xcconfig minus dyld; plus system_platform for strcmp (see libsystem-platform.nix).
    libs = [ "compiler_rt" "system_kernel" "system_malloc" "system_c" "system_blocks" "system_platform" ];
  };

  cflags = [
    "-std=gnu11"
    "-Os"
    "-fno-common"
    "-fstrict-aliasing"
    "-fno-exceptions"
    "-fverbose-asm"
    "-fvisibility=hidden" # only OS_EXPORT symbols should be exported
    "-Werror"
    "-Wno-nullability-completeness" # included .in.c files use macro-expanded pointer types
  ];

  codeFiles = [
    "collections/Source/collections_map.c"
    "collections/Source/collections_set.c"
  ];
in

mkDarwinPackage {
  pname = "libsystem_collections-pass${if libsystemStage1 == null then "1" else "2"}";
  version = lib.removePrefix "Libc-" sources.Libc.rev;

  src = sources.Libc;
  inherit toolchain;

  passthru.libsystemName = "system_collections";

  buildPhase = ''
    runHook preBuild

    export MD_SRCROOT=$PWD
    obj=$PWD/o
    mkdir -p $obj

    sources=()
    for f in ${lib.concatStringsSep " " codeFiles}; do
      sources+=( "$PWD/$f" )
    done

    md_log "collections: ''${#sources[@]} objects"
    md_compile $obj "$CC" ${lib.escapeShellArgs cflags} \
      -I$PWD/collections/PublicHeader -- "''${sources[@]}"

    md_dylib libsystem_collections.dylib \
      /usr/lib/system/libsystem_collections.dylib $obj \
      ${lib.escapeShellArgs linkFlags}

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 libsystem_collections.dylib \
      $out/usr/lib/system/libsystem_collections.dylib

    md_verify_pure   $out/usr/lib/system/libsystem_collections.dylib
    md_verify_signed $out/usr/lib/system/libsystem_collections.dylib

    md_verify_symbols $out/usr/lib/system/libsystem_collections.dylib \
      _os_map_32_init _os_map_64_init _os_map_str_init _os_map_128_init \
      _os_map_64_insert _os_map_64_find _os_map_64_delete _os_map_64_destroy \
      _os_map_str_insert _os_map_str_find _os_map_str_delete \
      _os_set_32_ptr_init _os_set_64_ptr_init _os_set_str_ptr_init \
      _os_set_64_ptr_insert _os_set_64_ptr_find _os_set_64_ptr_delete \
      _os_set_64_ptr_destroy

    runHook postInstall
  '';

  meta.description = "Libc collections -- the system hash map and hash set";
}
