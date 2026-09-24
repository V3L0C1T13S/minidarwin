# Stage 6: ncurses.xcodeproj's executables (xcodeconfig/executables.xcconfig),
# through ../cmds/mk-cmds.nix: clear, tput, tset, infocmp, toe and tic, each
# linked against libncurses.5.4.dylib as its frameworks phase says. The
# `executables` aggregate's fix_bin.sh is reproduced: its reset, captoinfo and
# infotocap symlinks, and ncurses5.4-config.
#
# Their man pages are not installed: install_man_misc.sh installs all of
# ncurses' pages at once, with hundreds of hardlinked aliases, and is not run
# here (see ncurses.nix).
{ lib
, mkCmds
, sources
, toolchain
, ncurses
, ncursesGenerated
}:

let
  common = {
    libraries = [{ pkg = ncurses; l = "ncurses"; }]; # frameworks phase
    builtProducts = ncursesGenerated; # term.h, curses.h, termsort.c, ...
    man = { };
  };

  tools = {
    clear = common;
    infocmp = common;
    tic = common // {
      links = {
        "/usr/bin/captoinfo" = "/usr/bin/tic";
        "/usr/bin/infotocap" = "/usr/bin/tic";
      };
    };
    toe = common;
    tput = common;
    tset = common // {
      links."/usr/bin/reset" = "/usr/bin/tset";
      # Defined by libdyld; see shell_cmds' find.
      allowUndefined."_environ" = "dyld";
    };
  };
in

mkCmds {
  pname = "ncurses-tools";
  version = lib.removePrefix "ncurses-" sources.ncurses.rev;
  src = sources.ncurses;
  inherit toolchain tools;
  sourceLists = import ./ncurses-tools-sources.nix;

  # Project-level Release settings and executables.xcconfig. The project's
  # OTHER_CFLAGS are Apple clang only, and both turn a feature off (ncurses.nix).
  cflags = [
    "-std=gnu99" # GCC_C_LANGUAGE_STANDARD
    "-Os"
    "-Werror=format-nonliteral" # WARNING_CFLAGS
    # HEADER_SEARCH_PATHS
    "-IBUILT_PRODUCTS_DIR"
    "-Incurses/include"
    "-Incurses/ncurses"
    "-Incurses/progs"
  ];
  defines = [ ];
  ldflags = [ "-Wl,-dead_strip" ]; # DEAD_CODE_STRIPPING (Release default)

  # fix_bin.sh's config script.
  extraInstall = ''
    install -Dm755 ncurses/misc/ncurses-config $out/usr/bin/ncurses5.4-config
  '';
}
