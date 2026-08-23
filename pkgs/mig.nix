# mig / migcom: host tool that generates Mach IPC stubs (built with nixpkgs stdenv, not shipped).
{ lib, stdenv, sources, bison, flex }:

stdenv.mkDerivation {
  pname = "mig";
  version = lib.removePrefix "bootstrap_cmds-" sources.bootstrap_cmds.rev;

  src = sources.bootstrap_cmds;

  nativeBuildInputs = [ bison flex ];

  strictDeps = true;

  buildPhase = ''
    runHook preBuild

    cd migcom.tproj

    bison -y -d parser.y
    flex  -o lexxer.c lexxer.l

    # Sources from Xcode target (handler.c excluded -- dead code). Pin MIG_VERSION for reproducibility.
    $CC -O2 -std=gnu17 \
      -DMIG_VERSION='"bootstrap_cmds-'"$version"'"' \
      -Wno-implicit-function-declaration \
      -Wno-int-conversion \
      -Wno-incompatible-pointer-types \
      -Wno-deprecated-non-prototype \
      -I. -I${sources.xnu}/osfmk \
      -o migcom \
      y.tab.c lexxer.c \
      error.c global.c header.c mig.c routine.c server.c \
      statement.c string.c type.c user.c utils.c

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/libexec $out/share/man/man1

    # Keep mig.sh's expected layout (../libexec/migcom).
    install -m0755 migcom       $out/libexec/migcom
    install -m0755 mig.sh       $out/bin/mig
    install -m0644 mig.1        $out/share/man/man1/mig.1
    install -m0644 migcom.1     $out/share/man/man1/migcom.1

    # Make MIGCC mandatory (no xcrun fallback).
    substituteInPlace $out/bin/mig \
      --replace-fail 'xcrunPath="/usr/bin/xcrun"' \
        'echo "mig: MIGCC must be set (no xcrun in a pure build)" >&2; exit 1; xcrunPath="/nonexistent"'

    patchShebangs $out/bin/mig

    runHook postInstall
  '';

  meta = {
    description = "Mach Interface Generator (build-time only)";
    platforms = lib.platforms.darwin;
  };
}
