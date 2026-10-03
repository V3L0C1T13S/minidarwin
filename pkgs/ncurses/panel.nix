# ncurses.xcodeproj's libpanel target, used by top's interactive display.
{ lib, mkDarwinPackage, sources, toolchain, ncurses, ncursesGenerated }:

mkDarwinPackage {
  pname = "ncurses-panel";
  version = lib.removePrefix "ncurses-" sources.ncurses.rev;
  src = sources.ncurses;
  inherit toolchain;

  passthru.headers = ncurses.headers;
  passthru.installName = "/usr/lib/libpanel.5.4.dylib";

  buildPhase = ''
    runHook preBuild
    export MD_SRCROOT=$PWD
    mkdir -p BUILT_PRODUCTS_DIR obj
    cp --no-preserve=mode ${ncursesGenerated}/* BUILT_PRODUCTS_DIR/
    md_compile $PWD/obj "$CC" -std=gnu99 -Os -Werror=format-nonliteral \
      -DHAVE_CONFIG_H -D_XOPEN_SOURCE=600 -DSIGWINCH=28 -DNDEBUG \
      -D_XOPEN_SOURCE_EXTENDED -DNCURSES_OPAQUE=0 -DNCURSES_WANT_BASEABI \
      -D_NCURSES_LIBBUILD -IBUILT_PRODUCTS_DIR -Incurses/include \
      -Incurses/ncurses -Incurses/panel \
      -- ${lib.concatMapStringsSep " " (f: "$PWD/${f}") (import ./panel-sources.nix)}
    MD_COMPAT_VERSION=5.4 MD_CURRENT_VERSION=5.4 \
      md_dylib libpanel.5.4.dylib /usr/lib/libpanel.5.4.dylib obj \
        -L${ncurses}/usr/lib -lncurses -lSystem
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 libpanel.5.4.dylib $out/usr/lib/libpanel.5.4.dylib
    ln -s libpanel.5.4.dylib $out/usr/lib/libpanel.dylib
    ln -s libpanel.5.4.dylib $out/usr/lib/libpanel.5.dylib
    md_verify_pure $out/usr/lib/libpanel.5.4.dylib
    md_verify_signed $out/usr/lib/libpanel.5.4.dylib
    md_verify_symbols $out/usr/lib/libpanel.5.4.dylib \
      _new_panel _del_panel _move_panel _update_panels
    runHook postInstall
  '';

  meta.description = "ncurses panel library, linked against MiniDarwin's ncurses and libSystem";
}
