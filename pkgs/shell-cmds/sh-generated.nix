# The seven files shell_cmds' `sh` target writes to BUILT_PRODUCTS_DIR before
# compiling: builtins.{c,h}, nodes.{c,h}, syntax.{c,h}, token.h. Host world --
# mknodes and mksyntax are compiled and run here, as the target's script phases
# do with `xcrun -sdk macosx cc`. Their output is text naming no host type
# (mksyntax writes CHAR_MIN/CHAR_MAX symbolically), so it serves either arch.
{ lib, stdenv, sources }:

stdenv.mkDerivation {
  pname = "shell_cmds-sh-generated";
  version = lib.removePrefix "shell_cmds-" sources.shell_cmds.rev;

  src = sources.shell_cmds;

  strictDeps = true;

  buildPhase = ''
    runHook preBuild

    # mkbuiltins and mktokens do `mktemp -t ka`: BSD reads that as a prefix,
    # GNU wants at least three X's in it.
    mkdir -p shim
    cat > shim/mktemp <<EOF
    #!${stdenv.shell}
    [ "\$*" = "-t ka" ] || { echo "mktemp shim: unexpected \$*" >&2; exit 1; }
    exec $(command -v mktemp) -t ka.XXXXXX
    EOF
    chmod +x shim/mktemp

    mkdir gen tools
    $CC -o tools/mknodes  sh/mknodes.c
    $CC -o tools/mksyntax sh/mksyntax.c

    # The four script phases, in the target's order.
    (cd gen && PATH=../shim:$PATH sh ../sh/mkbuiltins ../sh)
    (cd gen && ../tools/mknodes ../sh/nodetypes ../sh/nodes.c.pat)
    (cd gen && ../tools/mksyntax)
    (cd gen && PATH=../shim:$PATH sh ../sh/mktokens)

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    for f in builtins.c builtins.h nodes.c nodes.h syntax.c syntax.h token.h; do
      install -Dm644 gen/$f $out/$f
    done

    runHook postInstall
  '';

  meta = {
    description = "Generated sources for shell_cmds' sh (build-time only)";
    platforms = lib.platforms.darwin;
  };
}
