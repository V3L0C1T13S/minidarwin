# Stage 6: awk.xcodeproj target `awk` -- the one true awk, as /usr/bin/awk
# (see ../cmds/mk-cmds.nix). Its yacc output (src/awkgram.tab.c) and
# proctab.c are checked in, and compiled as they are. The script phase's
# OpenSourceVersions/OpenSourceLicenses files are not installed.
{ lib
, mkCmds
, sources
, toolchain
}:

mkCmds {
  pname = "awk";
  src = sources.awk;
  inherit toolchain;
  sourceLists = import ./awk-sources.nix;

  tools.awk = {
    man = { "src/awk.1" = "/usr/share/man/man1/awk.1"; }; # the script phase
    allowUndefined =
      # atan2(), cos(), exp(), ...: libm is libsystem_m, which is absent
      # (absent-members.nix).
      lib.genAttrs (map (s: "_${s}") [ "atan2" "cos" "exp" "log" "modf" "pow" "sin" ]) (_: "system_m")
      // { "_environ" = "dyld"; }; # ENVIRON; see shell_cmds' find
  };

  # Project-level Release settings (awk.xcodeproj): no language standard or
  # definitions.
  cflags = [
    "-Os" # GCC_OPTIMIZATION_LEVEL (Release default)
    "-Werror=format-nonliteral" # WARNING_CFLAGS
  ];
  defines = [ ];
  ldflags = [ "-Wl,-dead_strip" ]; # DEAD_CODE_STRIPPING (Release default)
}
