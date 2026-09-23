# Stage 6: /usr/lib/libncurses.5.4.dylib -- ncurses.xcodeproj target
# `libncurses` (Release, xcodeconfig/libraries.xcconfig), what libedit links for
# termcap. The `libraries` aggregate's other members (libform, libmenu,
# libpanel), the executables (tic, tput, ...), the man pages and the terminfo
# database are not built.
#
# The output is what the rootfs ships: the dylib and link_libs.sh's symlinks.
# What install_headers.sh puts in /usr/include is passthru.headers, for the
# libraries built on top of this one. (Not a second output: stdenv's
# multiple-outputs hook does not survive build-support.sh's `set -u`.)
{ lib
, runCommand
, mkDarwinPackage
, sources
, toolchain
, ncursesGenerated
, publicSdkView
}:

let
  srcs = import ./ncurses-sources.nix;

  builtPrefix = "$(BUILT_PRODUCTS_DIR)/";
  compiledPath = f:
    if lib.hasPrefix builtPrefix f then "BUILT_PRODUCTS_DIR/${lib.removePrefix builtPrefix f}" else f;

  # xcodeconfig/libraries.xcconfig GCC_PREPROCESSOR_DEFINITIONS.
  defines = [
    "HAVE_CONFIG_H"
    "_XOPEN_SOURCE=600"
    "SIGWINCH=28"
    "NDEBUG"
    "_XOPEN_SOURCE_EXTENDED"
    "NCURSES_OPAQUE=0"
    "NCURSES_WANT_BASEABI"
    "_NCURSES_LIBBUILD"
  ];

  # Project OTHER_CFLAGS are -fno-typed-memory-operations-experimental and
  # -fno-typed-cxx-new-delete: Apple clang only, and both turn a feature off.
  cflags = [
    "-std=gnu99" # GCC_C_LANGUAGE_STANDARD
    "-Os"
    "-Werror=format-nonliteral" # WARNING_CFLAGS
  ] ++ publicView;

  # The SDK is unifdef'd -DPRIVATE -UMODULES_SUPPORTED, so its <net/if.h> ends
  # by including <net/if_private.h>, which pulls in <net/if_dl.h>, which uses
  # u_char. Under _XOPEN_SOURCE=600 <sys/types.h> does not define u_char, so
  # anything that includes <sys/ioctl.h> (lib_setup.c, lib_tstp.c, ...) fails.
  # Apple's public SDK has no such include: publicSdkView restores that view.
  publicView = [ "-include" "${publicSdkView}/include/minidarwin/public-sdk-view.h" ];

  # HEADER_SEARCH_PATHS (project).
  includes = [ "BUILT_PRODUCTS_DIR" "ncurses/include" "ncurses/ncurses" "ncurses/progs" ];

  ver = "5.4";

  # Imports nothing in the tree defines yet.
  allowUndefined = {
    "__tlv_bootstrap" = "dyld"; # thread-local _nc_abiver (base/nc_abi.c, Apple's)
  };

  # link_libs.sh
  links = [ "libncurses.dylib" "libcurses.dylib" "libtermcap.dylib" "libncurses.5.dylib" ];

  # install_headers.sh
  headers = [
    "ncurses/include/tic.h"
    "ncurses/menu/eti.h"
    "ncurses/panel/panel.h"
    "ncurses/include/ncurses_dll.h"
    "ncurses/include/unctrl.h"
    "ncurses/include/nc_tparm.h"
    "BUILT_PRODUCTS_DIR/term.h"
    "ncurses/form/form.h"
    "ncurses/include/termcap.h"
    "BUILT_PRODUCTS_DIR/curses.h"
    "ncurses/menu/menu.h"
    "ncurses/include/term_entry.h"
    "BUILT_PRODUCTS_DIR/ncurses.modulemap"
  ];

  # Every header above is in the tarball or ncursesGenerated: none needs the
  # target preprocessor.
  installedHeaders = runCommand "ncurses-headers-${sources.ncurses.rev}" { } ''
    mkdir -p $out/usr/include
    cd ${sources.ncurses}
    for h in ${lib.escapeShellArgs headers}; do
      case $h in
        BUILT_PRODUCTS_DIR/*) h=${ncursesGenerated}/''${h#BUILT_PRODUCTS_DIR/} ;;
      esac
      install -m644 $h $out/usr/include/
    done
    ln -s curses.h $out/usr/include/ncurses.h
  '';
in

mkDarwinPackage {
  pname = "ncurses";
  version = lib.removePrefix "ncurses-" sources.ncurses.rev;

  src = sources.ncurses;
  inherit toolchain;

  passthru.allowUndefined = allowUndefined; # for rootfs closure check
  passthru.headers = installedHeaders;

  buildPhase = ''
    runHook preBuild

    export MD_SRCROOT=$PWD
    mkdir -p BUILT_PRODUCTS_DIR obj
    cp --no-preserve=mode ${ncursesGenerated}/* BUILT_PRODUCTS_DIR/

    # The two derived_sources.sh steps that run the target's preprocessor.
    incdir="-IBUILT_PRODUCTS_DIR -Incurses/ncurses -Incurses/include"
    macros="-DHAVE_CONFIG_H -U_XOPEN_SOURCE -D_XOPEN_SOURCE=600 -D_XOPEN_SOURCE_EXTENDED -DNDEBUG -DSIGWINCH=28 ${toString publicView}"
    sh ncurses/ncurses/tty/MKexpanded.sh "$CC -E" $incdir $macros \
      > BUILT_PRODUCTS_DIR/expanded.c
    sh ncurses/ncurses/base/MKlib_gen.sh "$CC -E -DHAVE_CONFIG $incdir $macros" \
      awk generated < BUILT_PRODUCTS_DIR/curses.h > BUILT_PRODUCTS_DIR/lib_gen.c
    if grep -l "$NIX_BUILD_TOP\|/nix/store" BUILT_PRODUCTS_DIR/expanded.c BUILT_PRODUCTS_DIR/lib_gen.c; then
      echo "ncurses: preprocessor output names a build path" >&2
      exit 1
    fi

    md_compile $PWD/obj "$CC" ${lib.escapeShellArgs cflags} \
      ${lib.escapeShellArgs (map (d: "-D${d}") defines)} \
      ${lib.concatMapStringsSep " " (i: "-I$PWD/${i}") includes} \
      -- ${lib.concatMapStringsSep " " (f: "$PWD/${compiledPath f}") srcs}

    MD_COMPAT_VERSION=${ver} MD_CURRENT_VERSION=${ver} \
      md_dylib libncurses.${ver}.dylib /usr/lib/libncurses.${ver}.dylib obj \
        ${lib.escapeShellArgs (map (s: "-Wl,-U,${s}") (lib.attrNames allowUndefined))} \
        -lSystem

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 libncurses.${ver}.dylib $out/usr/lib/libncurses.${ver}.dylib
    for l in ${lib.escapeShellArgs links}; do
      ln -s libncurses.${ver}.dylib $out/usr/lib/$l
    done

    md_verify_pure   $out/usr/lib/libncurses.${ver}.dylib
    md_verify_signed $out/usr/lib/libncurses.${ver}.dylib
    # What libedit's terminal.c calls.
    md_verify_symbols $out/usr/lib/libncurses.${ver}.dylib \
      _tgetent _tgetflag _tgetnum _tgetstr _tgoto _tputs _setupterm _tigetstr

    runHook postInstall
  '';

  meta.description = "ncurses' libncurses.5.4.dylib, linked against minidarwin's libSystem";
}
