# Stage 4: LLVM runtimes (libcompiler_rt, libunwind) as umbrella members.
# Force-load archive into dylib; two-pass link checks deps (see umbrella-link.nix).
{ lib
, mkDarwinPackage
, toolchain
, umbrellaLink
  # Which runtime: "compiler_rt" or "unwind".
, name
  # The stage 3 derivation holding the archive.
, runtime
  # Path to the archive inside it.
, archive
, libs ? [ ] # umbrella members resolving archive refs; pass2 -undefined error checks
, allowUndefined ? { }
, symbols ? [ ] # must export; archives have hidden visibility so empty table would be silent failure

, libsystemStage1 ? null
}:

let
  linkFlags = umbrellaLink {
    stage1 = libsystemStage1;
    inherit libs allowUndefined;
  };
in

mkDarwinPackage {
  pname = "lib${name}-dylib-pass${if libsystemStage1 == null then "1" else "2"}";
  version = runtime.version;

  inherit toolchain;
  dontUnpack = true;

  passthru.libsystemName = name;
  passthru.allowUndefined = allowUndefined; # checked by rootfs.nix

  buildPhase = ''
    runHook preBuild

    mkdir -p obj # no .o files; content from force-loaded archive
    md_dylib lib${name}.dylib /usr/lib/system/lib${name}.dylib obj \
      -Wl,-force_load,${runtime}/${archive} \
      ${lib.escapeShellArgs linkFlags}

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 lib${name}.dylib $out/usr/lib/system/lib${name}.dylib
    md_verify_pure   $out/usr/lib/system/lib${name}.dylib
    md_verify_signed $out/usr/lib/system/lib${name}.dylib
    md_verify_symbols $out/usr/lib/system/lib${name}.dylib \
      ${lib.escapeShellArgs symbols}

    runHook postInstall
  '';

  meta.description = "lib${name}.dylib -- ${name} as a libSystem umbrella member";
}
