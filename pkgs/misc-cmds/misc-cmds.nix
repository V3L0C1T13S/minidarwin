# Stage 6: misc_cmds targets (see ../cmds/mk-cmds.nix): cal/ncal, calendar,
# tsort, units. Not reproduced: apple-generic versioning's generated
# <tool>_vers.c, as for shell_cmds.
#
# Not built: leave. leave.c names u_int without including <sys/types.h>; only
# Apple's internal SDK supplies it through the headers leave.c does include
# (the public SDK, like ours, does not), and this build does not add a header
# to Apple's source to make up for it.
{ lib
, mkCmds
, sources
, toolchain
, ncurses
, libedit
}:

let
  fbsdid = [ "__FBSDID=__RCSID" ];

  # cal and ncal: the same sources, two products (ncal.c looks at its name).
  # <calendar.h> is ncal's own, found by Xcode's header map.
  ncalLike = {
    defines = fbsdid; # OTHER_CFLAGS = -D__FBSDID=__RCSID
    cflags = [ "-Incal" ];
    # Frameworks phase: libncurses.dylib (term.h: highlighting today).
    libraries = [{ pkg = ncurses; l = "ncurses"; }];
  };

  # sin, cos, ...: libm is libsystem_m, which is absent (absent-members.nix).
  libm = syms: lib.genAttrs (map (s: "_${s}") syms) (_: "system_m");

  # Per target, what differs from the project's Release settings; the
  # attributes are described in mk-cmds.nix.
  tools = {
    cal = ncalLike // {
      man = { "ncal/ncal.1" = "/usr/share/man/man1/cal.1"; }; # the target's script: a copy of ncal.1
    };
    calendar = {
      defines = fbsdid;
      # Moon phases and sun positions (pom.c, sunpos.c); and -a, which runs
      # as every user in turn.
      allowUndefined = libm [ "asin" "atan" "cos" "sin" "tan" ] // {
        "___sincos_stret" = "system_m";
        "_getpwent" = "system_info";
        "_initgroups" = "system_info";
      };
    };
    ncal = ncalLike;
    tsort = { };
    units = {
      libraries = [{ pkg = libedit; l = "edit"; }]; # frameworks phase: libedit.tbd
    };
  };
in

mkCmds {
  pname = "misc_cmds";
  src = sources.misc_cmds;
  inherit toolchain tools;
  sourceLists = import ./misc-cmds-sources.nix;

  # Project-level Release settings (misc_cmds.xcodeproj): no warning flags,
  # definitions or language standard.
  cflags = [
    "-Os" # GCC_OPTIMIZATION_LEVEL (Release default)
    "-Werror=implicit-function-declaration" # GCC_TREAT_IMPLICIT_FUNCTION_DECLARATIONS_AS_ERRORS
  ];
  defines = [ ];
  ldflags = [ "-Wl,-dead_strip" ]; # DEAD_CODE_STRIPPING

  # The copy phases' data files.
  extraInstall = ''
    install -Dm644 calendar/calendars/calendar.apple $out/usr/local/share/calendar/calendar.apple
    install -Dm644 calendar/calendars/calendar.freebsd $out/usr/local/share/calendar/calendar.freebsd
    install -Dm644 units/units.lib $out/usr/share/misc/units.lib
  '';
}
