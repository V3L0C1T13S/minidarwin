# Stage 4: libsystem_blocks.dylib (libclosure) - Blocks runtime (_Block_copy, _NSConcrete*Block).
# HAVE_OBJC=0 (only config buildable without objc4); two-pass link (see umbrella-link.nix).
{ lib
, mkDarwinPackage
, sources
, toolchain
, umbrellaLink
, libsystemStage1 ? null
}:

let
  # OTHER_LDFLAGS from Blocks.xcconfig minus ObjC/dyld (stage 5).
  linkFlags = umbrellaLink {
    stage1 = libsystemStage1;
    libs = [ "system_platform" "system_malloc" "unwind" "compiler_rt" ];
    upward = [ "system_c" ]; # back-edge to libsystem_c
  };

  cflags = [
    "-DHAVE_OBJC=0"
    "-DHAVE_UNWIND=1" # enables generic_helpers.c and requires -fexceptions
    "-fexceptions"
    "-Os"
  ];

  version = lib.removePrefix "libclosure-" sources.libclosure.rev;

  # Independent of libsystemStage1, so both passes share this one derivation.
  objects = mkDarwinPackage {
    pname = "libsystem_blocks-objects";
    inherit version toolchain;

    src = sources.libclosure;
    buildPhase = ''
      runHook preBuild

      export MD_SRCROOT=$PWD
      obj=$PWD/o
      mkdir -p $obj

      md_compile $obj "$CXX" ${lib.escapeShellArgs cflags} -- \
        $PWD/runtime.cpp
      md_compile $obj "$CC" ${lib.escapeShellArgs cflags} -- \
        $PWD/data.c $PWD/data.m $PWD/generic_helpers.c

      runHook postBuild
    '';

    installPhase = "cp -R $obj $out";
  };
in

mkDarwinPackage {
  pname = "libsystem_blocks-pass${if libsystemStage1 == null then "1" else "2"}";
  inherit version toolchain;
  dontUnpack = true;

  passthru.libsystemName = "system_blocks";
  passthru.objects = objects;

  buildPhase = ''
    runHook preBuild

    md_dylib libsystem_blocks.dylib /usr/lib/system/libsystem_blocks.dylib ${objects} \
      ${lib.escapeShellArgs linkFlags}

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 libsystem_blocks.dylib \
      $out/usr/lib/system/libsystem_blocks.dylib

    md_verify_pure   $out/usr/lib/system/libsystem_blocks.dylib
    md_verify_signed $out/usr/lib/system/libsystem_blocks.dylib

    md_verify_symbols $out/usr/lib/system/libsystem_blocks.dylib \
      __Block_copy __Block_release __Block_object_assign __Block_object_dispose \
      __NSConcreteStackBlock __NSConcreteMallocBlock __NSConcreteAutoBlock \
      __NSConcreteFinalizingBlock __NSConcreteGlobalBlock \
      __NSConcreteWeakBlockVariable

    runHook postInstall
  '';

  meta.description = "libclosure -- the Blocks runtime";
}
