# Stage 6: the first userland -- shell_cmds targets (see ../cmds/mk-cmds.nix).
# Not reproduced: apple-generic versioning's generated <tool>_vers.c (the
# __<tool>VersionString symbol), which nothing references; and the "All"
# aggregate's install-files.sh, which hardlinks id to groups and whoami.
{ mkCmds
, sources
, toolchain
, shGenerated
, libedit
, bison
}:

let
  # Per target, what differs from the project's Release settings; the
  # attributes are described in mk-cmds.nix.
  tools = {
    echo = { installDir = "/bin"; };
    false = { };
    find = {
      defines = [ "__FBSDID=__RCSID" "_DARWIN_USE_64_BIT_INODE" ];
      allowUndefined = {
        # -exec's execvp inherits it. Defined by libdyld (libdyldGlue.cpp),
        # which also carries the executable's NXArgv and __progname.
        "_environ" = "dyld";
        # -user, -group, -nouser, -nogroup, -ls.
        "_getgrnam" = "system_info";
        "_getpwnam" = "system_info";
        "_group_from_gid" = "system_info";
        "_user_from_uid" = "system_info";
      };
    };
    hostname = { installDir = "/bin"; };
    id = {
      defines = [ "__FBSDID=__RCSID" "USE_BSM_AUDIT" ];
      man = {
        "id/groups.1" = "/usr/share/man/man1/groups.1";
        "id/id.1" = "/usr/share/man/man1/id.1";
        "id/whoami.1" = "/usr/share/man/man1/whoami.1";
      };
      allowUndefined = {
        "_getgrgid" = "system_info";
        "_getgrouplist_2" = "system_info";
        "_getpwnam" = "system_info";
        "_getpwuid" = "system_info";
      };
    };
    pwd = { installDir = "/bin"; };
    realpath = { installDir = "/bin"; };
    # xcconfigs/sh.xcconfig: installed as ash (its TODO is to become /bin/sh).
    sh = {
      installDir = "/usr/local/bin";
      product = "ash";
      defines = [ "SHELL" ];
      includes = [ "BUILT_PRODUCTS_DIR" "sh" ];
      libraries = [{ pkg = libedit; l = "edit"; }]; # OTHER_LDFLAGS = -ledit
      cflags = [
        "-Werror=incompatible-pointer-types" # GCC_TREAT_INCOMPATIBLE_POINTER_TYPE_WARNINGS_AS_ERRORS
        "-Werror=return-type" # GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR
      ];
      builtProducts = shGenerated;
      man = { "sh/sh.1" = "/usr/local/share/man/man1/ash.1"; };
      allowUndefined = {
        "_environ" = "dyld"; # see find
        "_getpwnam" = "system_info"; # ~user expansion
      };
    };
    true = { };
    uname = { };
    who = {
      defines = [ "__FBSDID=__RCSID" "_UTMPX_COMPAT" "SUPPORT_UTMPX" ];
      # Libc's utmpx is not in libsystem_c: utmpx-darwin.c (which utmpx.c
      # cannot do without) is written against <asl.h>. See libsystem-c.nix.
      allowUndefined = {
        "_endutxent" = "system_asl";
        "_getutxent" = "system_asl";
        "_getutxline" = "system_asl";
        "_utmpxname" = "system_asl";
        "_wtmpxname" = "system_asl";
        # whoami(), when the tty is not in utmpx.
        "_getpwuid" = "system_info";
      };
    };
    yes = { };
  };
in

mkCmds {
  pname = "shell_cmds";
  src = sources.shell_cmds;
  inherit toolchain tools;
  sourceLists = import ./shell-cmds-sources.nix;

  nativeBuildInputs = [ bison ]; # find's getdate.y

  # Project-level Release settings (shell_cmds.xcodeproj).
  cflags = [
    "-std=gnu99" # GCC_C_LANGUAGE_STANDARD
    "-Os" # GCC_OPTIMIZATION_LEVEL (Release default)
    "-fno-common" # GCC_NO_COMMON_BLOCKS
    "-Wall"
    "-Werror=format-nonliteral" # WARNING_CFLAGS
    "-Werror=implicit-function-declaration" # GCC_TREAT_IMPLICIT_FUNCTION_DECLARATIONS_AS_ERRORS
  ];
  defines = [ "__FBSDID=__RCSID" ]; # GCC_PREPROCESSOR_DEFINITIONS
  ldflags = [ "-Wl,-dead_strip" ]; # DEAD_CODE_STRIPPING
}
