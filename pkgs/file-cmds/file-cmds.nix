# Stage 6: file_cmds targets (see ../cmds/mk-cmds.nix).
# Not reproduced: apple-generic versioning's generated <tool>_vers.c, as for
# shell_cmds; and the targets' Copy Test Files phases (/AppleInternal/Tests).
{ mkCmds
, sources
, toolchain
, libutil
, ncurses
}:

let
  defines = [ "__FBSDID=__RCSID" "_DARWIN_USE_64_BIT_INODE" ]; # GCC_PREPROCESSOR_DEFINITIONS

  # xattr and truncate: targets from Xcode's newer template, which set these.
  modernCflags = [
    "-std=gnu11" # GCC_C_LANGUAGE_STANDARD
    "-Wshorten-64-to-32" # GCC_WARN_64_TO_32_BIT_CONVERSION
    "-Werror=return-type" # GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR
    "-Wconditional-uninitialized" # GCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE
  ];

  # Per target, what differs from the project's Release settings; the
  # attributes are described in mk-cmds.nix.
  tools = {
    chflags = { };
    chmod = {
      installDir = "/bin";
      # +a/-a: an ACL entry's user or group name to its UUID.
      allowUndefined."_mbr_identifier_to_uuid" = "system_info";
    };
    chown = {
      installDir = "/usr/sbin";
      man = { "chown/chown.8" = "/usr/share/man/man8/chown.8"; };
      # Owner and group given by name.
      allowUndefined = {
        "_getgrnam" = "system_info";
        "_getpwnam" = "system_info";
      };
    };
    cp = {
      installDir = "/bin";
      # Regular files are copied by fcopyfile() (data, then xattrs and ACLs
      # by copyfile's state), so without libcopyfile cp can make only
      # directories, links and special files.
      allowUndefined = {
        "_copyfile_state_alloc" = "copyfile";
        "_copyfile_state_free" = "copyfile";
        "_copyfile_state_get" = "copyfile";
        "_copyfile_state_set" = "copyfile";
        "_fcopyfile" = "copyfile";
      };
    };
    du = { libraries = [{ pkg = libutil; l = "util"; }]; };
    ln = {
      installDir = "/bin";
      man = {
        "ln/ln.1" = "/usr/share/man/man1/ln.1";
        "ln/symlink.7" = "/usr/share/man/man7/symlink.7";
      };
    };
    ls = {
      installDir = "/bin";
      defines = defines ++ [ "COLORLS" ];
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
    mkdir = { installDir = "/bin"; };
    mv = {
      installDir = "/bin";
      allowUndefined = {
        # Across file systems, fastcopy() copies the data itself, then
        # fcopyfile() the ACL and xattrs.
        "_fcopyfile" = "copyfile";
        # The prompt before overwriting a target it cannot write names its
        # owner and group.
        "_group_from_gid" = "system_info";
        "_user_from_uid" = "system_info";
      };
    };
    stat = {
      defines = defines ++ [ "HAVE_CONFIG_H=0" ];
      # %Su, %Sg: owner and group names.
      allowUndefined = {
        "_group_from_gid" = "system_info";
        "_user_from_uid" = "system_info";
      };
    };
    truncate = {
      cflags = modernCflags;
      libraries = [{ pkg = libutil; l = "util"; }]; # OTHER_LDFLAGS = -lutil
    };
    xattr = { cflags = modernCflags; };
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
    # Not Apple's: LLVM 21's -Wall includes -Wunused-but-set-variable, and
    # -Werror makes it fatal. The variables are dead, not misused: ls.c's
    # labelstr is read only by FreeBSD's MAC label code (#ifndef __APPLE__),
    # chmod_acl.c's aindex counts loop iterations nothing reads.
    "-Wno-error=unused-but-set-variable"
  ];
  inherit defines;
  ldflags = [ "-Wl,-dead_strip" ]; # DEAD_CODE_STRIPPING
}
