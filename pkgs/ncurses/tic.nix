# tic_static: ncurses.xcodeproj's native `tic_static` target, which
# run_tic.sh's aggregate builds for the build machine to compile the terminfo
# database. Host world, never shipped. Its sources are libncurses' plus the
# generated ones, all target-independent (see ncurses-generated.nix).
{ lib, stdenv, sources, ncursesGenerated }:

let
  srcs = import ./tic-sources.nix;
  builtPrefix = "$(BUILT_PRODUCTS_DIR)/";
  compiledPath = f:
    if lib.hasPrefix builtPrefix f then "gen/${lib.removePrefix builtPrefix f}" else f;
in

stdenv.mkDerivation {
  pname = "ncurses-tic-static";
  version = lib.removePrefix "ncurses-" sources.ncurses.rev;

  src = sources.ncurses;
  strictDeps = true;

  buildPhase = ''
    runHook preBuild

    mkdir -p gen
    cp --no-preserve=mode ${ncursesGenerated}/* gen/

    # The target's GCC_PREPROCESSOR_DEFINITIONS, and the project's
    # HEADER_SEARCH_PATHS with BUILT_PRODUCTS_DIR first.
    $CC -std=gnu99 -O2 -Wl,-dead_strip \
      -DHAVE_CONFIG_H -D_XOPEN_SOURCE=600 -D_XOPEN_SOURCE_EXTENDED \
      -Igen -Incurses/include -Incurses/ncurses -Incurses/progs \
      -o tic_static ${lib.concatMapStringsSep " " compiledPath srcs}

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 tic_static $out/bin/tic_static
    runHook postInstall
  '';

  meta = {
    description = "ncurses' tic, for the build machine (compiles the terminfo database)";
    platforms = lib.platforms.darwin;
  };
}
