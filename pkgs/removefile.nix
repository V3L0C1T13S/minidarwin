# libremovefile.dylib -- Apple removefile(3).
{ lib
, mkDarwinPackage
, sources
, toolchain
}:

let
  version = lib.removePrefix "removefile-" sources.removefile.rev;
  sourcesToCompile = [
    "removefile.c"
    "removefile_random.c"
    "removefile_rename_unlink.c"
    "removefile_sunlink.c"
    "removefile_tree_walker.c"
  ];
  exports = [
    "_removefile"
    "_removefileat"
    "_removefile_cancel"
    "_removefile_state_alloc"
    "_removefile_state_free"
    "_removefile_state_get"
    "_removefile_state_set"
  ];
in

mkDarwinPackage {
  pname = "libremovefile";
  inherit version toolchain;
  src = sources.removefile;

  passthru.installName = "/usr/lib/libremovefile.dylib";
  passthru.allowUndefined = { };

  buildPhase = ''
    runHook preBuild

    export MD_SRCROOT=$PWD
    mkdir -p obj
    # APFS's private fsctl header is not in the pinned open SDK. The optional
    # clear-purgeable path cannot be built without it.
    substituteInPlace removefile_tree_walker.c \
      --replace-fail '#if __APPLE__ && !TARGET_OS_SIMULATOR' '#if 0'
    md_compile $PWD/obj "$CC" -Os -fno-common -- \
      ${lib.concatMapStringsSep " " (f: "$PWD/${f}") sourcesToCompile} \
      ${./compat}/getiopolicy-stub.c

    printf '%s\n' ${lib.escapeShellArgs exports} | sort > exports
    md_dylib libremovefile.dylib /usr/lib/libremovefile.dylib obj \
      -Wl,-dead_strip \
      -Wl,-exported_symbols_list,$PWD/exports \
      -lSystem

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 libremovefile.dylib $out/usr/lib/libremovefile.dylib
    ln -s libremovefile.dylib $out/usr/lib/libremovefile.1.dylib
    md_verify_pure $out/usr/lib/libremovefile.dylib
    md_verify_signed $out/usr/lib/libremovefile.dylib

    runHook postInstall
  '';

  meta.description = "Apple removefile library";
}
