# Stage 6: file_cmds targets (see ../cmds/mk-cmds.nix). So far only ls.
# Not reproduced: apple-generic versioning's generated <tool>_vers.c, as for
# shell_cmds; and the targets' Copy Test Files phases (/AppleInternal/Tests).
{ mkCmds
, sources
, toolchain
, libutil
, ncurses
}:

let
  # Per target, what differs from the project's Release settings; the
  # attributes are described in mk-cmds.nix.
  tools = {
    ls = {
      installDir = "/bin";
      defines = [ "__FBSDID=__RCSID" "_DARWIN_USE_64_BIT_INODE" "COLORLS" ];
      # labelstr and maxlabelstr are only read by FreeBSD's MAC label code,
      # which ls.c compiles out (#ifndef __APPLE__); this clang's -Wall warns,
      # and the project's -Werror would make that fatal.
      cflags = [ "-Wno-error=unused-but-set-variable" ];
      # Frameworks phase: libutil.dylib (humanize_number, for -h) and
      # libcurses.dylib (termcap, for -G), which is libncurses' symlink.
      libraries = [
        { pkg = libutil; l = "util"; }
        { pkg = ncurses; l = "curses"; }
      ];
      allowUndefined = {
        # -l, -n, -o, -g: owner and group names.
        "_group_from_gid" = "system_info";
        "_user_from_uid" = "system_info";
        # -e: ACL entries name their user or group by UUID.
        "_mbr_identifier_translate" = "system_info";
      };
    };
  };
in

mkCmds {
  pname = "file_cmds";
  src = sources.file_cmds;
  inherit toolchain tools;
  sourceLists = import ./file-cmds-sources.nix;

  # Project-level Release settings (file_cmds.xcodeproj). No
  # GCC_C_LANGUAGE_STANDARD: the compiler's default.
  cflags = [
    "-Os" # GCC_OPTIMIZATION_LEVEL (Release default)
    "-fno-common" # GCC_NO_COMMON_BLOCKS
    "-Wall"
    "-Werror=format-nonliteral"
    "-Werror=format"
    "-Werror"
    "-Wundef" # WARNING_CFLAGS
  ];
  defines = [ "__FBSDID=__RCSID" "_DARWIN_USE_64_BIT_INODE" ]; # GCC_PREPROCESSOR_DEFINITIONS
  ldflags = [ "-Wl,-dead_strip" ]; # DEAD_CODE_STRIPPING
}
