# What ncurses.xcodeproj's "Bootstrap Sources" and "Derived Sources" targets
# write to BUILT_PRODUCTS_DIR, less the two files that need the target's
# preprocessor (expanded.c, lib_gen.c -- ncurses.nix makes those). Host world:
# make_hash and make_keys are compiled and run here, as native_execs.sh builds
# them for the build machine. Everything comes from include/Caps, so nothing
# here depends on the target arch.
{ lib, stdenv, sources, unifdef }:

stdenv.mkDerivation {
  pname = "ncurses-generated";
  version = lib.removePrefix "ncurses-" sources.ncurses.rev;

  src = sources.ncurses;

  nativeBuildInputs = [ unifdef ];
  strictDeps = true;

  buildPhase = ''
    runHook preBuild

    # Relative, because some generators print their own path into the output.
    export PROJECT_DIR=. BUILT_PRODUCTS_DIR=gen PLATFORM_NAME=macosx
    mkdir -p gen

    # "Bootstrap Sources": curses.h, hashsize.h, ncurses_def.h, term.h, names.c.
    sh xcodescripts/bootstrap_headers.sh
    sh xcodescripts/bootstrap_sources.sh

    # native_make_hash / native_make_keys (their targets' settings, plus the
    # project's HEADER_SEARCH_PATHS). -dead_strip is Xcode's Release default,
    # and make_hash needs it: comp_hash.c's lookups call table getters that
    # live in the library, and make_hash never calls the lookups.
    inc="-Igen -Incurses/include -Incurses/ncurses -Incurses/progs"
    $CC -std=gnu99 -Wl,-dead_strip $inc -DMAIN_PROGRAM -D_XOPEN_SOURCE_EXTENDED \
      -D_DARWIN_C_SOURCE=_DARWIN_C_SOURCE -o gen/make_hash \
      ncurses/ncurses/tinfo/comp_hash.c ncurses/ncurses/tinfo/make_hash.c
    $CC -std=gnu99 -Wl,-dead_strip $inc -D_XOPEN_SOURCE_EXTENDED \
      -D_DARWIN_C_SOURCE=_DARWIN_C_SOURCE -o gen/make_keys \
      ncurses/ncurses/tinfo/make_keys.c

    # "Derived Sources", headers: run as is.
    sh xcodescripts/derived_headers.sh

    # "Derived Sources", sources: derived_sources.sh starts with xcrun, so its
    # steps are repeated here, minus expanded.c and lib_gen.c.
    caps=ncurses/include/Caps
    awk -f ncurses/ncurses/tinfo/MKcodes.awk bigstrings=1 $caps > gen/codes.c
    (cd gen && sh ../ncurses/ncurses/tinfo/MKcaptab.sh awk 1 \
      ../ncurses/ncurses/tinfo/MKcaptab.awk ../$caps) > gen/comp_captab.c
    # No fallback entries: the Xcode build names none.
    sh ncurses/ncurses/tinfo/MKfallback.sh /usr/share/terminfo \
      ncurses/misc/terminfo.src > gen/fallback.c
    awk -f ncurses/ncurses/base/MKkeyname.awk bigstrings=1 gen/keys.list > gen/lib_keyname.c
    awk -f ncurses/ncurses/tinfo/MKnames.awk bigstrings=1 < $caps > gen/names.c
    sh ncurses/progs/MKtermsort.sh awk $caps > gen/termsort.c
    echo | awk -f ncurses/ncurses/base/MKunctrl.awk bigstrings=1 > gen/unctrl.c

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    rm gen/make_hash gen/make_keys
    mkdir -p $out
    cp gen/* $out/
    # Generated text must not name the build directory or the store.
    if grep -l "$NIX_BUILD_TOP\|/nix/store" $out/*; then
      echo "ncurses-generated: output names a build path" >&2
      exit 1
    fi

    runHook postInstall
  '';

  meta = {
    description = "Generated sources for ncurses' libncurses (build-time only)";
    platforms = lib.platforms.darwin;
  };
}
