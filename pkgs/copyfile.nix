# libcopyfile.dylib -- Apple copyfile(3). Private quarantine hooks use no-op
# shims; xattr flag defaults use the unsandboxed table without private XPC.
{ lib
, mkDarwinPackage
, sources
, toolchain
}:

let
  version = lib.removePrefix "copyfile-" sources.copyfile.rev;
  exports = [
    "_copyfile"
    "_copyfile_state_alloc"
    "_copyfile_state_free"
    "_copyfile_state_get"
    "_copyfile_state_set"
    "_fcopyfile"
    "_xattr_flags_from_name"
    "_xattr_intent_with_flags"
    "_xattr_name_with_flags"
    "_xattr_name_without_flags"
    "_xattr_preserve_for_intent"
  ];
in

mkDarwinPackage {
  pname = "libcopyfile";
  inherit version toolchain;
  src = sources.copyfile;

  passthru.installName = "/usr/lib/libcopyfile.dylib";
  passthru.allowUndefined = { };

  buildPhase = ''
    runHook preBuild

    mkdir -p obj
    substituteInPlace xattr_flags.c \
      --replace-fail '#include <xpc/private.h>' '/* MiniDarwin: no private XPC headers. */' \
      --replace-fail '_xpc_runtime_is_app_sandboxed()' '0'

    md_compile $PWD/obj "$CC" -Os -fno-common -fblocks \
      -I${../compat} \
      -- $PWD/copyfile.c $PWD/xattr_flags.c \
        ${../compat}/quarantine-stub.c ${../compat}/dispatch-once.c

    printf '%s\n' ${lib.escapeShellArgs exports} | sort > exports
    md_dylib libcopyfile.dylib /usr/lib/libcopyfile.dylib obj \
      -Wl,-dead_strip \
      -Wl,-exported_symbols_list,$PWD/exports \
      -lSystem

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 libcopyfile.dylib $out/usr/lib/libcopyfile.dylib
    ln -s libcopyfile.dylib $out/usr/lib/libcopyfile.1.dylib
    md_verify_pure $out/usr/lib/libcopyfile.dylib
    md_verify_signed $out/usr/lib/libcopyfile.dylib

    runHook postInstall
  '';

  meta.description = "Apple copyfile library, without private quarantine support";
}
